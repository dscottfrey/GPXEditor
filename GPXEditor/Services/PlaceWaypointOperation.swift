// PlaceWaypointOperation.swift
//
// Place a brand-new Waypoint at a click location.  Used by the
// right-click → "Place Waypoint Here" context-menu item (M5
// follow-up).  No track point exists at the click — only a lat/lon
// from the user's gesture — so elevation and timestamp are nil.
// Snap to Ground (M7) is the path that fills in elevation later.
//
// Track ownership:  Waypoints in the data model are owned by a
// Track (Track.swift's file-header rationale:  GPX places `<wpt>`
// at document level but our project-internal model attaches them
// to a track for sidebar grouping and ownership semantics).  For
// the right-click "place here" gesture the user isn't picking a
// track — they're clicking on the map.  We attach to:
//   1. The master track if one is designated (D-011).
//   2. Otherwise, the first track in the session.
//   3. If the project has zero tracks, the operation is a no-op
//      (there's nowhere to put the waypoint).  The right-click
//      menu item should be disabled in that case;  the operation
//      defends against the menu-disabled-but-still-fired race.
//
// Per CONVENTIONS.md "platform-agnostic data layer," Foundation only.

import Foundation

public enum PlaceWaypointOperation {

    public static func apply(
        to session: GPXSession,
        latitude: Double,
        longitude: Double
    ) -> (session: GPXSession, hostTrackId: UUID?) {

        guard let hostTrackIndex = session.tracks.firstIndex(where: { $0.role == .master })
            ?? (session.tracks.isEmpty ? nil : 0)
        else {
            return (session, nil)
        }

        var newSession = session
        var hostTrack = newSession.tracks[hostTrackIndex]

        let waypoint = Waypoint(
            latitude: latitude,
            longitude: longitude,
            elevation: nil,
            time: nil,
            name: "",
            sym: "Generic",
            description: nil
        )
        hostTrack.waypoints.append(waypoint)
        newSession.tracks[hostTrackIndex] = hostTrack

        return (newSession, hostTrack.id)
    }
}
