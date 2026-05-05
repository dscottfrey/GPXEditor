// DeleteOperationTests.swift
//
// Coverage for DeleteOperation:  the pure-function delete that turns a
// (session, selection) pair into a new session with the selected
// points removed.  Tests the index-correctness property (descending-
// remove) explicitly, because a naive ascending-remove pass shifts
// indices and removes the wrong points — the kind of bug that
// silently corrupts user data.
//
// Also tests the M3 design choices around preservation:  empty segments
// stay (they're not pruned), empty tracks stay, and stale selection
// indices are silently ignored rather than crashing.

import Testing
import Foundation
@testable import GPXEditor

@Suite("DeleteOperation")
struct DeleteOperationTests {

    // MARK: - Fixture helpers

    private func point(_ lat: Double) -> TrackPoint {
        // lat doubles as a uniqueness marker so we can verify which
        // points were removed by inspecting remaining lats.
        TrackPoint(latitude: lat, longitude: 0)
    }

    private func session(tracks: [Track]) -> GPXSession {
        GPXSession(metadata: ProjectMetadata(), tracks: tracks)
    }

    private func makeTrack(
        name: String = "track",
        segments: [Segment]
    ) -> Track {
        Track(
            id: UUID(),
            name: name,
            immutableOriginalBytes: Data(),
            segments: segments
        )
    }

    private func makeSegment(points: [TrackPoint]) -> Segment {
        Segment(id: UUID(), color: HexColor("#FF0000")!, points: points)
    }

    private func ref(_ trackId: UUID, _ segmentId: UUID, _ index: Int) -> Selection.PointReference {
        Selection.PointReference(trackId: trackId, segmentId: segmentId, pointIndex: index)
    }

    // MARK: - Empty cases

    @Test("Empty selection is a no-op and reports no touched segments")
    func emptySelection() {
        let segment = makeSegment(points: [point(1), point(2), point(3)])
        let track = makeTrack(segments: [segment])
        let s = session(tracks: [track])

        let result = DeleteOperation.apply(to: s, deleting: Selection())

        #expect(result.touched.isEmpty)
        #expect(result.session == s)
    }

    // MARK: - Single-segment delete

    @Test("Deletes a single point at the requested index")
    func singlePointDelete() {
        let segment = makeSegment(points: [point(1), point(2), point(3)])
        let track = makeTrack(segments: [segment])
        let s = session(tracks: [track])

        let selection = Selection(points: [ref(track.id, segment.id, 1)])
        let result = DeleteOperation.apply(to: s, deleting: selection)

        let remaining = result.session.tracks[0].segments[0].points
        #expect(remaining.map(\.latitude) == [1, 3])
        #expect(result.touched == [DeleteOperation.TouchedSegment(trackId: track.id, segmentId: segment.id)])
    }

    @Test("Deletes multiple points in one segment using descending order (no index shift bug)")
    func multiPointDeleteSameSegment() {
        // The naive ascending-remove bug:  remove(at: 1) shifts what
        // was at 2 down to 1; remove(at: 2) then removes the wrong
        // point.  Test that deleting [1, 2] removes points at lat=2 and
        // lat=3 (the *original* indices), leaving [lat=1, lat=4].
        let segment = makeSegment(points: [point(1), point(2), point(3), point(4)])
        let track = makeTrack(segments: [segment])
        let s = session(tracks: [track])

        let selection = Selection(points: [
            ref(track.id, segment.id, 1),
            ref(track.id, segment.id, 2),
        ])
        let result = DeleteOperation.apply(to: s, deleting: selection)

        let remaining = result.session.tracks[0].segments[0].points
        #expect(remaining.map(\.latitude) == [1, 4])
    }

    // MARK: - Multi-segment delete

    @Test("Deletes across multiple segments and tracks; touched list is complete")
    func multiTrackDelete() {
        let segA1 = makeSegment(points: [point(10), point(11), point(12)])
        let segA2 = makeSegment(points: [point(20), point(21)])
        let trackA = makeTrack(name: "A", segments: [segA1, segA2])

        let segB1 = makeSegment(points: [point(30), point(31), point(32)])
        let trackB = makeTrack(name: "B", segments: [segB1])

        let s = session(tracks: [trackA, trackB])
        let selection = Selection(points: [
            ref(trackA.id, segA1.id, 0),
            ref(trackA.id, segA2.id, 1),
            ref(trackB.id, segB1.id, 2),
        ])

        let result = DeleteOperation.apply(to: s, deleting: selection)

        #expect(result.session.tracks[0].segments[0].points.map(\.latitude) == [11, 12])
        #expect(result.session.tracks[0].segments[1].points.map(\.latitude) == [20])
        #expect(result.session.tracks[1].segments[0].points.map(\.latitude) == [30, 31])

        // All three segments touched.  Order isn't guaranteed by the
        // operation contract;  check membership rather than equality.
        #expect(result.touched.count == 3)
        #expect(result.touched.contains(DeleteOperation.TouchedSegment(trackId: trackA.id, segmentId: segA1.id)))
        #expect(result.touched.contains(DeleteOperation.TouchedSegment(trackId: trackA.id, segmentId: segA2.id)))
        #expect(result.touched.contains(DeleteOperation.TouchedSegment(trackId: trackB.id, segmentId: segB1.id)))
    }

    // MARK: - Preservation rules

    @Test("Segment with all points deleted is preserved as empty (not pruned)")
    func emptySegmentPreserved() {
        let segment = makeSegment(points: [point(1), point(2)])
        let track = makeTrack(segments: [segment])
        let s = session(tracks: [track])

        let selection = Selection(points: [
            ref(track.id, segment.id, 0),
            ref(track.id, segment.id, 1),
        ])
        let result = DeleteOperation.apply(to: s, deleting: selection)

        // Segment still present, identity preserved.
        #expect(result.session.tracks[0].segments.count == 1)
        #expect(result.session.tracks[0].segments[0].id == segment.id)
        #expect(result.session.tracks[0].segments[0].points.isEmpty)
    }

    @Test("Track whose every segment goes empty is preserved (not pruned)")
    func emptyTrackPreserved() {
        let segment = makeSegment(points: [point(1)])
        let track = makeTrack(segments: [segment])
        let s = session(tracks: [track])

        let selection = Selection(points: [ref(track.id, segment.id, 0)])
        let result = DeleteOperation.apply(to: s, deleting: selection)

        #expect(result.session.tracks.count == 1)
        #expect(result.session.tracks[0].id == track.id)
    }

    // MARK: - Defensive guards

    @Test("Stale (out-of-range) indices are silently ignored, not fatal")
    func staleIndicesIgnored() {
        let segment = makeSegment(points: [point(1), point(2)])
        let track = makeTrack(segments: [segment])
        let s = session(tracks: [track])

        let selection = Selection(points: [
            ref(track.id, segment.id, 0),
            ref(track.id, segment.id, 999),  // stale — segment only has 2 points
        ])
        let result = DeleteOperation.apply(to: s, deleting: selection)

        // The valid index 0 was removed;  the stale 999 was skipped.
        #expect(result.session.tracks[0].segments[0].points.map(\.latitude) == [2])
    }

    @Test("Selection referencing an unknown track id is a no-op")
    func unknownTrackIgnored() {
        let segment = makeSegment(points: [point(1), point(2)])
        let track = makeTrack(segments: [segment])
        let s = session(tracks: [track])

        let selection = Selection(points: [ref(UUID(), segment.id, 0)])
        let result = DeleteOperation.apply(to: s, deleting: selection)

        #expect(result.session == s)
        #expect(result.touched.isEmpty)
    }
}
