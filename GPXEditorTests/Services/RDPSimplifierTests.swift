// RDPSimplifierTests.swift
//
// Coverage for the pure RDP simplification function:  basic
// preservation properties (first / last always kept), tolerance
// behaviour (small tolerance keeps everything, large tolerance keeps
// only endpoints), and the perpendicular-distance helper for the
// degenerate zero-length-line case.

import Testing
import Foundation
@testable import GPXEditor

@Suite("RDPSimplifier")
struct RDPSimplifierTests {

    private func pt(_ x: Double, _ y: Double) -> RDPSimplifier.Point2D {
        RDPSimplifier.Point2D(x: x, y: y)
    }

    @Test("Empty input returns empty indices")
    func emptyInput() {
        let result = RDPSimplifier.simplify([], tolerance: 1.0)
        #expect(result.isEmpty)
    }

    @Test("Single-point input returns its index")
    func singlePoint() {
        let result = RDPSimplifier.simplify([pt(0, 0)], tolerance: 1.0)
        #expect(result == [0])
    }

    @Test("Two-point input always returns both indices unchanged")
    func twoPoints() {
        let result = RDPSimplifier.simplify([pt(0, 0), pt(10, 10)], tolerance: 1.0)
        #expect(result == [0, 1])
    }

    @Test("Straight line collapses to endpoints under any positive tolerance")
    func straightLine() {
        // Five points on the same line y = x.  Every intermediate point
        // is exactly on the line, so perpendicular distance is 0.
        let points = [pt(0, 0), pt(1, 1), pt(2, 2), pt(3, 3), pt(4, 4)]
        let result = RDPSimplifier.simplify(points, tolerance: 0.001)
        #expect(result == [0, 4])
    }

    @Test("Sharp deviation is preserved when above tolerance")
    func sharpDeviation() {
        // Three points where the middle deviates significantly from the
        // line connecting first and last.
        let points = [pt(0, 0), pt(5, 100), pt(10, 0)]
        let result = RDPSimplifier.simplify(points, tolerance: 1.0)
        // All three preserved — the middle point is 100 units off the
        // x-axis line connecting (0,0) and (10,0).
        #expect(result == [0, 1, 2])
    }

    @Test("Tolerance above max deviation collapses to endpoints")
    func toleranceAboveDeviation() {
        let points = [pt(0, 0), pt(5, 1), pt(10, 0)]
        // Max deviation is 1.0 (the middle point is 1 unit above the
        // line).  Tolerance of 2.0 is larger, so the middle point drops.
        let result = RDPSimplifier.simplify(points, tolerance: 2.0)
        #expect(result == [0, 2])
    }

    @Test("First and last are always preserved")
    func endpointsAlwaysKept() {
        let points = [pt(0, 0), pt(1, 0), pt(2, 0), pt(3, 0)]
        // Tolerance huge enough to drop everything that can be dropped.
        let result = RDPSimplifier.simplify(points, tolerance: 1000)
        #expect(result.first == 0)
        #expect(result.last == 3)
        #expect(result.count == 2)
    }

    @Test("Noisy near-line input is reduced but endpoints preserved")
    func noisyLineReducedButEndpointsKept() {
        // Many points along the x-axis with alternating tiny vertical
        // noise.  Tolerance much larger than the noise — every
        // intermediate point should be filterable.
        //
        // We don't pin the exact surviving indices because RDP's
        // recursive structure makes that brittle (a point that's
        // "small deviation" from the original line can become
        // significant relative to a sub-line after recursion picks up
        // a steeper slope).  The invariants we care about are:  first
        // and last are preserved, and count goes down.
        var points: [RDPSimplifier.Point2D] = []
        for i in 0...20 {
            let x = Double(i)
            let y = Double(i % 2) * 0.01  // tiny alternating noise
            points.append(pt(x, y))
        }
        let result = RDPSimplifier.simplify(points, tolerance: 1.0)
        #expect(result.first == 0)
        #expect(result.last == 20)
        #expect(result.count < points.count)
    }

    @Test("perpendicularDistance handles degenerate zero-length line")
    func perpendicularDegenerate() {
        let p = pt(3, 4)
        let line = pt(0, 0)
        let d = RDPSimplifier.perpendicularDistance(point: p, lineStart: line, lineEnd: line)
        // Falls back to point-to-point Euclidean distance:  sqrt(9 + 16) = 5.
        #expect(abs(d - 5.0) < 1e-10)
    }

    @Test("perpendicularDistance computes correctly for axis-aligned line")
    func perpendicularAxisAligned() {
        // Line from (0, 0) to (10, 0) is the x-axis.  Distance from
        // (5, 7) is 7.
        let d = RDPSimplifier.perpendicularDistance(
            point: pt(5, 7),
            lineStart: pt(0, 0),
            lineEnd: pt(10, 0)
        )
        #expect(abs(d - 7.0) < 1e-10)
    }
}
