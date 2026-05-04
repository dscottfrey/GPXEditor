// RawGPX.swift
//
// Intermediate value types produced by GPXParser.  These mirror the shape of
// the source XML closely:  no UUIDs, no per-segment colors, no master/
// subsidiary roles, no immutable-original-bytes blob.  The parser's only job
// is to translate XML into these structs; promoting a `RawGPX` into a fully-
// populated `Track` (in `Models/`) — assigning UUIDs, picking palette colors,
// preserving the source bytes — is the importer's job (M1 task #8).
//
// Why the intermediate layer:  it keeps the parser focused on one concern
// (XML → data) and the importer focused on another (raw data → working-state
// model).  Each layer is independently testable, and the boundaries between
// them are explicit.  Without the intermediate types, the parser would have
// to know about UUID generation, palette indexing, and original-bytes
// retention — things that have nothing to do with reading XML.
//
// Foundation only.  Lives in `Services/` per CONVENTIONS.md type-kind
// grouping (the parser type-kind groups with these types, not with the
// `Models/` working-state types).

import Foundation

// MARK: - Top-level

/// The full content of a parsed GPX file, in raw form.
public struct RawGPX: Equatable, Sendable {

    /// `<gpx version="...">` attribute.  Either `"1.0"` or `"1.1"` for valid
    /// input.  Stored as a String rather than an enum so the parser doesn't
    /// have to fail-loud on a malformed-but-not-empty version; the parser
    /// raises `.unsupportedVersion` *before* this field is read by callers.
    public var version: String?

    /// `<gpx creator="...">` attribute.  Common values: "Garmin Connect",
    /// "Strava", "GPX Generator".  Project-internal use only — never emitted
    /// on export per D-012's "we set our own creator" stance.
    public var creator: String?

    /// `<metadata><time>...</time></metadata>` parsed as a Date.
    /// Optional because GPX 1.0 made it optional and many recordings omit it.
    public var metadataTime: Date?

    /// `<metadata><name>...</name></metadata>`.  Often missing; rarely useful.
    public var metadataName: String?

    /// All `<trk>` elements in document order.
    public var tracks: [RawTrack]

    /// All file-level `<wpt>` elements in document order.  GPX places `<wpt>`
    /// at the document level (peer to `<trk>`); the working-state model
    /// instead attaches them to a `Track` (see Waypoint.swift's header for
    /// the rationale).  The importer makes that placement decision; the
    /// parser just lists them.
    public var waypoints: [RawWaypoint]

    public init(
        version: String? = nil,
        creator: String? = nil,
        metadataTime: Date? = nil,
        metadataName: String? = nil,
        tracks: [RawTrack] = [],
        waypoints: [RawWaypoint] = []
    ) {
        self.version = version
        self.creator = creator
        self.metadataTime = metadataTime
        self.metadataName = metadataName
        self.tracks = tracks
        self.waypoints = waypoints
    }
}

// MARK: - Track / Segment / Point

/// A single `<trk>` from the source GPX.
public struct RawTrack: Equatable, Sendable {

    /// `<trk><name>...</name></trk>`.  Optional because not every recording
    /// supplies one; the importer falls back to a default like "Imported
    /// track" or the source filename when missing.
    public var name: String?

    /// All `<trkseg>` elements within this track in document order.
    public var segments: [RawSegment]

    public init(name: String? = nil, segments: [RawSegment] = []) {
        self.name = name
        self.segments = segments
    }
}

/// A single `<trkseg>`.  Holds an ordered list of points; segments carry no
/// other data in raw form.  Color and other working-state metadata are added
/// by the importer.
public struct RawSegment: Equatable, Sendable {

    public var points: [RawPoint]

    public init(points: [RawPoint] = []) {
        self.points = points
    }
}

/// A single `<trkpt>`.  Required `lat`/`lon` attributes plus optional `<ele>`
/// and `<time>` children.
public struct RawPoint: Equatable, Sendable {

    public var latitude: Double
    public var longitude: Double
    public var elevation: Double?
    public var time: Date?

    public init(
        latitude: Double,
        longitude: Double,
        elevation: Double? = nil,
        time: Date? = nil
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.elevation = elevation
        self.time = time
    }
}

// MARK: - Waypoint

/// A single `<wpt>`.  Same coordinate fields as `RawPoint` plus the
/// waypoint-specific name/sym/desc text children.
public struct RawWaypoint: Equatable, Sendable {

    public var latitude: Double
    public var longitude: Double
    public var elevation: Double?
    public var time: Date?
    public var name: String?
    public var sym: String?
    public var description: String?

    public init(
        latitude: Double,
        longitude: Double,
        elevation: Double? = nil,
        time: Date? = nil,
        name: String? = nil,
        sym: String? = nil,
        description: String? = nil
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.elevation = elevation
        self.time = time
        self.name = name
        self.sym = sym
        self.description = description
    }
}
