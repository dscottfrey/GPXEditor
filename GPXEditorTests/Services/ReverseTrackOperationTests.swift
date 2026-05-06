// ReverseTrackOperationTests.swift
//
// Coverage for ReverseTrackOperation — flips segment order within a
// track and flips per-segment point order.  Per-point metadata stays
// attached to its point;  segment ids and the track id are preserved;
// waypoints are untouched.

import Testing
import Foundation
@testable import GPXEditor

@Suite("ReverseTrackOperation")
struct ReverseTrackOperationTests {

    private func point(lat: Double, lon: Double, ele: Double? = nil, time: Date? = nil) -> TrackPoint {
        TrackPoint(latitude: lat, longitude: lon, elevation: ele, time: time)
    }

    private func makeTrack(segments: [Segment], waypoints: [Waypoint] = []) -> (GPXSession, Track) {
        let track = Track(
            id: UUID(),
            name: "T",
            immutableOriginalBytes: Data(),
            segments: segments,
            waypoints: waypoints
        )
        return (GPXSession(metadata: ProjectMetadata(), tracks: [track]), track)
    }

    @Test("Single-segment track: points reverse")
    func singleSegmentReverses() {
        let seg = Segment(id: UUID(), color: HexColor("#FF0000")!, points: [
            point(lat: 45.0, lon: -120.0),
            point(lat: 45.001, lon: -120.0),
            point(lat: 45.002, lon: -120.0),
            point(lat: 45.003, lon: -120.0),
        ])
        let (s, track) = makeTrack(segments: [seg])

        let result = ReverseTrackOperation.apply(to: s, trackId: track.id)
        let reversed = result.session.tracks[0].segments[0].points.map(\.latitude)
        #expect(reversed == [45.003, 45.002, 45.001, 45.0])
        #expect(result.touched.count == 1)
        #expect(result.touched[0].trackId == track.id)
    }

    @Test("Multi-segment track: segment order flips and points within each flip")
    func multiSegmentReverses() {
        let seg1 = Segment(id: UUID(), color: HexColor("#FF0000")!, points: [
            point(lat: 45.0, lon: -120.0),
            point(lat: 45.001, lon: -120.0),
        ])
        let seg2 = Segment(id: UUID(), color: HexColor("#00FF00")!, points: [
            point(lat: 46.0, lon: -120.0),
            point(lat: 46.001, lon: -120.0),
            point(lat: 46.002, lon: -120.0),
        ])
        let (s, track) = makeTrack(segments: [seg1, seg2])

        let result = ReverseTrackOperation.apply(to: s, trackId: track.id)
        let segs = result.session.tracks[0].segments
        // seg2 now first (reverse segment order), and its points flipped.
        #expect(segs[0].id == seg2.id)
        #expect(segs[0].points.map(\.latitude) == [46.002, 46.001, 46.0])
        // seg1 now second, points flipped.
        #expect(segs[1].id == seg1.id)
        #expect(segs[1].points.map(\.latitude) == [45.001, 45.0])
    }

    @Test("Per-point metadata stays attached to each point")
    func metadataPreserved() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let t1 = Date(timeIntervalSince1970: 1_000_010)
        let t2 = Date(timeIntervalSince1970: 1_000_020)
        let seg = Segment(id: UUID(), color: HexColor("#FF0000")!, points: [
            point(lat: 45.0, lon: -120.0, ele: 100, time: t0),
            point(lat: 45.001, lon: -120.0, ele: 110, time: t1),
            point(lat: 45.002, lon: -120.0, ele: 120, time: t2),
        ])
        let (s, track) = makeTrack(segments: [seg])

        let result = ReverseTrackOperation.apply(to: s, trackId: track.id)
        let points = result.session.tracks[0].segments[0].points
        // First point of reversed track is the original last point —
        // its elevation and timestamp came along with it.
        #expect(points[0].latitude == 45.002)
        #expect(points[0].elevation == 120)
        #expect(points[0].time == t2)
        #expect(points[2].latitude == 45.0)
        #expect(points[2].elevation == 100)
        #expect(points[2].time == t0)
    }

    @Test("Segment ids and colors are preserved")
    func segmentIdentityPreserved() {
        let seg1 = Segment(id: UUID(), name: "Morning", color: HexColor("#FF0000")!, points: [
            point(lat: 45.0, lon: -120.0),
            point(lat: 45.001, lon: -120.0),
        ])
        let seg2 = Segment(id: UUID(), name: "Afternoon", color: HexColor("#00FF00")!, points: [
            point(lat: 46.0, lon: -120.0),
            point(lat: 46.001, lon: -120.0),
        ])
        let (s, track) = makeTrack(segments: [seg1, seg2])

        let result = ReverseTrackOperation.apply(to: s, trackId: track.id)
        let segs = result.session.tracks[0].segments
        #expect(segs[0].id == seg2.id)
        #expect(segs[0].name == "Afternoon")
        #expect(segs[0].color == seg2.color)
        #expect(segs[1].id == seg1.id)
        #expect(segs[1].name == "Morning")
        #expect(segs[1].color == seg1.color)
    }

    @Test("Waypoints are untouched")
    func waypointsUntouched() {
        let seg = Segment(id: UUID(), color: HexColor("#FF0000")!, points: [
            point(lat: 45.0, lon: -120.0),
            point(lat: 45.001, lon: -120.0),
        ])
        let waypoint = Waypoint(
            latitude: 45.5,
            longitude: -119.5,
            elevation: 1000,
            time: nil,
            name: "Trailhead",
            sym: "Trailhead",
            description: nil
        )
        let (s, track) = makeTrack(segments: [seg], waypoints: [waypoint])

        let result = ReverseTrackOperation.apply(to: s, trackId: track.id)
        let wps = result.session.tracks[0].waypoints
        #expect(wps.count == 1)
        #expect(wps[0].id == waypoint.id)
        #expect(wps[0].latitude == 45.5)
        #expect(wps[0].name == "Trailhead")
    }

    @Test("Track id is preserved")
    func trackIdPreserved() {
        let seg = Segment(id: UUID(), color: HexColor("#FF0000")!, points: [
            point(lat: 45.0, lon: -120.0),
            point(lat: 45.001, lon: -120.0),
        ])
        let (s, track) = makeTrack(segments: [seg])

        let result = ReverseTrackOperation.apply(to: s, trackId: track.id)
        #expect(result.session.tracks[0].id == track.id)
    }

    @Test("Empty track (no segments) is a no-op with empty touched list")
    func emptyTrackNoOp() {
        let (s, track) = makeTrack(segments: [])
        let result = ReverseTrackOperation.apply(to: s, trackId: track.id)
        #expect(result.touched.isEmpty)
        #expect(result.session == s)
    }

    @Test("Single-point segment: still touched (geometric no-op but order changed semantically)")
    func singlePointSegment() {
        let seg = Segment(id: UUID(), color: HexColor("#FF0000")!, points: [
            point(lat: 45.0, lon: -120.0),
        ])
        let (s, track) = makeTrack(segments: [seg])
        let result = ReverseTrackOperation.apply(to: s, trackId: track.id)
        // Touched-list reports the track because the operation ran.
        // Geometrically the single point stayed at the same coordinates.
        #expect(result.touched.count == 1)
        #expect(result.session.tracks[0].segments[0].points.count == 1)
        #expect(result.session.tracks[0].segments[0].points[0].latitude == 45.0)
    }

    @Test("Stale trackId is a no-op")
    func staleTrackId() {
        let seg = Segment(id: UUID(), color: HexColor("#FF0000")!, points: [
            point(lat: 45.0, lon: -120.0),
            point(lat: 45.001, lon: -120.0),
        ])
        let (s, _) = makeTrack(segments: [seg])
        let result = ReverseTrackOperation.apply(to: s, trackId: UUID())
        #expect(result.touched.isEmpty)
        #expect(result.session == s)
    }

    @Test("Reverse twice returns the original")
    func reverseIsItsOwnInverse() {
        let seg1 = Segment(id: UUID(), color: HexColor("#FF0000")!, points: [
            point(lat: 45.0, lon: -120.0, ele: 100),
            point(lat: 45.001, lon: -120.0, ele: 110),
        ])
        let seg2 = Segment(id: UUID(), color: HexColor("#00FF00")!, points: [
            point(lat: 46.0, lon: -120.0, ele: 200),
            point(lat: 46.001, lon: -120.0, ele: 210),
            point(lat: 46.002, lon: -120.0, ele: 220),
        ])
        let (s, track) = makeTrack(segments: [seg1, seg2])

        let once = ReverseTrackOperation.apply(to: s, trackId: track.id).session
        let twice = ReverseTrackOperation.apply(to: once, trackId: track.id).session
        #expect(twice == s)
    }
}
