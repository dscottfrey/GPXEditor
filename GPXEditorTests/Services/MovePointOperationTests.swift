// MovePointOperationTests.swift
//
// Coverage for MovePointOperation — moves a single track point to a
// new (lat, lon) while preserving its elevation and timestamp.

import Testing
import Foundation
@testable import GPXEditor

@Suite("MovePointOperation")
struct MovePointOperationTests {

    private func point(lat: Double, lon: Double, ele: Double? = nil, time: Date? = nil) -> TrackPoint {
        TrackPoint(latitude: lat, longitude: lon, elevation: ele, time: time)
    }

    private func makeFixture() -> (GPXSession, Track, Segment) {
        let segment = Segment(id: UUID(), color: HexColor("#FF0000")!, points: [
            point(lat: 45.0, lon: -120.0, ele: 100, time: Date(timeIntervalSince1970: 1_700_000_000)),
            point(lat: 45.001, lon: -120.0, ele: 110, time: Date(timeIntervalSince1970: 1_700_000_010)),
            point(lat: 45.002, lon: -120.0, ele: 120, time: Date(timeIntervalSince1970: 1_700_000_020)),
        ])
        let track = Track(id: UUID(), name: "T", immutableOriginalBytes: Data(), segments: [segment])
        return (GPXSession(metadata: ProjectMetadata(), tracks: [track]), track, segment)
    }

    @Test("Moves the point to the new lat/lon")
    func moveBasic() {
        let (s, track, segment) = makeFixture()
        let result = MovePointOperation.apply(
            to: s, trackId: track.id, segmentId: segment.id, pointIndex: 1,
            latitude: 45.5, longitude: -119.5
        )
        #expect(result.touched.count == 1)
        let moved = result.session.tracks[0].segments[0].points[1]
        #expect(moved.latitude == 45.5)
        #expect(moved.longitude == -119.5)
    }

    @Test("Preserves elevation and timestamp on the moved point")
    func preservesMetadata() {
        let (s, track, segment) = makeFixture()
        let originalEle = s.tracks[0].segments[0].points[1].elevation
        let originalTime = s.tracks[0].segments[0].points[1].time

        let result = MovePointOperation.apply(
            to: s, trackId: track.id, segmentId: segment.id, pointIndex: 1,
            latitude: 45.5, longitude: -119.5
        )
        let moved = result.session.tracks[0].segments[0].points[1]
        #expect(moved.elevation == originalEle)
        #expect(moved.time == originalTime)
    }

    @Test("Other points in the segment are unchanged")
    func otherPointsUnchanged() {
        let (s, track, segment) = makeFixture()
        let result = MovePointOperation.apply(
            to: s, trackId: track.id, segmentId: segment.id, pointIndex: 1,
            latitude: 45.5, longitude: -119.5
        )
        #expect(result.session.tracks[0].segments[0].points[0] == s.tracks[0].segments[0].points[0])
        #expect(result.session.tracks[0].segments[0].points[2] == s.tracks[0].segments[0].points[2])
    }

    @Test("Same coordinates is a no-op (no touched entry)")
    func sameCoordinatesNoOp() {
        let (s, track, segment) = makeFixture()
        let p = s.tracks[0].segments[0].points[1]
        let result = MovePointOperation.apply(
            to: s, trackId: track.id, segmentId: segment.id, pointIndex: 1,
            latitude: p.latitude, longitude: p.longitude
        )
        #expect(result.touched.isEmpty)
        #expect(result.session == s)
    }

    @Test("Unknown track id is a no-op")
    func unknownTrack() {
        let (s, _, segment) = makeFixture()
        let result = MovePointOperation.apply(
            to: s, trackId: UUID(), segmentId: segment.id, pointIndex: 0,
            latitude: 45.5, longitude: -119.5
        )
        #expect(result.touched.isEmpty)
        #expect(result.session == s)
    }

    @Test("Out-of-range index is a no-op")
    func outOfRangeIndex() {
        let (s, track, segment) = makeFixture()
        let result = MovePointOperation.apply(
            to: s, trackId: track.id, segmentId: segment.id, pointIndex: 99,
            latitude: 45.5, longitude: -119.5
        )
        #expect(result.touched.isEmpty)
        #expect(result.session == s)
    }
}
