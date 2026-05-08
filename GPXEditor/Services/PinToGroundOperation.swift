// PinToGroundOperation.swift
//
// Pure-function "replace each named point's elevation with a new value"
// — the model-layer commit step of M7's Pin to Ground / Snap to Ground
// features.
//
// The network call to OpenTopoData is NOT this operation's concern.
// `Services/ElevationService.swift` is the async client that fetches
// elevations;  this operation accepts already-resolved values and
// applies them to the session.  Splitting the two keeps this layer
// pure (Foundation only, fully unit-testable, no network) and lets
// SessionViewModel coordinate the network → operation handoff with
// progress reporting and undo registration in one place.
//
// Inputs:
//   - The session to mutate.
//   - A list of PointReference (track, segment, index triples) naming
//     the points to update.
//   - A parallel array of new elevation values.  An entry of `nil`
//     means "the elevation lookup returned no value for this point" —
//     the point is left untouched (its existing elevation stays).
//
// Behavior:
//   - For each (reference, elevation) pair where the reference
//     resolves AND the elevation is non-nil AND the new value differs
//     from the existing one:  the point's `elevation` is replaced.
//     Lat / lon / time are preserved.
//   - Stale references (track / segment / index that no longer
//     resolves in the session) are silently ignored.  This matches
//     the stale-tolerance pattern DeleteOperation, MovePointOperation,
//     and the M6 operations all use:  selection state can drift
//     between gesture and commit, especially across undo boundaries,
//     and crashing on stale data would be hostile.
//   - If the elevations array is shorter than the references array,
//     the trailing references are processed as if their elevations
//     were nil (no update).  Symmetric:  trailing elevations beyond
//     the references count are simply ignored.  Defensive — the
//     caller (SessionViewModel.applyPinToGround) is supposed to
//     pass parallel arrays, but a length mismatch shouldn't crash;
//     the worst-case behavior is "fewer points get updated than the
//     user expected," visible immediately in the UI.
//   - No-op same-elevation:  if the new elevation equals the existing
//     one (within strict equality), the point is not rewritten and
//     the segment is not added to the touched list.  Avoids spurious
//     undo entries when Pin to Ground is run on a track whose
//     elevations are already accurate.
//
// Per CONVENTIONS.md "platform-agnostic data layer," Foundation only.

import Foundation

public enum PinToGroundOperation {

    /// Apply elevation updates to the named points.  Returns the new
    /// session and the list of segments that actually changed (used
    /// to scope the `update_tracks` broadcast — segments whose points
    /// were untouched don't need to be re-rendered).
    ///
    /// - Parameters:
    ///   - session: The session before the update.
    ///   - references: The points to update, identified positionally.
    ///   - newElevations: Parallel to `references`.  A nil entry means
    ///     "no elevation available for this point" — the point is left
    ///     untouched.  See file header for length-mismatch handling.
    public static func apply(
        to session: GPXSession,
        references: [Selection.PointReference],
        newElevations: [Double?]
    ) -> (session: GPXSession, touched: [TouchedSegment]) {

        var newSession = session

        // Touched segments are collected as a Set keyed by (trackId,
        // segmentId) to dedupe — Pin to Ground typically updates many
        // points across the same handful of segments, and we don't
        // want to re-broadcast the same segment N times.
        var touchedSet: Set<TouchedSegment> = []

        // Walk references in lock-step with elevations.  Length mismatch
        // is handled by zipping (Swift's `zip` truncates to the shorter
        // sequence) — see file header for why this is intentional.
        for (ref, newEle) in zip(references, newElevations) {

            guard let newEle = newEle else { continue }  // no value → skip

            guard let trackIndex = newSession.tracks.firstIndex(where: { $0.id == ref.trackId }) else {
                continue  // stale track id → skip
            }
            var track = newSession.tracks[trackIndex]
            guard let segmentIndex = track.segments.firstIndex(where: { $0.id == ref.segmentId }) else {
                continue  // stale segment id → skip
            }
            var segment = track.segments[segmentIndex]
            guard ref.pointIndex >= 0, ref.pointIndex < segment.points.count else {
                continue  // stale index → skip
            }

            var point = segment.points[ref.pointIndex]
            if point.elevation == newEle {
                continue  // no-op same value → don't dirty the segment
            }
            point.elevation = newEle
            // lat / lon / time are preserved — see file header.
            segment.points[ref.pointIndex] = point
            track.segments[segmentIndex] = segment
            newSession.tracks[trackIndex] = track

            touchedSet.insert(TouchedSegment(trackId: ref.trackId, segmentId: ref.segmentId))
        }

        // Sort the touched list for deterministic output (helps tests
        // and makes the update_tracks broadcast order predictable
        // across runs).  Order is by trackId then segmentId UUID
        // string — arbitrary but stable.
        let touched = touchedSet.sorted { lhs, rhs in
            if lhs.trackId != rhs.trackId {
                return lhs.trackId.uuidString < rhs.trackId.uuidString
            }
            return lhs.segmentId.uuidString < rhs.segmentId.uuidString
        }
        return (newSession, touched)
    }

    /// Mirror of MovePointOperation.TouchedSegment / SimplifyBrush.TouchedSegment.
    /// Same shape across operations so the bridge update_tracks broadcast
    /// path is uniform.
    public struct TouchedSegment: Hashable, Sendable {
        public let trackId: UUID
        public let segmentId: UUID

        public init(trackId: UUID, segmentId: UUID) {
            self.trackId = trackId
            self.segmentId = segmentId
        }
    }
}
