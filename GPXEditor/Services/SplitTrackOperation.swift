// SplitTrackOperation.swift
//
// Split a track into two tracks at a named point.  The original
// track keeps everything BEFORE the split point;  a freshly-created
// track holds everything FROM the split point onward.  The named
// point becomes the FIRST point of the new track's first segment
// (no duplication — same convention SetSegmentBoundary uses for
// within-track segment splits).
//
// Why no duplication:
//   - Consistency with SetSegmentBoundary at the segment level.
//   - "I want to split this trail at the lunch stop" — the lunch
//     stop ends up at the start of the second leg, not duplicated
//     across both.
//   - Round-trip-friendly:  exporting the two tracks separately
//     then re-importing gives two distinct tracks with no shared
//     point at the boundary, matching what was on disk.
// The alternative (duplicate the split point on both sides) was
// considered but rejected for the consistency reason above.  A
// future "Connect Two Points" / fuse operation would handle the
// inverse direction symmetrically.
//
// Segment handling:
//   - Segments that come ENTIRELY before the split point's segment
//     stay with the original track in their original order.
//   - The segment CONTAINING the split point gets cut into two
//     halves;  the pre-half stays with the original, the post-half
//     starts the new track.  Same shape as SetSegmentBoundary —
//     pre-half keeps the original segment id, post-half gets a
//     fresh id, color carries over.
//   - Segments that come ENTIRELY AFTER the split point's segment
//     move to the new track in their original order, with their
//     ids unchanged.
//   - Special case:  if the split point is at index 0 of its
//     segment AND that segment is not the first segment in the
//     track, no segment cut is needed — the split happens at a
//     natural segment boundary.  The original track keeps every
//     segment before this one;  the new track gets this segment
//     and everything after, all with their original ids.
//
// New track properties:
//   - id:  fresh UUID.
//   - name:  "<original name> (continued)" — reads naturally for
//     the typical "split day 1 from day 2" use case.  The user can
//     rename in the Inspector at M8.
//   - role:  nil (unaffiliated).  If the user split a master
//     track, the original keeps master role;  designating the new
//     half as master/subsidiary is an explicit decision rather
//     than something the split should silently make.
//   - recordedDate:  inherited from the original.  The recording
//     happened on a single date;  the split is a project-internal
//     subdivision, not a fresh recording.
//   - immutableOriginalBytes:  empty `Data()`.  The new track was
//     created by editing, not by importing — there's no source
//     file to "reset to."  Reset to Original on a track with empty
//     bytes is a separate concern that the Reset operation handles
//     (see TrackImporter.resetTrackToOriginal);  this operation
//     just leaves the bytes empty as the honest signal that there
//     is no original to restore.
//   - waypoints:  empty.  All waypoints stay on the original
//     track.  Spatial assignment ("which side of the split is
//     this waypoint closer to?") is more cleverness than v1
//     earns;  the user can move waypoints via the Inspector at M8.
//
// Edge cases (no-op behaviour, matching the SetSegmentBoundary /
// stale-references-tolerated pattern):
//   - Stale trackId or segmentId:  no-op.
//   - pointIndex == 0 in the FIRST segment:  no-op.  Splitting
//     "before the very first point" produces an empty original
//     track + a new track identical to the original.
//   - pointIndex points at the LAST point of the LAST segment AND
//     all later segments are also empty:  no-op.  Splitting "after
//     everything" produces a full original + an empty new track.
//   - Out-of-range pointIndex:  no-op.
//
// Per CONVENTIONS.md "platform-agnostic data layer," Foundation only.

import Foundation

public enum SplitTrackOperation {

    public static func apply(
        to session: GPXSession,
        trackId: UUID,
        segmentId: UUID,
        pointIndex: Int
    ) -> (session: GPXSession, touched: [TouchedTrack]) {

        guard let trackIndex = session.tracks.firstIndex(where: { $0.id == trackId }) else {
            return (session, [])
        }
        let originalTrack = session.tracks[trackIndex]
        guard let segmentIndex = originalTrack.segments.firstIndex(where: { $0.id == segmentId }) else {
            return (session, [])
        }
        let originalSegment = originalTrack.segments[segmentIndex]

        // Validate pointIndex against the named segment.
        guard pointIndex >= 0, pointIndex < originalSegment.points.count else {
            return (session, [])
        }

        // Reject the "split at the very first point" case — would
        // produce an empty original.
        if segmentIndex == 0 && pointIndex == 0 {
            return (session, [])
        }

        // Reject the "split at the very last point" case — would
        // produce an empty new track.  "Very last" means:  this is
        // the final point of this segment, and every later segment
        // (if any) is empty.
        if pointIndex == originalSegment.points.count - 1 {
            let laterSegmentsHaveAnyPoints = originalTrack.segments
                .dropFirst(segmentIndex + 1)
                .contains(where: { !$0.points.isEmpty })
            if !laterSegmentsHaveAnyPoints {
                // Still need to handle the variant where pointIndex
                // is the last of THIS segment but there's content
                // ahead.  That falls through below into the
                // segments-ahead branch.  Here we reject only when
                // there's nothing after.
                return (session, [])
            }
        }

        // Build the original-track-side segment list (everything that
        // comes before the split, including the partial cut of the
        // split segment) and the new-track-side segment list (the
        // partial post-split segment + everything after).

        var originalSegments: [Segment] = Array(originalTrack.segments[..<segmentIndex])
        var newSegments: [Segment] = []

        if pointIndex == 0 {
            // Natural segment boundary — no need to cut the segment.
            // The split segment moves whole-cloth to the new track,
            // followed by every segment after it.
            newSegments.append(originalSegment)
        } else {
            // Cut the split segment in two halves.  Pre-half keeps
            // the original segment id;  post-half gets a fresh id.
            // Color carries over to the new half (consistent with
            // SetSegmentBoundary).
            let preHalfPoints = Array(originalSegment.points[..<pointIndex])
            let postHalfPoints = Array(originalSegment.points[pointIndex...])
            var preHalf = originalSegment
            preHalf.points = preHalfPoints
            originalSegments.append(preHalf)

            let postHalf = Segment(
                id: UUID(),
                name: nil,
                color: originalSegment.color,
                points: postHalfPoints
            )
            newSegments.append(postHalf)
        }

        // Append every segment that came after the split segment to
        // the new track, preserving id/name/color/points.
        newSegments.append(contentsOf: originalTrack.segments[(segmentIndex + 1)...])

        // Build the modified original track.
        var modifiedOriginal = originalTrack
        modifiedOriginal.segments = originalSegments

        // Build the new track.  See file-header doc for property
        // choices and rationale.
        let newTrack = Track(
            id: UUID(),
            name: "\(originalTrack.name) (continued)",
            immutableOriginalBytes: Data(),
            segments: newSegments,
            waypoints: [],
            role: nil,
            recordedDate: originalTrack.recordedDate
        )

        var newSession = session
        newSession.tracks[trackIndex] = modifiedOriginal
        // Insert the new track immediately after the original so the
        // sidebar order matches the user's mental model:  "this track
        // and the one that came out of it sit next to each other."
        newSession.tracks.insert(newTrack, at: trackIndex + 1)

        return (
            newSession,
            [
                TouchedTrack(trackId: originalTrack.id),
                TouchedTrack(trackId: newTrack.id),
            ]
        )
    }

    public struct TouchedTrack: Equatable, Sendable {
        public let trackId: UUID

        public init(trackId: UUID) {
            self.trackId = trackId
        }
    }
}
