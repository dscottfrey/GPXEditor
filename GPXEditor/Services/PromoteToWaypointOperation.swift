// PromoteToWaypointOperation.swift
//
// Convert a single track point into a waypoint at the same lat/lon.
// The track point is removed from its segment;  a new Waypoint is
// appended to the same track's waypoints list, carrying the original
// point's lat / lon / elevation / time.  Same identity preservation
// philosophy as AddPointOnLine — we don't fabricate metadata.
//
// Default Waypoint properties:
//   - id:  freshly-generated UUID
//   - name:  empty string (user can edit in the Inspector at M8;
//     keeping it empty rather than synthesizing "Waypoint 5" or
//     "promoted point" means there's no fictional name to clean up
//     later)
//   - sym:  "Generic" (the curated icon set's neutral default)
//   - description:  nil
//
// Index-shift caveat:  removing the track point at index i shifts
// every index > i down by one.  Selection / undo state should be
// cleared by the caller (SessionViewModel does this).
//
// Per CONVENTIONS.md "platform-agnostic data layer," Foundation only.

import Foundation

public enum PromoteToWaypointOperation {

    public static func apply(
        to session: GPXSession,
        trackId: UUID,
        segmentId: UUID,
        pointIndex: Int
    ) -> (session: GPXSession, touched: [TouchedSegment]) {

        guard let trackIndex = session.tracks.firstIndex(where: { $0.id == trackId }) else {
            return (session, [])
        }
        var newSession = session
        var track = newSession.tracks[trackIndex]
        guard let segmentIndex = track.segments.firstIndex(where: { $0.id == segmentId }) else {
            return (session, [])
        }
        var segment = track.segments[segmentIndex]
        guard pointIndex >= 0, pointIndex < segment.points.count else {
            return (session, [])
        }

        let original = segment.points[pointIndex]
        let waypoint = Waypoint(
            latitude: original.latitude,
            longitude: original.longitude,
            elevation: original.elevation,
            time: original.time,
            name: "",
            sym: "Generic",
            description: nil
        )

        // Remove the track point from its segment.
        segment.points.remove(at: pointIndex)
        track.segments[segmentIndex] = segment

        // Append the waypoint to the track's waypoint list.  Order
        // doesn't carry semantic meaning at the data layer;  the
        // sidebar (M8) groups waypoints visually by spatial proximity
        // to segments, not by their position in this array.
        track.waypoints.append(waypoint)
        newSession.tracks[trackIndex] = track

        return (newSession, [TouchedSegment(trackId: trackId, segmentId: segmentId)])
    }

    public struct TouchedSegment: Equatable, Sendable {
        public let trackId: UUID
        public let segmentId: UUID

        public init(trackId: UUID, segmentId: UUID) {
            self.trackId = trackId
            self.segmentId = segmentId
        }
    }
}
