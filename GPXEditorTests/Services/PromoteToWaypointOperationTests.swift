// PromoteToWaypointOperationTests.swift
//
// Coverage for PromoteToWaypointOperation — converts a track point to
// a Waypoint, preserving its lat / lon / elevation / time, and
// removes the track point from the segment.

import Testing
import Foundation
@testable import GPXEditor

@Suite("PromoteToWaypointOperation")
struct PromoteToWaypointOperationTests {

    private func point(lat: Double, lon: Double, ele: Double? = nil, time: Date? = nil) -> TrackPoint {
        TrackPoint(latitude: lat, longitude: lon, elevation: ele, time: time)
    }

    private func makeFixture(points: [TrackPoint], waypoints: [Waypoint] = []) -> (GPXSession, Track, Segment) {
        let segment = Segment(id: UUID(), color: HexColor("#FF0000")!, points: points)
        let track = Track(
            id: UUID(),
            name: "T",
            immutableOriginalBytes: Data(),
            segments: [segment],
            waypoints: waypoints
        )
        return (GPXSession(metadata: ProjectMetadata(), tracks: [track]), track, segment)
    }

    @Test("Removes the track point and appends a Waypoint with same lat/lon")
    func basic() {
        let (s, track, segment) = makeFixture(points: [
            point(lat: 45.0, lon: -120.0),
            point(lat: 45.001, lon: -120.0),
            point(lat: 45.002, lon: -120.0),
        ])

        let result = PromoteToWaypointOperation.apply(
            to: s, trackId: track.id, segmentId: segment.id, pointIndex: 1
        )

        #expect(result.session.tracks[0].segments[0].points.count == 2)
        #expect(result.session.tracks[0].segments[0].points[0].latitude == 45.0)
        #expect(result.session.tracks[0].segments[0].points[1].latitude == 45.002)
        #expect(result.session.tracks[0].waypoints.count == 1)
        #expect(result.session.tracks[0].waypoints[0].latitude == 45.001)
        #expect(result.session.tracks[0].waypoints[0].longitude == -120.0)
        #expect(result.session.tracks[0].waypoints[0].sym == "Generic")
        #expect(result.session.tracks[0].waypoints[0].name == "")
    }

    @Test("Carries elevation and time over to the waypoint")
    func preservesMetadata() {
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        let (s, track, segment) = makeFixture(points: [
            point(lat: 45.0, lon: -120.0),
            point(lat: 45.001, lon: -120.0, ele: 123, time: t),
            point(lat: 45.002, lon: -120.0),
        ])

        let result = PromoteToWaypointOperation.apply(
            to: s, trackId: track.id, segmentId: segment.id, pointIndex: 1
        )
        let wp = result.session.tracks[0].waypoints[0]
        #expect(wp.elevation == 123)
        #expect(wp.time == t)
    }

    @Test("Existing waypoints are preserved")
    func existingWaypointsPreserved() {
        let existingWP = Waypoint(latitude: 50.0, longitude: -110.0, name: "trailhead")
        let (s, track, segment) = makeFixture(
            points: [
                point(lat: 45.0, lon: -120.0),
                point(lat: 45.001, lon: -120.0),
            ],
            waypoints: [existingWP]
        )

        let result = PromoteToWaypointOperation.apply(
            to: s, trackId: track.id, segmentId: segment.id, pointIndex: 0
        )
        #expect(result.session.tracks[0].waypoints.count == 2)
        #expect(result.session.tracks[0].waypoints.first?.id == existingWP.id)
    }

    @Test("Out-of-range index is a no-op")
    func outOfRange() {
        let (s, track, segment) = makeFixture(points: [
            point(lat: 45.0, lon: -120.0),
            point(lat: 45.001, lon: -120.0),
        ])
        let result = PromoteToWaypointOperation.apply(
            to: s, trackId: track.id, segmentId: segment.id, pointIndex: 99
        )
        #expect(result.touched.isEmpty)
        #expect(result.session == s)
    }

    @Test("Unknown track id is a no-op")
    func unknownTrack() {
        let (s, _, segment) = makeFixture(points: [point(lat: 45.0, lon: -120.0)])
        let result = PromoteToWaypointOperation.apply(
            to: s, trackId: UUID(), segmentId: segment.id, pointIndex: 0
        )
        #expect(result.touched.isEmpty)
        #expect(result.session == s)
    }
}
