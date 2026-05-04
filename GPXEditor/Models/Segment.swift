// Segment.swift
//
// A contiguous run of recorded points within a Track, mapping to a single
// `<trkseg>` element in GPX.  A track with two recording sessions, a
// pause-and-resume, or a deliberate Set-Segment-Boundary edit (D-014) ends
// up as multiple Segments.  D-012 preserves segment structure on export
// because it carries user intent through any export-then-reimport round
// trip — the writer emits one `<trkseg>` per Segment in order.
//
// Color is a per-Segment property, stored as a HexColor (D-013).  Two
// Segments of the same Track can be different colors so the user can
// visually distinguish (for example) the morning half from the afternoon
// half of an out-and-back recording.  The default-palette assignment
// happens at import time — the parser produces colorless raw segments,
// then the importer colors them from the palette before the Track is
// folded into the session.
//
// Waypoints are not stored on Segment — they live on Track.  See
// Waypoint.swift for the rationale.

import Foundation

/// A contiguous run of TrackPoints with its own color and optional name.
/// Identity is stable across edits so the sidebar can reference it by id.
public struct Segment: Identifiable, Equatable, Codable, Sendable {

    /// Stable identity for this segment.  Survives mutations to its name,
    /// color, or point list.
    public let id: UUID

    /// Optional segment name.  GPX has no native segment-name element, so
    /// this is project-internal — it appears in the sidebar but does not
    /// round-trip through GPX export.  `nil` for an unnamed segment.
    public var name: String?

    /// Display color for this segment, used wherever the segment renders
    /// (map polyline, sidebar swatch, inspector header).  Not exported
    /// in GPX (D-013).
    public var color: HexColor

    /// The ordered list of recorded points in this segment.  May be empty
    /// (a degenerate segment) in transient editing states; persisted
    /// projects normally have at least two points per segment, and
    /// renderers handle empty/single-point segments without crashing.
    public var points: [TrackPoint]

    public init(
        id: UUID = UUID(),
        name: String? = nil,
        color: HexColor,
        points: [TrackPoint] = []
    ) {
        self.id = id
        self.name = name
        self.color = color
        self.points = points
    }
}
