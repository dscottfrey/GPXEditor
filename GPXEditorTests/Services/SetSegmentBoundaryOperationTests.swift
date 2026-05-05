// SetSegmentBoundaryOperationTests.swift
//
// Coverage for SetSegmentBoundaryOperation — splits a segment into
// two at the named point.  The point becomes the first point of the
// new segment;  the original segment shrinks to [0..pointIndex - 1].

import Testing
import Foundation
@testable import GPXEditor

@Suite("SetSegmentBoundaryOperation")
struct SetSegmentBoundaryOperationTests {

    private func point(lat: Double, lon: Double) -> TrackPoint {
        TrackPoint(latitude: lat, longitude: lon)
    }

    private func makeFixture(points: [TrackPoint]) -> (GPXSession, Track, Segment) {
        let segment = Segment(id: UUID(), color: HexColor("#FF0000")!, points: points)
        let track = Track(id: UUID(), name: "T", immutableOriginalBytes: Data(), segments: [segment])
        return (GPXSession(metadata: ProjectMetadata(), tracks: [track]), track, segment)
    }

    @Test("Splits the segment at the named point")
    func basicSplit() {
        let (s, track, segment) = makeFixture(points: [
            point(lat: 45.0, lon: -120.0),
            point(lat: 45.001, lon: -120.0),
            point(lat: 45.002, lon: -120.0),
            point(lat: 45.003, lon: -120.0),
            point(lat: 45.004, lon: -120.0),
        ])

        let result = SetSegmentBoundaryOperation.apply(
            to: s, trackId: track.id, segmentId: segment.id, pointIndex: 2
        )
        let segs = result.session.tracks[0].segments
        #expect(segs.count == 2)
        #expect(segs[0].points.map(\.latitude) == [45.0, 45.001])
        #expect(segs[1].points.map(\.latitude) == [45.002, 45.003, 45.004])
    }

    @Test("Original segment id is preserved on the first half; new segment gets a fresh id")
    func idPreservation() {
        let (s, track, segment) = makeFixture(points: [
            point(lat: 45.0, lon: -120.0),
            point(lat: 45.001, lon: -120.0),
            point(lat: 45.002, lon: -120.0),
        ])

        let result = SetSegmentBoundaryOperation.apply(
            to: s, trackId: track.id, segmentId: segment.id, pointIndex: 1
        )
        #expect(result.session.tracks[0].segments[0].id == segment.id)
        #expect(result.session.tracks[0].segments[1].id != segment.id)
    }

    @Test("Color is carried over to the new segment")
    func colorCarriesOver() {
        let (s, track, segment) = makeFixture(points: [
            point(lat: 45.0, lon: -120.0),
            point(lat: 45.001, lon: -120.0),
            point(lat: 45.002, lon: -120.0),
        ])
        let result = SetSegmentBoundaryOperation.apply(
            to: s, trackId: track.id, segmentId: segment.id, pointIndex: 1
        )
        #expect(result.session.tracks[0].segments[1].color == segment.color)
    }

    @Test("pointIndex == 0 is a no-op (would produce empty original segment)")
    func zeroIndexNoOp() {
        let (s, track, segment) = makeFixture(points: [
            point(lat: 45.0, lon: -120.0),
            point(lat: 45.001, lon: -120.0),
            point(lat: 45.002, lon: -120.0),
        ])
        let result = SetSegmentBoundaryOperation.apply(
            to: s, trackId: track.id, segmentId: segment.id, pointIndex: 0
        )
        #expect(result.touched.isEmpty)
        #expect(result.session == s)
    }

    @Test("Out-of-range pointIndex is a no-op")
    func outOfRange() {
        let (s, track, segment) = makeFixture(points: [
            point(lat: 45.0, lon: -120.0),
            point(lat: 45.001, lon: -120.0),
        ])
        let result = SetSegmentBoundaryOperation.apply(
            to: s, trackId: track.id, segmentId: segment.id, pointIndex: 99
        )
        #expect(result.touched.isEmpty)
        #expect(result.session == s)
    }

    @Test("Two-segment touched list reports both segments")
    func bothTouched() {
        let (s, track, segment) = makeFixture(points: [
            point(lat: 45.0, lon: -120.0),
            point(lat: 45.001, lon: -120.0),
            point(lat: 45.002, lon: -120.0),
        ])
        let result = SetSegmentBoundaryOperation.apply(
            to: s, trackId: track.id, segmentId: segment.id, pointIndex: 1
        )
        #expect(result.touched.count == 2)
    }
}
