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

/// Payload for the `points_selected` inbound message.  Sent by JS when
/// a marquee, lasso, or click gesture commits.  Modifier indicates how
/// the new selection combines with the existing canonical selection
/// (Swift owns the canonical state; JS only reports the gesture).
public struct PointsSelectedPayload: Decodable {
    public let modifier: SelectionModifier
    public let selection: [WireSelectionGroup]
}

/// How a points_selected gesture combines with the existing selection.
///
/// Marquee / lasso:  plain drag is `replace`;  shift-drag is `add`;
/// option-drag is `subtract` — Photoshop convention, kept as-is for
/// drag-shaped gestures.
///
/// Vertex click (M7.5):  plain click is `replace` (single-point);
/// shift-click is `range` (extend from anchor — Apple convention);
/// ⌘-click is `toggle` (XOR a single point — Apple convention).  The
/// vertex-click path is intentionally Apple-flavored rather than
/// Photoshop-flavored because individual vertex selection in a
/// long sequence (e.g., picking a range of trail points to operate
/// on) maps naturally onto Finder's range / toggle convention.
///
/// Snake_case raw values match the wire shape directly.
public enum SelectionModifier: String, Decodable, Sendable {
    case replace
    case add
    case subtract
    case toggle
    case range
}

/// Payload for the `delete_points` inbound message.  This is the path
/// used by JS-originated deletes (e.g. a future right-click → Delete);
/// the Delete-key path goes through Swift menus (AppCommands) and
/// SessionViewModel.deleteSelected, not through the bridge.
public struct DeletePointsPayload: Decodable {
    public let trackId: UUID
    public let segmentId: UUID
    public let pointIndices: [Int]
}

/// Payload for the `move_point` inbound message (M5).  Sent by JS on
/// vertex-drag commit (mouseup) with the destination lat/lon.  The
/// (track_id, segment_id, point_index) triple identifies the point
/// being moved;  Swift looks it up, updates lat/lon (preserving
/// elevation and timestamp), and broadcasts update_tracks.
public struct MovePointPayload: Decodable {
    public let trackId: UUID
    public let segmentId: UUID
    public let pointIndex: Int
    public let lat: Double
    public let lon: Double
}

/// Payload for the `add_point_on_line` inbound message (M5).  Sent
/// by JS on a click landing on a polyline (not on a vertex).
/// `afterIndex` names the existing point that the new point should
/// be inserted IMMEDIATELY AFTER;  -1 means insert at the very front.
/// Per Docs/02_MAP_AND_BRIDGE.md, the wire field is `after_index`
/// which decodes to `afterIndex` via the snake-case strategy.
public struct AddPointOnLinePayload: Decodable {
    public let trackId: UUID
    public let segmentId: UUID
    public let afterIndex: Int
    public let lat: Double
    public let lon: Double
}

/// Payload for the `request_context_menu` inbound message (M5
/// follow-up).  JS detects right-click and posts this with the click
/// context — either a vertex (track_id, segment_id, point_index) or
/// empty space (lat, lon).  The view-coordinate `clickX`/`clickY`
/// fields locate the cursor for menu positioning;  Swift converts
/// from view coordinates to screen coordinates when calling
/// `NSMenu.popUp(...)`.
public struct RequestContextMenuPayload: Decodable {
    public let target: ContextMenuTarget
    public let clickX: Double
    public let clickY: Double
}

/// Discriminated union of context-menu targets.  Mirrors the wire
/// format `{kind: "point" | "empty", ...}` decoded via a manual
/// `init(from:)` since Swift's automatic Codable doesn't handle this
/// shape natively.
public enum ContextMenuTarget: Decodable, Equatable, Sendable {
    case point(trackId: UUID, segmentId: UUID, pointIndex: Int)
    case empty(latitude: Double, longitude: Double)

    private enum CodingKeys: String, CodingKey {
        case kind, trackId, segmentId, pointIndex, lat, lon
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "point":
            self = .point(
                trackId: try c.decode(UUID.self, forKey: .trackId),
                segmentId: try c.decode(UUID.self, forKey: .segmentId),
                pointIndex: try c.decode(Int.self, forKey: .pointIndex)
            )
        case "empty":
            self = .empty(
                latitude: try c.decode(Double.self, forKey: .lat),
                longitude: try c.decode(Double.self, forKey: .lon)
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: c,
                debugDescription: "Unknown context-menu target kind: \(kind)"
            )
        }
    }
}

/// Payload for the `apply_brush` inbound message (M4).  Sent by JS on
/// brush-stroke commit (mouseup).  Per Docs/02_MAP_AND_BRIDGE.md the
/// stroke geometry — not the JS-computed preview result — is what
/// crosses the bridge:  Swift re-runs the operation against authoritative
/// state so a stale local preview can never commit.  A single brush
/// gesture may produce multiple `apply_brush` messages if the stroke
/// touches multiple tracks (one message per track_id).
public struct ApplyBrushPayload: Decodable {
    public let brushType: String
    public let trackId: UUID
    public let stroke: WireBrushStroke
}

/// Wire representation of a brush stroke.  `kind` mirrors D-015's two
/// brush specializations — "region" for Simplify / Smooth / Average
/// (existing-point operations within a circle around the cursor) and
/// "path" for Add Detail (point-generating along the cursor path).
/// At M4 only `kind == "region"` is actually used;  the field is
/// declared now so the wire format doesn't need extending later.
public struct WireBrushStroke: Decodable {
    public let kind: String
    public let samples: [WireStrokeSample]
}

/// One sample from a brush stroke — typically one cursor position
/// during the drag.  Each sample carries its own radius_meters so a
/// future variable-radius brush could vary it within a single gesture;
/// at M4 every sample carries the same radius.
public struct WireStrokeSample: Decodable {
    public let lat: Double
    public let lon: Double
    public let radiusMeters: Double
}

/// Wire representation of one (track, segment, point_indices) group,
/// shared by `points_selected` (inbound) and `highlight_selection`
/// (outbound).  Mirrors `Selection.SegmentGroup` from the model layer.
///
/// **UUID case is part of the contract.**  The JS side keys
/// `state.tracksById` by lowercase UUID strings (set when load_session
/// is rendered;  see WireTrack.init's `.lowercased()` call).  A wire
/// type that encoded UUIDs through Swift's default Codable would emit
/// UPPERCASE strings (UUID.uuidString is uppercase), and the round-trip
/// from Swift→JS→Swift→JS would produce a mismatch in the JS Map lookup
/// — selection markers fail to render with `skipped_no_track > 0` even
/// though the Swift side is doing everything correctly.  The fix is the
/// same one WireTrack/WireSegment/WireWaypoint use:  store the wire
/// representation as `String`, lowercase explicitly at construction,
/// and convert back to UUID at the model boundary on the way in.
public struct WireSelectionGroup: Codable {
    public let trackId: String       // lowercase UUID string on the wire
    public let segmentId: String     // lowercase UUID string on the wire
    public let pointIndices: [Int]

    public init(trackId: String, segmentId: String, pointIndices: [Int]) {
        self.trackId = trackId
        self.segmentId = segmentId
        self.pointIndices = pointIndices
    }

    /// Build from the model layer's `Selection.SegmentGroup`.  Used
    /// when encoding `highlight_selection` from the canonical
    /// SessionViewModel.selection.  Lowercases the UUID strings so JS
    /// state.tracksById key-matching works (see type doc).
    public init(from group: Selection.SegmentGroup) {
        self.trackId = group.trackId.uuidString.lowercased()
        self.segmentId = group.segmentId.uuidString.lowercased()
        self.pointIndices = group.pointIndices
    }

    /// Convert to the model layer's `Selection.SegmentGroup`.  Returns
    /// nil if the wire strings aren't valid UUIDs — that's a bridge
    /// violation the caller should log and drop, not crash on.
    public func toModelGroup() -> Selection.SegmentGroup? {
        guard
            let trackUUID = UUID(uuidString: trackId),
            let segmentUUID = UUID(uuidString: segmentId)
        else { return nil }
        return Selection.SegmentGroup(
            trackId: trackUUID,
            segmentId: segmentUUID,
            pointIndices: pointIndices
        )
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

/// Payload for the `update_tracks` outbound message.  Sent after a
/// Swift-side mutation that should be reflected in the WebView without
/// reloading the entire session.  At M3 the typical sender is
/// SessionViewModel.deleteSelected (which broadcasts the touched
/// tracks), and the AppCommands Import GPX path (which broadcasts the
/// newly-added tracks plus any existing ones if the operation requires
/// it).
///
/// Wire format is "replace these tracks entirely" rather than a
/// per-segment or per-point diff.  Per Docs/02_MAP_AND_BRIDGE.md the
/// simpler shape is fast enough at the realistic scale of GPXeditor
/// projects (a few tracks, thousands of points) and avoids a whole
/// class of consistency bugs that diff protocols are heir to.
public struct UpdateTracksPayload: Encodable {
    public let tracks: [WireTrack]

    /// Build from the canonical session, including only the tracks
    /// whose ids appear in `trackIds`.  Returns an empty payload if
    /// none of the requested ids match — caller decides whether to
    /// send anyway (broadcast-empty serves as a "tell JS to drop any
    /// stale layers" signal).
    public init(session: GPXSession, trackIds: Set<UUID>) {
        self.tracks = session.tracks
            .filter { trackIds.contains($0.id) }
            .map(WireTrack.init(from:))
    }

    /// Build from a list of tracks directly — used when the caller
    /// already has the post-mutation Track values and wants to broadcast
    /// them without re-walking the session.
    public init(tracks: [Track]) {
        self.tracks = tracks.map(WireTrack.init(from:))
    }
}

/// Payload for the `preview_trim` outbound message.  Sent by the
/// Trim Track dialog as the user adjusts the start/end bounds —
/// JS renders the named points with a red highlight so the user
/// sees exactly which samples will be dropped on commit.  An
/// empty groups array clears the preview without sending the
/// companion `clear_trim_preview` message;  both code paths reach
/// the same JS state.
public struct PreviewTrimPayload: Encodable {
    public let groups: [WireSelectionGroup]

    public init(groups: [TrimTrackOperation.PreviewGroup]) {
        // Reuse WireSelectionGroup as the wire shape — it already
        // has the (track_id, segment_id, point_indices) triple in
        // the right snake_case format and lowercase-id convention.
        // The semantic meaning is different (these points are
        // "to be removed," not "selected") but the wire envelope
        // matches and JS dispatches by message type.
        self.groups = groups.map {
            WireSelectionGroup(
                trackId: $0.trackId.uuidString.lowercased(),
                segmentId: $0.segmentId.uuidString.lowercased(),
                pointIndices: $0.pointIndices
            )
        }
    }
}

/// Payload for the `clear_trim_preview` outbound message.  Sent
/// when the dialog dismisses (OK or Cancel) so the JS preview
/// overlay tears down cleanly.  Empty payload — the message type
/// itself is the signal.
public struct ClearTrimPreviewPayload: Encodable {
    public init() {}
}

/// Payload for the `zoom_to_bounds` outbound message (M7.5).  Sent
/// when the user invokes "Zoom to Fit" on a track in the sidebar
/// (or — eventually — ⌘2 "Zoom to Selection" from the parking-lot
/// items).  JS calls Leaflet's `map.fitBounds([[south, west],
/// [north, east]])` with reasonable padding so the requested
/// region renders fully visible without kissing the viewport edges.
///
/// All four fields are WGS84 decimal degrees per the bridge
/// protocol's coordinate convention.  North > south and east > west
/// is the caller's responsibility (Leaflet tolerates the inverse
/// but the result wouldn't match user intent).
public struct ZoomToBoundsPayload: Encodable {
    public let northLat: Double
    public let southLat: Double
    public let eastLon: Double
    public let westLon: Double

    public init(
        northLat: Double,
        southLat: Double,
        eastLon: Double,
        westLon: Double
    ) {
        self.northLat = northLat
        self.southLat = southLat
        self.eastLon = eastLon
        self.westLon = westLon
    }

    enum CodingKeys: String, CodingKey {
        // Explicit because the snake-case strategy on `northLat`
        // produces `north_lat` — that's correct, but declaring
        // them here keeps the wire contract self-documenting.
        case northLat = "north_lat"
        case southLat = "south_lat"
        case eastLon = "east_lon"
        case westLon = "west_lon"
    }
}

/// Payload for the `remove_tracks` outbound message.  Sent after a
/// Swift-side mutation removes one or more tracks from the session
/// (M6 Merge — source track is absorbed and removed).  JS tears
/// down the named tracks' Leaflet layers and drops them from its
/// state.tracksById map.
///
/// Wire format:  a list of track ids to remove.  The companion
/// `update_tracks` message (sent in the same broadcast) carries the
/// surviving tracks' new state;  this message carries the removed
/// ones.  Together they describe a complete diff over the track
/// roster without requiring a full load_session.
public struct RemoveTracksPayload: Encodable {
    public let trackIds: [String]

    public init(trackIds: [UUID]) {
        // Lowercase the UUID strings to match the WireTrack convention
        // that JS keys state.tracksById by lowercase id strings;  see
        // the M3 UUID-case round-trip note in HANDOFF.md for context
        // on why mismatched casing is a silent disaster.
        self.trackIds = trackIds.map { $0.uuidString.lowercased() }
    }
}

/// Payload for the `highlight_selection` outbound message.  Sent any
/// time the canonical selection changes.  Empty `selection` array
/// clears the highlight.
public struct HighlightSelectionPayload: Encodable {
    public let selection: [WireSelectionGroup]

    public init(selection: Selection) {
        self.selection = selection.grouped().map(WireSelectionGroup.init(from:))
    }
}

/// Payload for the `set_tool` outbound message.  Sent when the active
/// editing tool changes (V → point, L → lasso, Escape → point).  JS
/// reads this to decide which gesture to attach to the next mouse drag —
/// rectangle for `point` (marquee), free-form polygon for `lasso`.
///
/// This message is an addition to the M2-M9 catalog originally drafted
/// in Docs/02_MAP_AND_BRIDGE.md;  added at M3 because the directive's
/// original assumption was that JS would infer the tool from the
/// gesture, which is brittle (a user expects "the lasso tool draws a
/// lasso every time" — the gesture cue is the result, not the cause).
public struct SetToolPayload: Encodable {

    /// Wire string identifying the tool.  Snake_case to match the
    /// project's wire-format convention even though most tool names
    /// are single words.
    public let tool: String

    public init(tool: EditingTool) {
        switch tool {
        case .point: self.tool = "point"
        case .lasso: self.tool = "lasso"
        case .brushSimplify: self.tool = "brush_simplify"
        case .brushSmooth: self.tool = "brush_smooth"
        }
    }
}
