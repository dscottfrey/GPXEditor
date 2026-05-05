// SmoothBrushTests.swift
//
// Coverage for SmoothBrush.apply — the M4 brush operation that runs a
// uniform-weight kernel moving average over the points of a track that
// fall within the brush stroke's swept region.  Tests the no-op cases,
// real smoothing on noisy input, and the preservation rules
// (out-of-region points unchanged, elevation/timestamp preserved).

import Testing
import Foundation
@testable import GPXEditor

@Suite("SmoothBrush")
struct SmoothBrushTests {

    // MARK: - Fixture helpers

    private func point(lat: Double, lon: Double, ele: Double? = nil) -> TrackPoint {
        TrackPoint(latitude: lat, longitude: lon, elevation: ele)
    }

    private func makeSegment(points: [TrackPoint]) -> Segment {
        Segment(id: UUID(), color: HexColor("#FF0000")!, points: points)
    }

    private func makeTrack(segments: [Segment]) -> Track {
        Track(
            id: UUID(),
            name: "track",
            immutableOriginalBytes: Data(),
            segments: segments
        )
    }

    private func session(tracks: [Track]) -> GPXSession {
        GPXSession(metadata: ProjectMetadata(), tracks: tracks)
    }

    private func sample(lat: Double, lon: Double, radius: Double = 30) -> SmoothBrush.StrokeSample {
        SmoothBrush.StrokeSample(latitude: lat, longitude: lon, radiusMeters: radius)
    }

    // MARK: - Empty / no-op cases

    @Test("Empty stroke is a no-op")
    func emptyStroke() {
        let segment = makeSegment(points: [
            point(lat: 45, lon: -120),
            point(lat: 45.001, lon: -120),
            point(lat: 45.002, lon: -120),
        ])
        let track = makeTrack(segments: [segment])
        let s = session(tracks: [track])

        let result = SmoothBrush.apply(to: s, trackId: track.id, stroke: [])
        #expect(result.touched.isEmpty)
        #expect(result.session == s)
    }

    @Test("Unknown track id is a no-op")
    func unknownTrack() {
        let segment = makeSegment(points: [
            point(lat: 45, lon: -120),
            point(lat: 45.001, lon: -120),
            point(lat: 45.002, lon: -120),
        ])
        let track = makeTrack(segments: [segment])
        let s = session(tracks: [track])

        let result = SmoothBrush.apply(
            to: s,
            trackId: UUID(),
            stroke: [sample(lat: 45, lon: -120)]
        )
        #expect(result.touched.isEmpty)
        #expect(result.session == s)
    }

    @Test("Stroke far from any point is a no-op")
    func strokeFarAway() {
        let segment = makeSegment(points: [
            point(lat: 45, lon: -120),
            point(lat: 45.001, lon: -120),
            point(lat: 45.002, lon: -120),
        ])
        let track = makeTrack(segments: [segment])
        let s = session(tracks: [track])

        let result = SmoothBrush.apply(
            to: s,
            trackId: track.id,
            stroke: [sample(lat: -45, lon: 60)]
        )
        #expect(result.touched.isEmpty)
        #expect(result.session == s)
    }

    @Test("Already-smooth segment with interior-only brush is essentially unchanged")
    func alreadySmoothInteriorBrushNoOp() {
        // 11 collinear evenly-spaced points along a meridian.  A single
        // brush sample at index 5 reaches indices 3-7 (within 30m
        // radius);  every brushed point has a SYMMETRIC kernel, so for
        // evenly-spaced collinear input the kernel mean equals the
        // center mathematically.  Floating-point arithmetic may
        // introduce sub-nanodegree noise, so we assert "essentially
        // unchanged" rather than byte-exact equality.
        var points: [TrackPoint] = []
        for i in 0..<11 {
            points.append(point(lat: 45.0 + Double(i) * 0.0001, lon: -120))
        }
        let segment = makeSegment(points: points)
        let track = makeTrack(segments: [segment])
        let s = session(tracks: [track])

        let stroke = [sample(lat: 45.0005, lon: -120)]
        let result = SmoothBrush.apply(to: s, trackId: track.id, stroke: stroke)

        let resulting = result.session.tracks[0].segments[0].points
        #expect(resulting.count == points.count)
        for i in 0..<resulting.count {
            let dLat = abs(resulting[i].latitude - points[i].latitude)
            let dLng = abs(resulting[i].longitude - points[i].longitude)
            #expect(dLat < 1e-9, "Point \(i) lat moved more than expected: \(dLat)")
            #expect(dLng < 1e-9, "Point \(i) lng moved more than expected: \(dLng)")
        }
    }

    // MARK: - Real smoothing

    @Test("Noisy zigzag is smoothed toward the average path")
    func zigzagSmoothed() {
        // 11 points with alternating tiny longitude offset.  Smoothing
        // averages each point with its neighbors, pulling the zigzag
        // toward a straighter line.
        var points: [TrackPoint] = []
        for i in 0..<11 {
            let zigzag = i % 2 == 0 ? 0.00005 : -0.00005   // ~5m alternation
            points.append(point(lat: 45.0 + Double(i) * 0.0001, lon: -120 + zigzag))
        }
        let segment = makeSegment(points: points)
        let track = makeTrack(segments: [segment])
        let s = session(tracks: [track])

        var stroke: [SmoothBrush.StrokeSample] = []
        for i in 0..<11 {
            stroke.append(sample(lat: 45.0 + Double(i) * 0.0001, lon: -120))
        }

        let result = SmoothBrush.apply(to: s, trackId: track.id, stroke: stroke)
        #expect(result.touched.count == 1)

        let resultingPoints = result.session.tracks[0].segments[0].points
        // Same point count — Smooth doesn't drop anything.
        #expect(resultingPoints.count == points.count)
        // Interior points should have moved toward longitude 0
        // (the average of the alternating zigzag).  Point at index 5
        // started at -120 + 0.00005 (or -0.00005 depending on parity);
        // its kernel-7 average should be much closer to -120.
        let beforeMid = abs(points[5].longitude - (-120.0))
        let afterMid = abs(resultingPoints[5].longitude - (-120.0))
        #expect(afterMid < beforeMid)
    }

    // MARK: - Preservation rules

    @Test("Out-of-region points are byte-identical")
    func untouchedPointsPreserved() {
        // Two regions:  one will be brushed, one won't.
        var points: [TrackPoint] = []
        // Brushed region — zigzag near (45, -120)
        for i in 0..<10 {
            let zigzag = i % 2 == 0 ? 0.00005 : -0.00005
            points.append(point(lat: 45.0 + Double(i) * 0.0001, lon: -120 + zigzag))
        }
        // Untouched region — far away
        for i in 0..<10 {
            points.append(point(lat: 50.0 + Double(i) * 0.0001, lon: -110))
        }
        let segment = makeSegment(points: points)
        let track = makeTrack(segments: [segment])
        let s = session(tracks: [track])

        let stroke = [sample(lat: 45.0, lon: -120)]
        let result = SmoothBrush.apply(to: s, trackId: track.id, stroke: stroke)
        let resulting = result.session.tracks[0].segments[0].points

        // Tail (untouched) is identical.
        let expectedTail = Array(points.suffix(10))
        let actualTail = Array(resulting.suffix(10))
        #expect(actualTail == expectedTail)
    }

    @Test("Elevation and timestamp are preserved per smoothed point")
    func elevationAndTimePreserved() {
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        var points: [TrackPoint] = []
        for i in 0..<7 {
            let zigzag = i % 2 == 0 ? 0.00005 : -0.00005
            let p = TrackPoint(
                latitude: 45.0 + Double(i) * 0.0001,
                longitude: -120 + zigzag,
                elevation: 100.0 + Double(i),
                time: baseDate.addingTimeInterval(Double(i))
            )
            points.append(p)
        }
        let segment = makeSegment(points: points)
        let track = makeTrack(segments: [segment])
        let s = session(tracks: [track])

        var stroke: [SmoothBrush.StrokeSample] = []
        for i in 0..<7 {
            stroke.append(sample(lat: 45.0 + Double(i) * 0.0001, lon: -120))
        }

        let result = SmoothBrush.apply(to: s, trackId: track.id, stroke: stroke)
        let resulting = result.session.tracks[0].segments[0].points

        // Per-point elevation and time match the originals — Smooth
        // only moves lat/lon.
        for i in 0..<resulting.count {
            #expect(resulting[i].elevation == points[i].elevation)
            #expect(resulting[i].time == points[i].time)
        }
    }
}
