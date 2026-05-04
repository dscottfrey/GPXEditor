// GPXSession.swift
//
// The top-level project state.  An open `.gpxeditor` document is one
// `GPXSession` value:  every Track, every Segment, every Waypoint,
// every immutable original-bytes blob, plus the chosen basemap and
// the saved viewport.  The `Services/ProjectFile.swift` codec wraps
// this into the on-disk JSON envelope (with `formatVersion`) but the
// envelope is purely a codec concern — the runtime model is just
// `GPXSession`.
//
// `GPXSession` is the single Swift-side source of truth for the
// document (per CONVENTIONS.md "Swift is the source of truth;
// JavaScript is the presentation layer").  The map view never holds
// authoritative state — anything the user does in the WebView is
// marshaled across the bridge, applied to a `GPXSession` value here,
// and the new state is pushed back for redraw.
//
// Master/subsidiary invariant: at most one Track in `tracks` carries
// `role == .master`.  This is enforced at the operations layer (M9
// adds the Mark-as-Master action that demotes any prior master before
// promoting the new one) rather than at the data-model layer; the
// type allows multiple `.master` tracks at rest because the cost of
// guarding every mutation is higher than the cost of a single
// invariant-check at the operation that can violate it.

import Foundation

/// The complete state of an open project document.  Encoded into the
/// `.gpxeditor` JSON file via `Services/ProjectFile.swift` (M1).
public struct GPXSession: Equatable, Codable, Sendable {

    /// Project-level metadata (name, creation/modification timestamps).
    public var metadata: ProjectMetadata

    /// All tracks in the project, in user-controlled display order.
    /// At most one carries `.master` role; see master/subsidiary
    /// invariant in the file header.
    public var tracks: [Track]

    /// Identifier of the active basemap.  Stored as a String — the
    /// registry of available basemaps and their tile-server URLs lives
    /// in M2's basemap selector and the SECURITY.md network allow-list.
    /// Persisting an unknown id (e.g., a basemap that was removed in a
    /// later app version) is non-fatal: the UI falls back to the
    /// default basemap and a warning surfaces.
    public var selectedBasemapId: String

    /// Saved map viewport.  `nil` for a freshly created project that
    /// has never been viewed; populated as soon as the map view is
    /// shown and updated as the user pans/zooms.
    public var viewport: ViewportState?

    public init(
        metadata: ProjectMetadata = ProjectMetadata(),
        tracks: [Track] = [],
        selectedBasemapId: String = "osm",
        viewport: ViewportState? = nil
    ) {
        self.metadata = metadata
        self.tracks = tracks
        self.selectedBasemapId = selectedBasemapId
        self.viewport = viewport
    }
}
