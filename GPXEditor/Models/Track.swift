// Track.swift
//
// A single GPX track in a project session.  Maps to a `<trk>` element in
// the source GPX file, but with two important departures from the GPX
// data model that come straight out of the architectural decisions:
//
//   1. Each Track carries its own immutable copy of the original GPX
//      bytes (`immutableOriginalBytes`).  D-008 makes the project file
//      self-contained: source files are ingested at import time, their
//      bytes preserved verbatim, and never re-read from disk.  This is
//      what powers per-track Reset to Original (re-parse the bytes,
//      replace the working state) and what makes a saved project
//      portable — a user could delete the source GPX after import and
//      the project would still work perfectly.
//
//   2. Tracks carry a master/subsidiary role (D-011) that the GPX format
//      has no concept of.  Exactly one Track per project is the master;
//      any number may be subsidiaries; the rest are unaffiliated.  The
//      role is project-internal — it doesn't round-trip through GPX
//      export — and is enforced at the `GPXSession` layer rather than at
//      the Track layer (i.e., no init guard prevents you from setting two
//      tracks `.master`; the session-level invariant catches that).
//
// Waypoints live on Track rather than on Segment because GPX places
// `<wpt>` at the document level and the per-segment grouping in the
// sidebar (Docs/05_UI.md) is a UI concern computed from spatial
// proximity, not a stored relationship.  See Waypoint.swift.

import Foundation

/// A single track in a project: name, ordered segments, waypoints, an
/// optional master/subsidiary role, the original GPX bytes from import,
/// and the recording date pulled from the source file's `<metadata><time>`
/// (used at export time per D-012).
public struct Track: Identifiable, Equatable, Codable, Sendable {

    /// Stable identity for this Track across all edits.  Generated when
    /// the Track is constructed by the importer.
    public let id: UUID

    /// User-visible name shown in the sidebar.  GPX provides this via
    /// `<trk><name>` when present; the importer falls back to a
    /// default ("Imported track" or the source filename) when missing,
    /// so this is never `nil`.
    public var name: String

    /// The original GPX file's bytes, preserved verbatim from import.
    /// Never mutated after construction.  Reset to Original re-parses
    /// from this; export of a project's master could in principle be
    /// served from this if the user wanted byte-exact round-trip, though
    /// the standard export path runs through GPXWriter and applies the
    /// D-012 transformations.
    ///
    /// Stored as `Data` rather than `String` so it survives any encoding
    /// quirk in the source file (BOM, unusual XML declaration encoding,
    /// trailing nulls).  In the on-disk `.gpxeditor` JSON envelope it is
    /// base64-encoded; see `Services/ProjectFile.swift` (M1).
    public let immutableOriginalBytes: Data

    /// The ordered list of segments that make up this track's working
    /// state.  This is what the user edits; the immutable bytes above are
    /// what they can fall back to.
    public var segments: [Segment]

    /// Waypoints belonging to this track.  See Waypoint.swift for why
    /// they live on Track rather than on Segment.
    public var waypoints: [Waypoint]

    /// Master/subsidiary role; `nil` means unaffiliated (D-011).
    public var role: TrackRole?

    /// The track's recorded date, taken from the source GPX file's
    /// `<metadata><time>` element when present.  Used by the GPX writer
    /// (D-012) to populate the file-level `<metadata><time>` of the
    /// exported file.  Optional because not every source file declares
    /// one.
    public var recordedDate: Date?

    public init(
        id: UUID = UUID(),
        name: String,
        immutableOriginalBytes: Data,
        segments: [Segment] = [],
        waypoints: [Waypoint] = [],
        role: TrackRole? = nil,
        recordedDate: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.immutableOriginalBytes = immutableOriginalBytes
        self.segments = segments
        self.waypoints = waypoints
        self.role = role
        self.recordedDate = recordedDate
    }
}
