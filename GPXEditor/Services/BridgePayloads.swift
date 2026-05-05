// BridgePayloads.swift
//
// The typed payload structs for every bridge message currently
// implemented.  Schemas are documented in Docs/02_MAP_AND_BRIDGE.md;
// these structs are the Swift expression of those schemas.
//
// Naming convention:  every payload type is named `<MessageType>Payload`
// in PascalCase.  Wire-format keys are snake_case;  the `JSONEncoder` /
// `JSONDecoder` configurations in BridgeMessage.swift apply
// .convertToSnakeCase / .convertFromSnakeCase so most properties don't
// need explicit CodingKeys mappings — `editorVersion` <-> `editor_version`
// happens automatically.  Where the wire format uses an irregular form
// (a leading underscore, an abbreviation that doesn't round-trip
// cleanly through the snake-case strategy), an explicit CodingKeys is
// declared.
//
// Inbound payloads decode from JSON;  outbound payloads encode to JSON.
// Two payloads cross both directions — none currently — and would be
// declared as both Decodable and Encodable.
//
// Platform-agnostic.  Foundation only.

import Foundation

// MARK: - Inbound payloads (JS → Swift)

/// Payload for the `ready` inbound message.  Sent once by editor.js when
/// it has finished initializing and is ready to accept `load_session`.
/// `editorVersion` is a build-time string useful for diagnosing JS/Swift
/// schema mismatches in os_log.
public struct ReadyPayload: Decodable {
    public let editorVersion: String
}

/// Payload for the `log` inbound message.  editor.js uses this in place
/// of `console.log` so JS log lines surface in os_log alongside Swift
/// logs;  level maps to os_log severity.
///
/// `context` is a free-form JSON object for diagnostic metadata.  We
/// don't strongly type it because callers may attach arbitrary
/// structured data;  the dispatcher renders it back to a JSON string
/// for the os_log message.
public struct LogPayload: Decodable {
    public let level: String     // "debug" | "info" | "warning" | "error"
    public let message: String
    public let context: JSONValue?
}

/// A minimal Codable type for "any JSON value" — used by `LogPayload.context`
/// where the schema is "arbitrary diagnostic object."  Swift's stdlib doesn't
/// ship one of these, so we define a small variant locally rather than
/// pulling in a dependency for the single use site.
public enum JSONValue: Codable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? container.decode(Double.self) {
            self = .number(n)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let a = try? container.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? container.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Value is not a recognised JSON type"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:           try container.encodeNil()
        case .bool(let b):    try container.encode(b)
        case .number(let n):  try container.encode(n)
        case .string(let s):  try container.encode(s)
        case .array(let a):   try container.encode(a)
        case .object(let o):  try container.encode(o)
        }
    }

    /// Render to a compact JSON string for log output.  Used by the
    /// dispatcher to fold the free-form context into an os_log line.
    public func compactJSONString() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard
            let data = try? encoder.encode(self),
            let s = String(data: data, encoding: .utf8)
        else {
            return "<unencodable JSONValue>"
        }
        return s
    }
}

// MARK: - Outbound payloads (Swift → JS)

/// Payload for the `load_session` outbound message.  Carries the full
/// project state for initial render.  Schema in Docs/02_MAP_AND_BRIDGE.md;
/// the wire keys are snake_case via the encoder's keyEncodingStrategy.
public struct LoadSessionPayload: Encodable {

    public let tracks: [WireTrack]
    public let activeBasemapId: String
    public let viewport: WireViewport?

    /// Build a wire payload from the canonical Swift session.  The mapping
    /// flattens internal types (Track / Segment / TrackPoint / Waypoint)
    /// into the wire shapes documented in the bridge protocol.  Per-point
    /// timestamps survive on the wire (D-012 only drops them on GPX
    /// export) so the Stats panel can compute speed/gradient.
    public init(session: GPXSession) {
        self.tracks = session.tracks.map(WireTrack.init(from:))
        self.activeBasemapId = session.selectedBasemapId
        self.viewport = session.viewport.map(WireViewport.init(from:))
    }
}

/// Wire representation of a Track.  Note `trackId: String` (UUID
/// stringified) and `role: String?` ("master" / "subsidiary" / nil) —
/// JS sees stringly-typed UUIDs and roles.
public struct WireTrack: Encodable {
    public let trackId: String
    public let name: String
    public let role: String?
    public let segments: [WireSegment]
    public let waypoints: [WireWaypoint]

    public init(from track: Track) {
        self.trackId = track.id.uuidString.lowercased()
        self.name = track.name
        self.role = track.role.map { role in
            switch role {
            case .master: return "master"
            case .subsidiary: return "subsidiary"
            }
        }
        self.segments = track.segments.map(WireSegment.init(from:))
        self.waypoints = track.waypoints.map(WireWaypoint.init(from:))
    }
}

public struct WireSegment: Encodable {
    public let segmentId: String
    public let color: String        // "#RRGGBB"
    public let points: [WireTrackPoint]

    public init(from segment: Segment) {
        self.segmentId = segment.id.uuidString.lowercased()
        self.color = segment.color.value
        self.points = segment.points.map(WireTrackPoint.init(from:))
    }
}

public struct WireTrackPoint: Encodable {

    public let lat: Double
    public let lon: Double
    public let ele: Double?
    public let time: String?    // ISO 8601 with Z

    public init(from point: TrackPoint) {
        self.lat = point.latitude
        self.lon = point.longitude
        self.ele = point.elevation
        self.time = point.time.map(WireTrackPoint.iso8601Formatter.string(from:))
    }

    /// ISO 8601 with explicit Z UTC suffix.  Matches GPX's xsd:dateTime
    /// format and the bridge protocol's "time" convention.  Static so the
    /// formatter is reused across every point encoding rather than
    /// reconstructed (formatter init is non-trivial).
    private static let iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    enum CodingKeys: String, CodingKey {
        // Override the default snake-case strategy — `lat`/`lon`/`ele`
        // are already wire-shape and don't have a camelCase Swift form
        // to convert from.  Without this CodingKeys, the strategy would
        // emit them unchanged (which is correct), but declaring the keys
        // explicitly documents the wire contract.
        case lat, lon, ele, time
    }
}

public struct WireWaypoint: Encodable {
    public let waypointId: String
    public let lat: Double
    public let lon: Double
    public let name: String
    public let symbol: String

    public init(from waypoint: Waypoint) {
        self.waypointId = waypoint.id.uuidString.lowercased()
        self.lat = waypoint.latitude
        self.lon = waypoint.longitude
        self.name = waypoint.name
        self.symbol = waypoint.sym
    }
}

public struct WireViewport: Encodable {
    public let centerLat: Double
    public let centerLon: Double
    public let zoom: Double

    public init(from viewport: ViewportState) {
        self.centerLat = viewport.centerLatitude
        self.centerLon = viewport.centerLongitude
        self.zoom = viewport.zoom
    }
}

/// Payload for the `set_basemap` outbound message.  Sent on initial load
/// (with the document's `selectedBasemapId`) and whenever the user picks
/// a different basemap from the SwiftUI selector.
public struct SetBasemapPayload: Encodable {
    public let basemapId: String
    public let tileUrlTemplate: String
    public let attribution: String
    public let maxZoom: Int

    public init(from basemap: Basemap) {
        self.basemapId = basemap.id
        self.tileUrlTemplate = basemap.tileURLTemplate
        self.attribution = basemap.attribution
        self.maxZoom = basemap.maxZoom
    }

    enum CodingKeys: String, CodingKey {
        // Explicit because "tileUrlTemplate" snake-cases to
        // "tile_url_template" cleanly (`Url` -> `url`) but only because
        // the standard strategy lower-cases acronyms;  declare the keys
        // here so the wire shape is self-documenting.
        case basemapId = "basemap_id"
        case tileUrlTemplate = "tile_url_template"
        case attribution
        case maxZoom = "max_zoom"
    }
}
