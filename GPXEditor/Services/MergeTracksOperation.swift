// MergeTracksOperation.swift
//
// Merge a source track into a destination track.  The source's
// segments are appended (in order) to the destination's segments;
// the source's waypoints are appended to the destination's
// waypoints;  the source track is removed from the session.  The
// destination keeps its identity (id, name, role, recordedDate,
// immutableOriginalBytes).
//
// "Merge Track INTO this one" is the directional reading:
//   - Selection identifies the destination — "this one".
//   - The user picks the source from a sheet — "the second track."
//   - Source dissolves into destination;  destination wins on every
//     property other than the appended segments and waypoints.
//
// Why destination wins on identity:
//   - The user invoked the operation while operating on the
//     destination (its point was selected).  That establishes the
//     destination as the "subject" of the edit.
//   - Source's role (master / subsidiary) is dropped.  If the user
//     wanted the resulting track to be the master, they would have
//     selected on the master-track side.  Auto-elevating the merged
//     result to master based on either side's role would be
//     surprising;  better to keep the destination's role and let
//     the user re-tag if needed (M9 introduces the master/subsidiary
//     UI affordance).
//   - Source's immutableOriginalBytes are dropped.  Reset to
//     Original on the merged track restores the destination's pre-
//     merge state — undoes the merge as part of restoring the
//     destination's full original recording.  The source's bytes
//     are not preserved separately;  if the user wants to undo the
//     merge specifically, ⌘Z is the path.  This matches the
//     "immutableOriginalBytes is the source-of-record for THIS
//     track" semantics — once two tracks merge, only one history
//     can survive at the bytes layer.
//   - Source's recordedDate is dropped.  The merged track was
//     "recorded" on the destination's date;  picking the earliest
//     of the two dates would be plausible but adds policy where
//     "destination wins" is simpler and consistent with the rest of
//     the property-resolution rule.
//
// Segment / waypoint preservation:
//   - Source segments are appended whole-cloth to destination's
//     segment array.  Each segment keeps its id, name, color, and
//     points.  No segment cuts;  the merge is purely concatenation.
//   - Source waypoints are appended to destination's waypoint
//     array.  Each waypoint keeps its id, name, sym, lat/lon,
//     elevation, time, description.
//
// Edge cases (no-op):
//   - source == destination:  can't merge a track with itself.
//   - Stale source or destination id:  no-op.
//
// Per CONVENTIONS.md "platform-agnostic data layer," Foundation only.

import Foundation

public enum MergeTracksOperation {

    public static func apply(
        to session: GPXSession,
        sourceTrackId: UUID,
        destinationTrackId: UUID
    ) -> (session: GPXSession, touched: [TouchedTrack]) {

        // Self-merge is a no-op.  If we didn't reject this here we'd
        // end up duplicating every segment of the track into itself
        // and then removing the track entirely (because both indices
        // would point at the same array slot), corrupting state.
        if sourceTrackId == destinationTrackId {
            return (session, [])
        }

        guard let sourceIndex = session.tracks.firstIndex(where: { $0.id == sourceTrackId }) else {
            return (session, [])
        }
        guard let destinationIndex = session.tracks.firstIndex(where: { $0.id == destinationTrackId }) else {
            return (session, [])
        }

        var newSession = session
        let source = newSession.tracks[sourceIndex]

        // Append source's segments and waypoints to the destination.
        // Take the destination by value, mutate, write back, then
        // remove the source — order matters because removing the
        // source first would shift the destinationIndex if the
        // source was earlier in the array.
        var destination = newSession.tracks[destinationIndex]
        destination.segments.append(contentsOf: source.segments)
        destination.waypoints.append(contentsOf: source.waypoints)
        newSession.tracks[destinationIndex] = destination

        // Now remove the source.  We re-find its index to be safe
        // against the (currently impossible) scenario where the
        // append above changed the array shape.
        if let recheckedSourceIndex = newSession.tracks.firstIndex(where: { $0.id == sourceTrackId }) {
            newSession.tracks.remove(at: recheckedSourceIndex)
        }

        return (newSession, [TouchedTrack(trackId: destinationTrackId)])
    }

    public struct TouchedTrack: Equatable, Sendable {
        public let trackId: UUID

        public init(trackId: UUID) {
            self.trackId = trackId
        }
    }
}
