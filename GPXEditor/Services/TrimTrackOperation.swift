// TrimTrackOperation.swift
//
// Time-based trim of a track:  drop every TrackPoint whose
// timestamp falls outside the kept window.  Per D-018 the dialog
// surfaces two optional bounds — "trim start before <time>" and
// "trim end after <time>" — and the operation honors whichever
// bounds the user enabled.  Both nil means "keep everything" (a
// no-op);  one or both bounds means drop the points that fall
// outside.
//
// Bound semantics:
//   - `trimStartBefore`:  drop every point whose timestamp is
//     STRICTLY less than this.  Points exactly at the boundary
//     stay.  Reads as "trim until time X" — at X you're keeping.
//   - `trimEndAfter`:  drop every point whose timestamp is
//     STRICTLY greater than this.  Points exactly at the boundary
//     stay.  Reads as "trim everything after time Y" — Y itself is
//     the last kept point.
//
// Untimestamped points (TrackPoint.time == nil) are KEPT.  They
// have no time to compare against the bounds, and dropping them
// would conflate "outside the time window" with "no time recorded"
// — different concerns.  In practice these come from editing
// operations that synthesized points (Add Detail Brush at M9) or
// from imports where the source GPX omitted `<time>`;  trim-by-time
// shouldn't disturb either.
//
// Empty segments after trim are PRESERVED, not pruned.  Identity
// matters for undo:  the prior session's segments[i].id has to
// still exist after undo replays so any UI surface that holds onto
// a segment id (selection, inspector pin, future bookmark) doesn't
// dangle.  Pruning empty segments would force the undo path to
// re-create them with their original ids preserved, which is a
// fragile invariant to maintain.  Keeping the empty-segment shell
// in place is the simpler correctness guarantee.
//
// Selection-aware:  this operation takes a single trackId, not a
// selection.  The directive (D-018) mentions "trim within a
// selected range" as an option;  v1 implements only the simpler
// "trim the whole track" form.  Per-selection-range trim is in the
// deferred parking lot — the selection-aware semantic adds two
// design choices (does selection narrow the trim's scope or
// override the time-based one?) that aren't worth pinning down
// before a real use case surfaces.
//
// Edge cases (no-op behaviour, matching the stale-references-
// tolerated pattern):
//   - Both bounds nil:  no-op.
//   - Stale trackId:  no-op.
//   - Track has no timestamped points at all:  trim has nothing to
//     act on for either bound;  no points are dropped (every point
//     is untimestamped and therefore kept).  The dialog should
//     gate on this BEFORE opening — there's nothing for the user
//     to set — but the operation tolerates the case if it does
//     get invoked.
//
// Per CONVENTIONS.md "platform-agnostic data layer," Foundation only.

import Foundation

public enum TrimTrackOperation {

    public static func apply(
        to session: GPXSession,
        trackId: UUID,
        trimStartBefore: Date?,
        trimEndAfter: Date?
    ) -> (session: GPXSession, touched: [TouchedTrack]) {

        // Both bounds nil — no-op.  Detected at the operation
        // boundary so callers don't have to special-case it.
        if trimStartBefore == nil && trimEndAfter == nil {
            return (session, [])
        }

        guard let trackIndex = session.tracks.firstIndex(where: { $0.id == trackId }) else {
            return (session, [])
        }

        var newSession = session
        var track = newSession.tracks[trackIndex]
        var anyChange = false

        for segmentIndex in track.segments.indices {
            let originalPoints = track.segments[segmentIndex].points
            let kept = originalPoints.filter { point in
                shouldKeep(point: point, startBefore: trimStartBefore, endAfter: trimEndAfter)
            }
            if kept.count != originalPoints.count {
                track.segments[segmentIndex].points = kept
                anyChange = true
            }
        }

        if !anyChange {
            // Bounds were set but didn't actually drop anything
            // (every timestamped point fell within the kept window;
            // any untimestamped points were kept by the rule above).
            // Empty touched-list signals the caller to skip the
            // undo entry.
            return (session, [])
        }

        newSession.tracks[trackIndex] = track
        return (newSession, [TouchedTrack(trackId: trackId)])
    }

    /// Compute the (track, segment, indices) groups of points that
    /// would be dropped if `apply` ran with these bounds.  Used by
    /// the dialog's live-preview overlay (the user sees the to-be-
    /// dropped points highlighted in red as they adjust the time
    /// bounds).
    ///
    /// The grouped shape mirrors `Selection.SegmentGroup` so the
    /// JS-side preview renderer can re-use the highlight machinery
    /// — same wire shape, different style on the marker.
    public static func pointsToRemove(
        in session: GPXSession,
        trackId: UUID,
        trimStartBefore: Date?,
        trimEndAfter: Date?
    ) -> [PreviewGroup] {
        if trimStartBefore == nil && trimEndAfter == nil { return [] }
        guard let track = session.tracks.first(where: { $0.id == trackId }) else { return [] }

        var groups: [PreviewGroup] = []
        for segment in track.segments {
            var indices: [Int] = []
            for (i, point) in segment.points.enumerated() {
                if !shouldKeep(point: point, startBefore: trimStartBefore, endAfter: trimEndAfter) {
                    indices.append(i)
                }
            }
            if !indices.isEmpty {
                groups.append(PreviewGroup(
                    trackId: trackId,
                    segmentId: segment.id,
                    pointIndices: indices
                ))
            }
        }
        return groups
    }

    /// Earliest and latest timestamp among a track's points, or nil
    /// if no point has a timestamp.  Used by the trim dialog to
    /// pre-fill the DatePicker bounds and to gate the "Trim Track…"
    /// menu item:  a track with no timestamps has nothing to trim.
    public static func timestampRange(of trackId: UUID, in session: GPXSession) -> ClosedRange<Date>? {
        guard let track = session.tracks.first(where: { $0.id == trackId }) else { return nil }
        var earliest: Date? = nil
        var latest: Date? = nil
        for segment in track.segments {
            for point in segment.points {
                guard let t = point.time else { continue }
                if earliest == nil || t < earliest! { earliest = t }
                if latest == nil || t > latest! { latest = t }
            }
        }
        guard let lo = earliest, let hi = latest else { return nil }
        // ClosedRange requires lower <= upper.  In a properly-
        // recorded track lo <= hi always;  if the data is
        // pathological (somehow a point's time precedes another
        // earlier point's time) we still want to surface a sensible
        // range, so clamp into a valid order.
        if lo > hi { return hi...lo }
        return lo...hi
    }

    // MARK: - Internals

    private static func shouldKeep(
        point: TrackPoint,
        startBefore: Date?,
        endAfter: Date?
    ) -> Bool {
        guard let t = point.time else {
            // Untimestamped points are always kept — see file header.
            return true
        }
        if let s = startBefore, t < s { return false }
        if let e = endAfter, t > e { return false }
        return true
    }

    public struct TouchedTrack: Equatable, Sendable {
        public let trackId: UUID

        public init(trackId: UUID) {
            self.trackId = trackId
        }
    }

    /// One (track, segment) group of point indices that would be
    /// dropped by the proposed trim.  Used by the live-preview
    /// pipeline;  the wire shape mirrors `Selection.SegmentGroup`
    /// so the JS renderer can re-use existing per-point overlay
    /// machinery if it wants to.
    public struct PreviewGroup: Equatable, Sendable {
        public let trackId: UUID
        public let segmentId: UUID
        public let pointIndices: [Int]

        public init(trackId: UUID, segmentId: UUID, pointIndices: [Int]) {
            self.trackId = trackId
            self.segmentId = segmentId
            self.pointIndices = pointIndices
        }
    }
}
