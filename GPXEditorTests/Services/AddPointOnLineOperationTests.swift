// AddPointOnLineOperationTests.swift
//
// Coverage for AddPointOnLineOperation — inserts a new track point
// between two existing points, with elevation and time linearly
// interpolated when both anchors have those values.

import Testing
import Foundation
@testable import GPXEditor

@Suite("AddPointOnLineOperation")
struct AddPointOnLineOperationTests {

    private func point(lat: Double, lon: Double, ele: Double? = nil, time: Date? = nil) -> TrackPoint {
        TrackPoint(latitude: lat, longitude: lon, elevation: ele, time: time)
    }

    private func makeFixture(points: [TrackPoint]) -> (GPXSession, Track, Segment) {
        let segment = Segment(id: UUID(), color: HexColor("#FF0000")!, points: points)
        let track = Track(id: UUID(), name: "T", immutableOriginalBytes: Data(), segments: [segment])
        return (GPXSession(metadata: ProjectMetadata(), tracks: [track]), track, segment)
    }

    @Test("Inserts the new point at afterIndex+1 with the supplied lat/lon")
    func insertBasic() {
        let (s, track, segment) = makeFixture(points: [
            point(lat: 45.0, lon: -120.0),
            point(lat: 45.002, lon: -120.0),
        ])
        let result = AddPointOnLineOperation.apply(
            to: s, trackId: track.id, segmentId: segment.id,
            afterIndex: 0, latitude: 45.001, longitude: -120.0
        )
        let pts = result.session.tracks[0].segments[0].points
        #expect(pts.count == 3)
        #expect(pts[0].latitude == 45.0)
        #expect(pts[1].latitude == 45.001)  // newly inserted
        #expect(pts[1].longitude == -120.0)
        #expect(pts[2].latitude == 45.002)
        #expect(result.touched.count == 1)
    }

    @Test("Linearly interpolates elevation between anchors when both have it")
    func interpolatesElevation() {
        let (s, track, segment) = makeFixture(points: [
            point(lat: 45.0, lon: -120.0, ele: 100),
            point(lat: 45.002, lon: -120.0, ele: 200),
        ])
        let result = AddPointOnLineOperation.apply(
            to: s, trackId: track.id, segmentId: segment.id,
            afterIndex: 0, latitude: 45.001, longitude: -120.0
        )
        let inserted = result.session.tracks[0].segments[0].points[1]
        #expect(inserted.elevation == 150)
    }

    @Test("Inserted elevation falls back when only one anchor has it")
    func elevationFallback() {
        let (s, track, segment) = makeFixture(points: [
            point(lat: 45.0, lon: -120.0, ele: 100),
            point(lat: 45.002, lon: -120.0, ele: nil),
        ])
        let result = AddPointOnLineOperation.apply(
            to: s, trackId: track.id, segmentId: segment.id,
            afterIndex: 0, latitude: 45.001, longitude: -120.0
        )
        // Only the "before" anchor had elevation;  inserted point
        // takes 100.
        #expect(result.session.tracks[0].segments[0].points[1].elevation == 100)
    }

    @Test("Inserted elevation is nil when neither anchor has elevation")
    func elevationNilWhenNoneAvailable() {
        let (s, track, segment) = makeFixture(points: [
            point(lat: 45.0, lon: -120.0),
            point(lat: 45.002, lon: -120.0),
        ])
        let result = AddPointOnLineOperation.apply(
            to: s, trackId: track.id, segmentId: segment.id,
            afterIndex: 0, latitude: 45.001, longitude: -120.0
        )
        #expect(result.session.tracks[0].segments[0].points[1].elevation == nil)
    }

    @Test("Linearly interpolates timestamp between anchors")
    func interpolatesTime() {
        let t1 = Date(timeIntervalSince1970: 1_700_000_000)
        let t2 = Date(timeIntervalSince1970: 1_700_000_100)
        let (s, track, segment) = makeFixture(points: [
            point(lat: 45.0, lon: -120.0, time: t1),
            point(lat: 45.002, lon: -120.0, time: t2),
        ])
        let result = AddPointOnLineOperation.apply(
            to: s, trackId: track.id, segmentId: segment.id,
            afterIndex: 0, latitude: 45.001, longitude: -120.0
        )
        let inserted = result.session.tracks[0].segments[0].points[1]
        let expected = Date(timeIntervalSince1970: 1_700_000_050)
        #expect(abs(inserted.time!.timeIntervalSince(expected)) < 0.001)
    }

    @Test("afterIndex == -1 inserts at the very front")
    func insertAtFront() {
        let (s, track, segment) = makeFixture(points: [
            point(lat: 45.0, lon: -120.0),
            point(lat: 45.002, lon: -120.0),
        ])
        let result = AddPointOnLineOperation.apply(
            to: s, trackId: track.id, segmentId: segment.id,
            afterIndex: -1, latitude: 44.9, longitude: -120.0
        )
        let pts = result.session.tracks[0].segments[0].points
        #expect(pts.count == 3)
        #expect(pts[0].latitude == 44.9)
        #expect(pts[1].latitude == 45.0)
    }

    @Test("afterIndex == lastIndex inserts at the end")
    func insertAtEnd() {
        let (s, track, segment) = makeFixture(points: [
            point(lat: 45.0, lon: -120.0),
            point(lat: 45.002, lon: -120.0),
        ])
        let result = AddPointOnLineOperation.apply(
            to: s, trackId: track.id, segmentId: segment.id,
            afterIndex: 1, latitude: 45.5, longitude: -120.0
        )
        let pts = result.session.tracks[0].segments[0].points
        #expect(pts.count == 3)
        #expect(pts[2].latitude == 45.5)
    }

    @Test("Out-of-range afterIndex is a no-op")
    func outOfRangeAfterIndex() {
        let (s, track, segment) = makeFixture(points: [
            point(lat: 45.0, lon: -120.0),
            point(lat: 45.002, lon: -120.0),
        ])
        let result = AddPointOnLineOperation.apply(
            to: s, trackId: track.id, segmentId: segment.id,
            afterIndex: 99, latitude: 45.5, longitude: -120.0
        )
        #expect(result.touched.isEmpty)
        #expect(result.session == s)
    }

    @Test("Empty segment is a no-op")
    func emptySegment() {
        let (s, track, segment) = makeFixture(points: [])
        let result = AddPointOnLineOperation.apply(
            to: s, trackId: track.id, segmentId: segment.id,
            afterIndex: -1, latitude: 45.0, longitude: -120.0
        )
        #expect(result.touched.isEmpty)
    }

    @Test("Unknown track id is a no-op")
    func unknownTrack() {
        let (s, _, segment) = makeFixture(points: [
            point(lat: 45.0, lon: -120.0),
            point(lat: 45.002, lon: -120.0),
        ])
        let result = AddPointOnLineOperation.apply(
            to: s, trackId: UUID(), segmentId: segment.id,
            afterIndex: 0, latitude: 45.001, longitude: -120.0
        )
        #expect(result.touched.isEmpty)
        #expect(result.session == s)
    }
}
