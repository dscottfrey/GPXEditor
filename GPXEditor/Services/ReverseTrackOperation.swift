// ReverseTrackOperation.swift
//
// Reverse a track's direction — flips segment order within the track
// and flips point order within each segment.  The result reads as
// "walk this trail backwards":  the last recorded point becomes the
// first, the first becomes the last, and the segments line up in the
// reverse order they were recorded.
//
// Why both axes (segment order AND within-segment point order):
// segments encode a sequence of recording runs — a pause-and-resume,
// or a deliberate Set-Segment-Boundary edit (D-014).  A user who
// reverses a track wants the whole geometry reversed end-to-end, not
// just the points within each segment;  if you reverse only the
// per-segment points, segment-2 still comes after segment-1, so the
// resulting track reads as "morning recording but in reverse, then
// afternoon recording but in reverse," which doesn't match the
// intent.  Both axes flipped gives the natural "do the entire trail
// in reverse" reading.
//
// Per-point metadata (elevation, timestamp) stays attached to each
// individual point.  We don't fabricate or reorder metadata — a point
// with a recorded timestamp keeps that timestamp regardless of where
// it ends up in the segment.  The natural consequence:  if the
// original track had monotonically-increasing timestamps, the
// reversed track has monotonically-decreasing timestamps.  That's
// honest — the timestamps record when the recording happened, and
// reversing the track doesn't change that history.  The Stats panel
// (M8) computing speed will see negative time deltas if it processes
// a reversed track naively;  it should take abs() on the time delta
// or compare adjacent timestamps without assuming order.  Strip-
// timestamps-on-reverse was considered and rejected:  it's destructive
// (Reset to Original recovers, but undo's the more natural recovery
// path), and a future "Strip Timestamps" operation can be added if
// the use case earns it.
//
// Identity preservation:  segment ids are unchanged.  The track's
// segments array is a new ordering of the same segments;  each
// segment's points array is a new ordering of the same points.  The
// segment id remains the segment id;  the track id is unchanged.  This
// matters for undo (snapshot-and-restore continues to work),
// for the bridge `update_tracks` broadcast (each segment renders with
// its existing id), and for any hypothetical future "linked
// references" (a comment, an inspector pin) that uses segment id.
//
// Waypoints are untouched.  They have their own lat/lon and don't
// participate in track ordering — a waypoint placed at a trailhead
// stays at the trailhead regardless of which direction you walk the
// trail.
//
// Edge cases:
//   - Empty track (zero segments):  no-op (no touched-list entry).
//   - Track with empty segments:  segment order flips, within-segment
//     reverse is a no-op for empty segments.  Touched-list still
//     reports the track because order changed.
//   - Single-segment, single-point:  the reverse is geometrically a
//     no-op but still goes through the operation;  touched-list
//     reports the track for consistency (callers can detect the no-op
//     by comparing pre/post if they care).  Same shape MovePoint uses
//     for "same coordinates" — let the caller decide whether a no-op
//     deserves an undo entry.
//   - Stale trackId (track not in session):  no-op, empty touched.
//
// Per CONVENTIONS.md "platform-agnostic data layer," Foundation only.

import Foundation

public enum ReverseTrackOperation {

    public static func apply(
        to session: GPXSession,
        trackId: UUID
    ) -> (session: GPXSession, touched: [TouchedTrack]) {

        guard let trackIndex = session.tracks.firstIndex(where: { $0.id == trackId }) else {
            return (session, [])
        }

        var newSession = session
        var track = newSession.tracks[trackIndex]

        if track.segments.isEmpty {
            // Nothing to reverse;  no touched-list entry so the
            // SessionViewModel layer skips registering an undo.
            return (session, [])
        }

        // Reverse points within each segment, then reverse the segment
        // array itself.  Order of these two operations doesn't matter
        // (they're independent axes) but doing the inner reverse first
        // keeps the loop's locality of reference clean.
        for i in track.segments.indices {
            track.segments[i].points.reverse()
        }
        track.segments.reverse()

        newSession.tracks[trackIndex] = track

        return (newSession, [TouchedTrack(trackId: trackId)])
    }

    public struct TouchedTrack: Equatable, Sendable {
        public let trackId: UUID

        public init(trackId: UUID) {
            self.trackId = trackId
        }
    }
}
