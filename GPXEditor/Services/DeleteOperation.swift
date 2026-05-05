// DeleteOperation.swift
//
// Pure-function delete:  given a session and a selection, return a new
// session with the selected points removed.  Doesn't touch undo, doesn't
// touch FileDocument, doesn't touch the bridge — those concerns live one
// layer up in `SessionViewModel.deleteSelected(...)`, which captures
// undo state, applies this function, and emits the bridge `update_tracks`
// notification.
//
// Two design choices worth surfacing here:
//
//   1. Empty segments (zero remaining points) are PRESERVED, not pruned.
//      Removing every point of a segment leaves the segment as an empty
//      shell with the same id and color.  Reasoning:  segment identity
//      is referenced by selection state, by the sidebar, by waypoint
//      grouping (M8), and conceptually by the user — turning "all
//      points deleted" into "segment vanished" surprises the user and
//      complicates undo (which would need to recreate the segment with
//      its prior id and color).  An empty segment is a degenerate
//      state that renders as nothing and exports as nothing, but it
//      still exists in the model.  An explicit "remove empty segments"
//      action can be added later if real use surfaces a need.
//
//   2. Empty tracks (zero remaining segments) are PRESERVED for the
//      same reason — track identity is the master/subsidiary anchor
//      and removing one would orphan that role.  Use the sidebar's
//      explicit "Remove Track" action (M8) when you mean to delete a
//      track, not Delete-all-points.
//
// Per CONVENTIONS.md "platform-agnostic data layer," this file is
// Foundation-only and never imports SwiftUI, AppKit, or WebKit.

import Foundation

/// The pure delete operation.  Stateless;  the namespace exists for
/// discoverability rather than instance state.
public enum DeleteOperation {

    /// Apply the delete to a session, removing every selected point.
    /// Returns the new session value plus the set of (track_id,
    /// segment_id) pairs that were touched — callers use the touched
    /// list to drive a targeted bridge `update_tracks` rather than
    /// re-broadcasting every track in the project.
    ///
    /// Index correctness:  selected indices are sorted in DESCENDING
    /// order before removal so each removal doesn't shift indices that
    /// haven't been processed yet.  A naive ascending pass would mis-
    /// remove because `remove(at: 3)` shifts what was at index 4 down
    /// to index 3, then the next `remove(at: 4)` removes the wrong
    /// point.
    public static func apply(
        to session: GPXSession,
        deleting selection: Selection
    ) -> (session: GPXSession, touched: [TouchedSegment]) {

        if selection.isEmpty {
            return (session, [])
        }

        // Group by track/segment for efficient mutation.  `Selection.grouped()`
        // already does the sorting and de-duplication we need.
        let groups = selection.grouped()

        // Build a lookup so we can find which indices to remove from
        // each segment without scanning the groups list per segment.
        var indicesByKey: [SegmentKey: [Int]] = [:]
        for g in groups {
            indicesByKey[SegmentKey(trackId: g.trackId, segmentId: g.segmentId)] = g.pointIndices
        }

        // Mutate a copy of the session.  GPXSession / Track / Segment
        // are value types, so this is genuine COW state-snapshot
        // semantics — the caller can keep the original around for
        // undo without aliasing concerns.
        var newSession = session
        var touched: [TouchedSegment] = []

        for trackIdx in newSession.tracks.indices {
            var track = newSession.tracks[trackIdx]
            var trackChanged = false

            for segIdx in track.segments.indices {
                let key = SegmentKey(trackId: track.id, segmentId: track.segments[segIdx].id)
                guard let indices = indicesByKey[key], !indices.isEmpty else { continue }

                // Sort descending so removals don't invalidate indices
                // that haven't been processed yet.  Filter to valid
                // indices defensively — a stale selection (e.g., from
                // a prior undo state) might reference an out-of-range
                // index, which we should silently ignore rather than
                // crash.
                let pointCount = track.segments[segIdx].points.count
                let validDescending = indices
                    .filter { $0 >= 0 && $0 < pointCount }
                    .sorted(by: >)

                if validDescending.isEmpty { continue }

                for i in validDescending {
                    track.segments[segIdx].points.remove(at: i)
                }
                trackChanged = true
                touched.append(TouchedSegment(trackId: track.id, segmentId: track.segments[segIdx].id))
            }

            if trackChanged {
                newSession.tracks[trackIdx] = track
            }
        }

        return (newSession, touched)
    }

    /// One (track, segment) pair affected by the delete.  Returned to
    /// the caller so a partial bridge update can re-broadcast only the
    /// changed tracks rather than the entire project state.
    public struct TouchedSegment: Equatable, Sendable {
        public let trackId: UUID
        public let segmentId: UUID

        public init(trackId: UUID, segmentId: UUID) {
            self.trackId = trackId
            self.segmentId = segmentId
        }
    }

    /// Internal lookup key.
    private struct SegmentKey: Hashable {
        let trackId: UUID
        let segmentId: UUID
    }
}
