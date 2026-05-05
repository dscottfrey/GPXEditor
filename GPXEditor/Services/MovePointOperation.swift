// MovePointOperation.swift
//
// Pure-function "move a single track point to a new location" — the
// Swift side of M5's vertex draggability.  JS posts a `move_point`
// bridge message on commit (mouseup) with the destination lat/lon;
// SessionViewModel routes through this operation, registers undo,
// and broadcasts the result via `update_tracks`.
//
// The point's elevation and timestamp are PRESERVED — moving a point's
// (lat, lon) is a re-positioning of the recorded sample, not a change
// to its other recorded metadata.  D-012's export rule (drop per-point
// time at export) doesn't apply here;  this is the in-memory editing
// model, where time and elevation stay attached for stats / display
// purposes.
//
// Per CONVENTIONS.md "platform-agnostic data layer," Foundation only.

import Foundation

public enum MovePointOperation {

    /// Apply the move.  Returns the new session plus the touched
    /// segment for partial-broadcast `update_tracks`.  No-op when the
    /// (track, segment, index) triple doesn't resolve — matches the
    /// stale-selection-tolerant pattern DeleteOperation uses.
    public static func apply(
        to session: GPXSession,
        trackId: UUID,
        segmentId: UUID,
        pointIndex: Int,
        latitude: Double,
        longitude: Double
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

        var point = segment.points[pointIndex]
        // Defensive identity check — if nothing actually changed, don't
        // produce a "touched" entry that would register a no-op undo.
        if point.latitude == latitude && point.longitude == longitude {
            return (session, [])
        }
        point.latitude = latitude
        point.longitude = longitude
        // elevation and time are preserved — see file header.
        segment.points[pointIndex] = point
        track.segments[segmentIndex] = segment
        newSession.tracks[trackIndex] = track

        return (newSession, [TouchedSegment(trackId: trackId, segmentId: segmentId)])
    }

    /// Mirror of DeleteOperation.TouchedSegment / SimplifyBrush.TouchedSegment.
    /// Same shape across operations so the bridge update_tracks broadcast
    /// path is uniform.
    public struct TouchedSegment: Equatable, Sendable {
        public let trackId: UUID
        public let segmentId: UUID

        public init(trackId: UUID, segmentId: UUID) {
            self.trackId = trackId
            self.segmentId = segmentId
        }
    }
}
