// SetSegmentBoundaryOperation.swift
//
// Split a single track segment into two segments at the named point.
// The named point becomes the FIRST point of the new (second)
// segment;  the original segment shrinks to [0..pointIndex - 1].
// No point duplication — the boundary point lives in exactly one
// of the two resulting segments.
//
// Why "first of the new segment" rather than "last of the old":
// the GPX `<trkseg>` model treats segments as runs of recorded
// samples;  splitting "from this point onward becomes a new run"
// reads naturally for the typical user intent ("the rest of this
// trail is a different leg").  The other convention (point ends
// the previous segment) would also be valid;  pick one and stay
// consistent.
//
// Edge cases:
//   - pointIndex == 0:  splitting "from the very first point" would
//     produce an empty original segment + a new segment identical
//     to the original.  No-op rather than create the empty.
//   - pointIndex out of range:  no-op (matches the
//     stale-references-tolerated pattern).
//   - segment.points.count < 2:  no-op (nothing meaningful to
//     split).
//
// New segment's color and id:
//   - id:  fresh UUID
//   - name:  nil (no carry-over;  the original segment keeps its
//     name, the new one starts unnamed)
//   - color:  carry over from the original.  Two segments of the
//     same color is fine — the user can recolor in the Inspector
//     (M8) if they want visual distinction.  Auto-cycling to the
//     next palette slot would feel surprising at this layer;  the
//     palette assignment lives in TrackImporter, not in editing
//     operations.
//
// Per CONVENTIONS.md "platform-agnostic data layer," Foundation only.

import Foundation

public enum SetSegmentBoundaryOperation {

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
        let originalSegment = track.segments[segmentIndex]

        // Edge cases that produce a degenerate split.
        if pointIndex <= 0 { return (session, []) }
        if pointIndex >= originalSegment.points.count { return (session, []) }
        if originalSegment.points.count < 2 { return (session, []) }

        // Build the two halves.  Original keeps points [0..pointIndex - 1];
        // the new segment takes [pointIndex..end].
        let originalPoints = Array(originalSegment.points[..<pointIndex])
        let newPoints = Array(originalSegment.points[pointIndex...])

        var shrunkOriginal = originalSegment
        shrunkOriginal.points = originalPoints

        let newSegment = Segment(
            id: UUID(),
            name: nil,
            color: originalSegment.color,
            points: newPoints
        )

        // Replace original at its index, insert new segment immediately
        // after.  The track's segments array preserves order, which is
        // what the user expects (visually contiguous in the sidebar).
        track.segments[segmentIndex] = shrunkOriginal
        track.segments.insert(newSegment, at: segmentIndex + 1)
        newSession.tracks[trackIndex] = track

        return (
            newSession,
            [
                TouchedSegment(trackId: trackId, segmentId: originalSegment.id),
                TouchedSegment(trackId: trackId, segmentId: newSegment.id),
            ]
        )
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
