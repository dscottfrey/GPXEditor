// SplitTrackOperationTests.swift
//
// Coverage for SplitTrackOperation — divides a track into two at a
// named point.  The point becomes the first point of the new
// (second) track's first segment;  the original track keeps
// everything before.

import Testing
import Foundation
@testable import GPXEditor

@Suite("SplitTrackOperation")
struct SplitTrackOperationTests {

    private func point(lat: Double, lon: Double, ele: Double? = nil, time: Date? = nil) -> TrackPoint {
        TrackPoint(latitude: lat, longitude: lon, elevation: ele, time: time)
    }

    private func makeSession(
        trackName: String = "Trail",
        segments: [Segment],
        waypoints: [Waypoint] = [],
        role: TrackRole? = nil,
        recordedDate: Date? = nil
    ) -> (GPXSession, Track) {
        let track = Track(
            id: UUID(),
            name: trackName,
            immutableOriginalBytes: Data([0x01, 0x02, 0x03]),
            segments: segments,
            waypoints: waypoints,
            role: role,
            recordedDate: recordedDate
        )
        return (GPXSession(metadata: ProjectMetadata(), tracks: [track]), track)
    }

    @Test("Mid-segment split: original keeps prefix, new track gets suffix")
    func midSegmentSplit() {
        let seg = Segment(id: UUID(), color: HexColor("#FF0000")!, points: [
            point(lat: 45.0, lon: -120.0),
            point(lat: 45.001, lon: -120.0),
            point(lat: 45.002, lon: -120.0),
            point(lat: 45.003, lon: -120.0),
            point(lat: 45.004, lon: -120.0),
        ])
        let (s, track) = makeSession(segments: [seg])

        let result = SplitTrackOperation.apply(
            to: s, trackId: track.id, segmentId: seg.id, pointIndex: 2
        )
        // Two tracks now.
        #expect(result.session.tracks.count == 2)
        // Original track keeps points [0..1].
        #expect(result.session.tracks[0].segments[0].points.map(\.latitude) == [45.0, 45.001])
        // New track has points [2..4].
        #expect(result.session.tracks[1].segments[0].points.map(\.latitude) == [45.002, 45.003, 45.004])
    }

    @Test("Original track id and segment id (pre-half) are preserved")
    func originalIdsPreserved() {
        let seg = Segment(id: UUID(), color: HexColor("#FF0000")!, points: [
            point(lat: 45.0, lon: -120.0),
            point(lat: 45.001, lon: -120.0),
            point(lat: 45.002, lon: -120.0),
        ])
        let (s, track) = makeSession(segments: [seg])

        let result = SplitTrackOperation.apply(
            to: s, trackId: track.id, segmentId: seg.id, pointIndex: 1
        )
        #expect(result.session.tracks[0].id == track.id)
        #expect(result.session.tracks[0].segments[0].id == seg.id)
        // New track and post-half segment get fresh ids.
        #expect(result.session.tracks[1].id != track.id)
        #expect(result.session.tracks[1].segments[0].id != seg.id)
    }

    @Test("Split at segment boundary (pointIndex == 0 of non-first segment)")
    func splitAtSegmentBoundary() {
        let seg1 = Segment(id: UUID(), color: HexColor("#FF0000")!, points: [
            point(lat: 45.0, lon: -120.0),
            point(lat: 45.001, lon: -120.0),
        ])
        let seg2 = Segment(id: UUID(), color: HexColor("#00FF00")!, points: [
            point(lat: 46.0, lon: -120.0),
            point(lat: 46.001, lon: -120.0),
            point(lat: 46.002, lon: -120.0),
        ])
        let (s, track) = makeSession(segments: [seg1, seg2])

        let result = SplitTrackOperation.apply(
            to: s, trackId: track.id, segmentId: seg2.id, pointIndex: 0
        )
        // Original keeps seg1 (intact, original id).
        #expect(result.session.tracks[0].segments.count == 1)
        #expect(result.session.tracks[0].segments[0].id == seg1.id)
        // New track gets seg2 whole-cloth (no cut, original id).
        #expect(result.session.tracks[1].segments.count == 1)
        #expect(result.session.tracks[1].segments[0].id == seg2.id)
        #expect(result.session.tracks[1].segments[0].points.map(\.latitude) == [46.0, 46.001, 46.002])
    }

    @Test("Multi-segment track: split mid-second-segment")
    func multiSegmentMidSplit() {
        let seg1 = Segment(id: UUID(), color: HexColor("#FF0000")!, points: [
            point(lat: 45.0, lon: -120.0),
            point(lat: 45.001, lon: -120.0),
        ])
        let seg2 = Segment(id: UUID(), color: HexColor("#00FF00")!, points: [
            point(lat: 46.0, lon: -120.0),
            point(lat: 46.001, lon: -120.0),
            point(lat: 46.002, lon: -120.0),
        ])
        let seg3 = Segment(id: UUID(), color: HexColor("#0000FF")!, points: [
            point(lat: 47.0, lon: -120.0),
        ])
        let (s, track) = makeSession(segments: [seg1, seg2, seg3])

        let result = SplitTrackOperation.apply(
            to: s, trackId: track.id, segmentId: seg2.id, pointIndex: 1
        )
        // Original: seg1 unchanged + seg2's pre-half (point 0).
        #expect(result.session.tracks[0].segments.count == 2)
        #expect(result.session.tracks[0].segments[0].id == seg1.id)
        #expect(result.session.tracks[0].segments[1].id == seg2.id)
        #expect(result.session.tracks[0].segments[1].points.map(\.latitude) == [46.0])
        // New track: seg2's post-half (points 1..2, fresh id) + seg3.
        #expect(result.session.tracks[1].segments.count == 2)
        #expect(result.session.tracks[1].segments[0].id != seg2.id)
        #expect(result.session.tracks[1].segments[0].points.map(\.latitude) == [46.001, 46.002])
        #expect(result.session.tracks[1].segments[1].id == seg3.id)
    }

    @Test("New track inherits color of post-half from the cut segment")
    func colorCarriesOver() {
        let seg = Segment(id: UUID(), color: HexColor("#ABCDEF")!, points: [
            point(lat: 45.0, lon: -120.0),
            point(lat: 45.001, lon: -120.0),
            point(lat: 45.002, lon: -120.0),
        ])
        let (s, track) = makeSession(segments: [seg])

        let result = SplitTrackOperation.apply(
            to: s, trackId: track.id, segmentId: seg.id, pointIndex: 1
        )
        #expect(result.session.tracks[1].segments[0].color == seg.color)
    }

    @Test("New track name is suffixed with (continued)")
    func nameSuffix() {
        let seg = Segment(id: UUID(), color: HexColor("#FF0000")!, points: [
            point(lat: 45.0, lon: -120.0),
            point(lat: 45.001, lon: -120.0),
            point(lat: 45.002, lon: -120.0),
        ])
        let (s, track) = makeSession(trackName: "Mt Hood Loop", segments: [seg])

        let result = SplitTrackOperation.apply(
            to: s, trackId: track.id, segmentId: seg.id, pointIndex: 1
        )
        #expect(result.session.tracks[0].name == "Mt Hood Loop")
        #expect(result.session.tracks[1].name == "Mt Hood Loop (continued)")
    }

    @Test("New track has empty original bytes (created by edit, not import)")
    func newTrackHasEmptyBytes() {
        let seg = Segment(id: UUID(), color: HexColor("#FF0000")!, points: [
            point(lat: 45.0, lon: -120.0),
            point(lat: 45.001, lon: -120.0),
            point(lat: 45.002, lon: -120.0),
        ])
        let (s, track) = makeSession(segments: [seg])

        let result = SplitTrackOperation.apply(
            to: s, trackId: track.id, segmentId: seg.id, pointIndex: 1
        )
        // Original keeps its bytes;  new track has none.
        #expect(result.session.tracks[0].immutableOriginalBytes == Data([0x01, 0x02, 0x03]))
        #expect(result.session.tracks[1].immutableOriginalBytes == Data())
    }

    @Test("Original track keeps role; new track has nil role")
    func roleNotInherited() {
        let seg = Segment(id: UUID(), color: HexColor("#FF0000")!, points: [
            point(lat: 45.0, lon: -120.0),
            point(lat: 45.001, lon: -120.0),
            point(lat: 45.002, lon: -120.0),
        ])
        let (s, track) = makeSession(segments: [seg], role: .master)

        let result = SplitTrackOperation.apply(
            to: s, trackId: track.id, segmentId: seg.id, pointIndex: 1
        )
        #expect(result.session.tracks[0].role == .master)
        #expect(result.session.tracks[1].role == nil)
    }

    @Test("recordedDate is inherited by the new track")
    func recordedDateInherited() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let seg = Segment(id: UUID(), color: HexColor("#FF0000")!, points: [
            point(lat: 45.0, lon: -120.0),
            point(lat: 45.001, lon: -120.0),
            point(lat: 45.002, lon: -120.0),
        ])
        let (s, track) = makeSession(segments: [seg], recordedDate: date)

        let result = SplitTrackOperation.apply(
            to: s, trackId: track.id, segmentId: seg.id, pointIndex: 1
        )
        #expect(result.session.tracks[0].recordedDate == date)
        #expect(result.session.tracks[1].recordedDate == date)
    }

    @Test("Waypoints all stay on the original track")
    func waypointsStayOnOriginal() {
        let seg = Segment(id: UUID(), color: HexColor("#FF0000")!, points: [
            point(lat: 45.0, lon: -120.0),
            point(lat: 45.001, lon: -120.0),
            point(lat: 45.002, lon: -120.0),
        ])
        let wp = Waypoint(
            latitude: 45.0015,
            longitude: -120.0,
            elevation: nil,
            time: nil,
            name: "Camp",
            sym: "Campsite",
            description: nil
        )
        let (s, track) = makeSession(segments: [seg], waypoints: [wp])

        let result = SplitTrackOperation.apply(
            to: s, trackId: track.id, segmentId: seg.id, pointIndex: 1
        )
        #expect(result.session.tracks[0].waypoints.count == 1)
        #expect(result.session.tracks[0].waypoints[0].id == wp.id)
        #expect(result.session.tracks[1].waypoints.isEmpty)
    }

    @Test("Touched list reports both tracks")
    func touchedListReportsBoth() {
        let seg = Segment(id: UUID(), color: HexColor("#FF0000")!, points: [
            point(lat: 45.0, lon: -120.0),
            point(lat: 45.001, lon: -120.0),
            point(lat: 45.002, lon: -120.0),
        ])
        let (s, track) = makeSession(segments: [seg])

        let result = SplitTrackOperation.apply(
            to: s, trackId: track.id, segmentId: seg.id, pointIndex: 1
        )
        #expect(result.touched.count == 2)
        #expect(result.touched.contains(SplitTrackOperation.TouchedTrack(trackId: track.id)))
        // Other id is the new track's freshly generated id.
        let newId = result.session.tracks[1].id
        #expect(result.touched.contains(SplitTrackOperation.TouchedTrack(trackId: newId)))
    }

    @Test("New track is inserted immediately after the original")
    func newTrackInsertedAfter() {
        let seg1 = Segment(id: UUID(), color: HexColor("#FF0000")!, points: [
            point(lat: 45.0, lon: -120.0),
            point(lat: 45.001, lon: -120.0),
            point(lat: 45.002, lon: -120.0),
        ])
        let trackA = Track(id: UUID(), name: "A", immutableOriginalBytes: Data(), segments: [seg1])
        let trackB = Track(id: UUID(), name: "B", immutableOriginalBytes: Data(), segments: [
            Segment(id: UUID(), color: HexColor("#00FF00")!, points: [
                point(lat: 46.0, lon: -120.0),
            ]),
        ])
        let trackC = Track(id: UUID(), name: "C", immutableOriginalBytes: Data(), segments: [
            Segment(id: UUID(), color: HexColor("#0000FF")!, points: [
                point(lat: 47.0, lon: -120.0),
            ]),
        ])
        let s = GPXSession(metadata: ProjectMetadata(), tracks: [trackA, trackB, trackC])

        let result = SplitTrackOperation.apply(
            to: s, trackId: trackB.id, segmentId: trackB.segments[0].id, pointIndex: 0  // segments must have 2 points to split mid;  use boundary instead
        )
        // Boundary case at index 0 of first segment is a no-op — pick a real split.
        // Re-do with a 3-point segment in B.
        let segB = Segment(id: UUID(), color: HexColor("#00FF00")!, points: [
            point(lat: 46.0, lon: -120.0),
            point(lat: 46.001, lon: -120.0),
            point(lat: 46.002, lon: -120.0),
        ])
        let trackB2 = Track(id: UUID(), name: "B", immutableOriginalBytes: Data(), segments: [segB])
        let s2 = GPXSession(metadata: ProjectMetadata(), tracks: [trackA, trackB2, trackC])
        let result2 = SplitTrackOperation.apply(
            to: s2, trackId: trackB2.id, segmentId: segB.id, pointIndex: 1
        )
        // Order should be [A, B, B-continued, C].
        #expect(result2.session.tracks.count == 4)
        #expect(result2.session.tracks[0].id == trackA.id)
        #expect(result2.session.tracks[1].id == trackB2.id)
        #expect(result2.session.tracks[2].name == "B (continued)")
        #expect(result2.session.tracks[3].id == trackC.id)
        // Suppress unused result warning from the boundary-case probe above.
        _ = result
    }

    @Test("pointIndex == 0 in segment 0 is a no-op")
    func leadingEdgeNoOp() {
        let seg = Segment(id: UUID(), color: HexColor("#FF0000")!, points: [
            point(lat: 45.0, lon: -120.0),
            point(lat: 45.001, lon: -120.0),
            point(lat: 45.002, lon: -120.0),
        ])
        let (s, track) = makeSession(segments: [seg])
        let result = SplitTrackOperation.apply(
            to: s, trackId: track.id, segmentId: seg.id, pointIndex: 0
        )
        #expect(result.touched.isEmpty)
        #expect(result.session == s)
    }

    @Test("pointIndex at the very last point is a no-op")
    func trailingEdgeNoOp() {
        let seg = Segment(id: UUID(), color: HexColor("#FF0000")!, points: [
            point(lat: 45.0, lon: -120.0),
            point(lat: 45.001, lon: -120.0),
            point(lat: 45.002, lon: -120.0),
        ])
        let (s, track) = makeSession(segments: [seg])
        let result = SplitTrackOperation.apply(
            to: s, trackId: track.id, segmentId: seg.id, pointIndex: 2
        )
        #expect(result.touched.isEmpty)
        #expect(result.session == s)
    }

    @Test("Stale trackId is a no-op")
    func staleTrackId() {
        let seg = Segment(id: UUID(), color: HexColor("#FF0000")!, points: [
            point(lat: 45.0, lon: -120.0),
            point(lat: 45.001, lon: -120.0),
            point(lat: 45.002, lon: -120.0),
        ])
        let (s, _) = makeSession(segments: [seg])
        let result = SplitTrackOperation.apply(
            to: s, trackId: UUID(), segmentId: seg.id, pointIndex: 1
        )
        #expect(result.touched.isEmpty)
        #expect(result.session == s)
    }

    @Test("Stale segmentId is a no-op")
    func staleSegmentId() {
        let seg = Segment(id: UUID(), color: HexColor("#FF0000")!, points: [
            point(lat: 45.0, lon: -120.0),
            point(lat: 45.001, lon: -120.0),
            point(lat: 45.002, lon: -120.0),
        ])
        let (s, track) = makeSession(segments: [seg])
        let result = SplitTrackOperation.apply(
            to: s, trackId: track.id, segmentId: UUID(), pointIndex: 1
        )
        #expect(result.touched.isEmpty)
        #expect(result.session == s)
    }

    @Test("Out-of-range pointIndex is a no-op")
    func outOfRangePointIndex() {
        let seg = Segment(id: UUID(), color: HexColor("#FF0000")!, points: [
            point(lat: 45.0, lon: -120.0),
            point(lat: 45.001, lon: -120.0),
        ])
        let (s, track) = makeSession(segments: [seg])
        let result = SplitTrackOperation.apply(
            to: s, trackId: track.id, segmentId: seg.id, pointIndex: 99
        )
        #expect(result.touched.isEmpty)
        #expect(result.session == s)
    }

    @Test("Last-point-of-segment with content ahead is NOT a no-op")
    func lastPointButMoreSegmentsAhead() {
        // Splitting at the last point of seg1 when seg2 has content
        // should produce two tracks:  original keeps seg1 minus its
        // last point + nothing else;  new track gets just-the-last-
        // point + seg2.
        let seg1 = Segment(id: UUID(), color: HexColor("#FF0000")!, points: [
            point(lat: 45.0, lon: -120.0),
            point(lat: 45.001, lon: -120.0),
            point(lat: 45.002, lon: -120.0),
        ])
        let seg2 = Segment(id: UUID(), color: HexColor("#00FF00")!, points: [
            point(lat: 46.0, lon: -120.0),
        ])
        let (s, track) = makeSession(segments: [seg1, seg2])
        let result = SplitTrackOperation.apply(
            to: s, trackId: track.id, segmentId: seg1.id, pointIndex: 2
        )
        #expect(result.touched.count == 2)
        #expect(result.session.tracks[0].segments[0].points.map(\.latitude) == [45.0, 45.001])
        #expect(result.session.tracks[1].segments.count == 2)
        #expect(result.session.tracks[1].segments[0].points.map(\.latitude) == [45.002])
        #expect(result.session.tracks[1].segments[1].id == seg2.id)
    }
}
