// RDPSimplifier.swift
//
// Pure-function Ramer-Douglas-Peucker polyline simplification.  Used
// by SimplifyBrush at M4 (the canonical commit;  the JS-side preview
// uses simplify.js, separately vendored).  Used later by other
// operations that want RDP simplification (e.g. an explicit
// "Simplify Track" menu command).
//
// The algorithm:
//   1. Connect the first and last point of the input with a straight line.
//   2. Find the input point with the greatest perpendicular distance from
//      that line.
//   3. If that distance is greater than `tolerance`, recursively simplify
//      the two halves.  Otherwise, every intermediate point is within
//      tolerance — drop them all and keep just the first and last.
//
// Two design choices worth surfacing:
//
// 1. Coordinates are treated as 2D Euclidean (lat / lon as plain
//    numbers).  Perpendicular distance is computed in the same flat
//    Euclidean space.  This is the standard cartographic shortcut for
//    short-range simplification — at hiking-track scale (kilometres,
//    not continent-spanning) the curvature error is negligible relative
//    to the GPS noise we're trying to remove.  A spherical-distance
//    variant exists but is overkill for v1.
//
// 2. Tolerance is a Double in the same coordinate space as the input
//    (degrees of lat/lon).  Callers that think in metres are responsible
//    for converting:  at the equator, 1 degree of longitude ≈ 111 km;
//    at higher latitudes, the longitude factor shrinks by cos(latitude).
//    SimplifyBrush handles this conversion at its boundary so the brush
//    radius can be specified in metres.  RDPSimplifier itself stays
//    coordinate-system-agnostic — same algorithm whether the input is
//    in degrees, metres, or projected pixels.
//
// Per CONVENTIONS.md "platform-agnostic data layer," this file is
// Foundation-only.  No SwiftUI, no AppKit, no WebKit.

import Foundation

/// Pure RDP polyline simplification.  Stateless;  the namespace exists
/// for discoverability rather than instance state.
public enum RDPSimplifier {

    /// A 2D point with x/y coordinates in any units.  At the
    /// SimplifyBrush boundary the convention is x = longitude,
    /// y = latitude — but the algorithm itself doesn't care which is
    /// which.
    public struct Point2D: Equatable, Sendable {
        public var x: Double
        public var y: Double

        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }
    }

    /// Simplify a polyline to a subset of its input points where every
    /// dropped point is within `tolerance` perpendicular distance of
    /// the simplified line.  Always preserves the first and last point.
    ///
    /// Returns the input array's indices in their original order — the
    /// caller can then reconstruct the simplified polyline by reading
    /// `input[indices[i]]` for each i, or use the indices directly to
    /// build a "keep these, drop the rest" replacement.  Returning
    /// indices (rather than fresh Point2D values) is the SimplifyBrush
    /// flow's friend:  the operation needs to know which TrackPoints
    /// survived so it can preserve their elevation, timestamp, and
    /// any other per-point metadata that's not in the 2D simplification
    /// space.
    ///
    /// Empty or single-point input returns the input's indices
    /// unchanged.  Two-point input returns [0, 1] unchanged (the
    /// algorithm has nothing to simplify).
    public static func simplify(_ points: [Point2D], tolerance: Double) -> [Int] {
        if points.count <= 2 {
            return Array(points.indices)
        }
        // Bit-set of indices to keep.  More efficient than recursive
        // array concatenation;  the recursion just toggles bits.
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        simplifyRecursive(
            points: points,
            firstIndex: 0,
            lastIndex: points.count - 1,
            tolerance: tolerance,
            keep: &keep
        )
        return keep.indices.filter { keep[$0] }
    }

    /// Recursive worker.  Marks intermediate points to keep based on
    /// perpendicular distance from the line connecting `firstIndex`
    /// and `lastIndex`.
    private static func simplifyRecursive(
        points: [Point2D],
        firstIndex: Int,
        lastIndex: Int,
        tolerance: Double,
        keep: inout [Bool]
    ) {
        if lastIndex <= firstIndex + 1 {
            return  // no intermediate points to consider
        }

        let first = points[firstIndex]
        let last = points[lastIndex]

        var maxDistance: Double = 0
        var maxIndex: Int = firstIndex

        for i in (firstIndex + 1)..<lastIndex {
            let d = perpendicularDistance(point: points[i], lineStart: first, lineEnd: last)
            if d > maxDistance {
                maxDistance = d
                maxIndex = i
            }
        }

        if maxDistance > tolerance {
            // Keep this point and recurse into both halves.
            keep[maxIndex] = true
            simplifyRecursive(
                points: points,
                firstIndex: firstIndex,
                lastIndex: maxIndex,
                tolerance: tolerance,
                keep: &keep
            )
            simplifyRecursive(
                points: points,
                firstIndex: maxIndex,
                lastIndex: lastIndex,
                tolerance: tolerance,
                keep: &keep
            )
        }
        // else: every intermediate point is within tolerance — they're
        // already marked false (the default), nothing more to do.
    }

    /// Perpendicular distance from `point` to the infinite line passing
    /// through `lineStart` and `lineEnd`.  Standard formula:
    ///
    ///     distance = |((y2 - y1) * x0 - (x2 - x1) * y0 + x2*y1 - y2*x1)|
    ///                / sqrt((y2 - y1)^2 + (x2 - x1)^2)
    ///
    /// Degenerate case where lineStart == lineEnd:  returns the simple
    /// Euclidean distance from the point to that single coordinate.
    /// Without this guard the formula divides by zero;  RDP shouldn't
    /// invoke us with a degenerate line in normal use, but a defensive
    /// guard is cheap insurance.
    static func perpendicularDistance(
        point: Point2D,
        lineStart: Point2D,
        lineEnd: Point2D
    ) -> Double {
        let dx = lineEnd.x - lineStart.x
        let dy = lineEnd.y - lineStart.y
        let lengthSquared = dx * dx + dy * dy
        if lengthSquared == 0 {
            // Degenerate line:  fall back to point-to-point distance.
            let pdx = point.x - lineStart.x
            let pdy = point.y - lineStart.y
            return (pdx * pdx + pdy * pdy).squareRoot()
        }
        let numerator = abs(dy * point.x - dx * point.y + lineEnd.x * lineStart.y - lineEnd.y * lineStart.x)
        return numerator / lengthSquared.squareRoot()
    }
}
