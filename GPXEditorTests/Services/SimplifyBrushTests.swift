// SimplifyBrushTests.swift
//
// Coverage for SimplifyBrush.apply — the M4 brush operation that runs
// RDP simplification on whichever sub-ranges of a track's segments fall
// within the brush stroke's swept region.

import Testing
import Foundation
@testable import GPXEditor

@Suite("SimplifyBrush")
struct SimplifyBrushTests {

    // MARK: - Fixture helpers

    private func point(lat: Double, lon: Double) -> TrackPoint {
        TrackPoint(latitude: lat, longitude: lon)
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

    private func sample(lat: Double, lon: Double, radius: Double = 30) -> SimplifyBrush.StrokeSample {
        SimplifyBrush.StrokeSample(latitude: lat, longitude: lon, radiusMeters: radius)
    }

    // MARK: - Empty / no-op cases

    @Test("Empty stroke is a no-op")
    func emptyStroke() {
        let segment = makeSegment(points: [point(lat: 45, lon: -120), point(lat: 45.001, lon: -120)])
        let track = makeTrack(segments: [segment])
        let s = session(tracks: [track])

        let result = SimplifyBrush.apply(to: s, trackId: track.id, stroke: [])

        #expect(result.touched.isEmpty)
        #expect(result.session == s)
    }

    @Test("Unknown track id is a no-op")
    func unknownTrack() {
        let segment = makeSegment(points: [point(lat: 45, lon: -120), point(lat: 45.001, lon: -120)])
        let track = makeTrack(segments: [segment])
        let s = session(tracks: [track])

        let result = SimplifyBrush.apply(
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

        // Brush is on the other side of the world.
        let result = SimplifyBrush.apply(
            to: s,
            trackId: track.id,
            stroke: [sample(lat: -45, lon: 60)]
        )

        #expect(result.touched.isEmpty)
        #expect(result.session == s)
    }

    @Test("Two-point segment is too short to simplify; left untouched")
    func tooShortSegment() {
        let segment = makeSegment(points: [point(lat: 45, lon: -120), point(lat: 45.0001, lon: -120)])
        let track = makeTrack(segments: [segment])
        let s = session(tracks: [track])

        let result = SimplifyBrush.apply(
            to: s,
            trackId: track.id,
            stroke: [sample(lat: 45, lon: -120)]
        )

        #expect(result.touched.isEmpty)
        #expect(result.session == s)
    }

    // MARK: - Real simplification

    @Test("Brush over a noisy collinear run drops intermediate points")
    func collinearNoisySimplify() {
        // 11 points along a meridian (constant longitude) at increasing
        // latitudes.  All exactly on a line — RDP should drop every
        // intermediate point and keep just the endpoints.
        var points: [TrackPoint] = []
        for i in 0..<11 {
            points.append(point(lat: 45.0 + Double(i) * 0.0001, lon: -120))
        }
        let segment = makeSegment(points: points)
        let track = makeTrack(segments: [segment])
        let s = session(tracks: [track])

        // Brush stroke covering all 11 points (the brush radius is 30m;
        // 11 points spanning ~110m at this latitude).  Use multiple
        // samples along the stroke so every point is within radius of
        // some sample.
        var stroke: [SimplifyBrush.StrokeSample] = []
        for i in 0..<11 {
            stroke.append(sample(lat: 45.0 + Double(i) * 0.0001, lon: -120))
        }

        let result = SimplifyBrush.apply(to: s, trackId: track.id, stroke: stroke)

        // After simplification the segment should have FEWER points
        // (the exact count depends on tolerance, but it should drop
        // intermediate points on a perfectly-collinear run).
        #expect(result.touched.count == 1)
        let resultingPoints = result.session.tracks[0].segments[0].points
        #expect(resultingPoints.count < points.count)
        // First and last preserved — RDP invariant.
        #expect(resultingPoints.first?.latitude == points.first?.latitude)
        #expect(resultingPoints.last?.latitude == points.last?.latitude)
    }

    @Test("Brush leaves untouched portions of a segment exactly intact")
    func untouchedPortionPreserved() {
        // Build a segment with two regions:  a brushed-over noisy run
        // followed by an untouched stretch.  Verify the untouched
        // points are byte-identical in the output.
        var points: [TrackPoint] = []
        // Brushed region:  10 collinear points around (45.000, -120)
        for i in 0..<10 {
            points.append(point(lat: 45.0 + Double(i) * 0.00005, lon: -120))
        }
        // Untouched region:  10 points far away at (50, -110)
        for i in 0..<10 {
            points.append(point(lat: 50.0 + Double(i) * 0.001, lon: -110))
        }
        let segment = makeSegment(points: points)
        let track = makeTrack(segments: [segment])
        let s = session(tracks: [track])

        // Brush only the first region.
        let stroke = [sample(lat: 45.0, lon: -120)]

        let result = SimplifyBrush.apply(to: s, trackId: track.id, stroke: stroke)

        let resulting = result.session.tracks[0].segments[0].points
        // The trailing 10 points are unchanged — find them in the
        // result and confirm equality.
        let expectedTail = Array(points.suffix(10))
        let actualTail = Array(resulting.suffix(10))
        #expect(actualTail == expectedTail)
    }

    @Test("Touched list correctly identifies the affected segment")
    func touchedListIsCorrect() {
        // Two segments;  brush touches only the first.
        var pointsA: [TrackPoint] = []
        for i in 0..<10 {
            pointsA.append(point(lat: 45.0 + Double(i) * 0.00005, lon: -120))
        }
        let segA = makeSegment(points: pointsA)

        var pointsB: [TrackPoint] = []
        for i in 0..<10 {
            pointsB.append(point(lat: 50.0 + Double(i) * 0.00005, lon: -110))
        }
        let segB = makeSegment(points: pointsB)

        let track = makeTrack(segments: [segA, segB])
        let s = session(tracks: [track])

        let stroke = [sample(lat: 45.0, lon: -120)]
        let result = SimplifyBrush.apply(to: s, trackId: track.id, stroke: stroke)

        #expect(result.touched.count == 1)
        #expect(result.touched.first?.segmentId == segA.id)
    }
}
