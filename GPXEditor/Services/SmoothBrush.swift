// SmoothBrush.swift
//
// The second concrete brush, pulled forward from M9 to M4 during M4
// verification (Scott's feedback:  "it should prefer to remove jitter
// and make the points more in a line, only removing points when they
// are redundant" — the first half of which describes Smooth, not
// Simplify).  Per D-015 the brush family shares an architecture but at
// M4 we ship two concrete brushes side-by-side without a `BrushTool`
// protocol;  M9 will factor one out when the third and fourth brushes
// (Average, AddDetail) earn the abstraction.
//
// Algorithm — uniform-weight kernel moving average (D-016 says "simplest
// version that achieves the goal";  here that's a boxcar filter):
//
//   1. The brush stroke is a sequence of (lat, lon, radius_meters)
//      samples — the same wire format SimplifyBrush uses.
//   2. For each segment in the named track, find every point whose
//      lat/lon falls within `radius_meters` of some stroke sample.
//   3. For each such point, replace its lat/lon with the uniform
//      average of itself and its `k` nearest neighbors in index space
//      (k each side, 2k+1 points total).  Points outside the brush
//      region keep their original positions.  Elevation and timestamp
//      are preserved unchanged — this brush only smooths the planar
//      geometry, not the per-point metadata.
//   4. Return the new session.
//
// One value fixed for v1 (D-016 leaves it tunable for iteration):
//
//   - Kernel half-width:  3 (so 7 points contribute to each smoothed
//     position).  Wide enough to dampen typical 1-3m GPS jitter while
//     not so wide that legitimate trail features get over-smoothed.
//     A future iteration could expose this as a strength slider, or
//     switch to a Gaussian kernel for smoother falloff.
//
// Per CONVENTIONS.md "platform-agnostic data layer," this file is
// Foundation-only.  No SwiftUI, no AppKit, no WebKit.

import Foundation

public enum SmoothBrush {

    /// Number of neighbors to include on each side of the smoothed
    /// point.  Total kernel width = 2*halfWidth + 1.  Tuned during M4
    /// verification:  the initial 3 (7-point average) was too aggressive
    /// for typical recording-noise levels — it pulled legitimate trail
    /// curves toward straight lines.  1 (3-point average — each point
    /// with just its immediate neighbors) is gentler and removes
    /// jitter without distorting the underlying path.  Iteration
    /// material:  expose as a "hardness" slider per D-016.
    public static let defaultKernelHalfWidth: Int = 1

    /// One sample from a brush stroke.  Same shape as
    /// SimplifyBrush.StrokeSample;  duplicated here rather than
    /// shared so each brush's API stays self-contained.  When a
    /// third brush lands at M9 we'll factor out a common
    /// `BrushStrokeSample`.
    public struct StrokeSample: Equatable, Sendable {
        public var latitude: Double
        public var longitude: Double
        public var radiusMeters: Double

        public init(latitude: Double, longitude: Double, radiusMeters: Double) {
            self.latitude = latitude
            self.longitude = longitude
            self.radiusMeters = radiusMeters
        }
    }

    /// Apply the smooth brush to a single track within a session.
    /// Returns the new session value plus the (track_id, segment_id)
    /// pairs that were touched and actually changed.  A segment whose
    /// brushed points happen to already lie at their kernel-average
    /// (perfectly straight line, no smoothing to do) is NOT included
    /// in `touched` — same convention SimplifyBrush uses.
    public static func apply(
        to session: GPXSession,
        trackId: UUID,
        stroke: [StrokeSample]
    ) -> (session: GPXSession, touched: [TouchedSegment]) {

        guard !stroke.isEmpty else { return (session, []) }
        guard let trackIndex = session.tracks.firstIndex(where: { $0.id == trackId }) else {
            return (session, [])
        }

        var newSession = session
        var track = newSession.tracks[trackIndex]
        var touched: [TouchedSegment] = []

        for segIdx in track.segments.indices {
            let segment = track.segments[segIdx]
            let originalPoints = segment.points
            // Smoothing requires at least kernel-width-plus-one points
            // for the kernel to do anything meaningful.  For very short
            // segments we skip rather than degrade gracefully — kernel
            // averaging over a 2-point segment would just produce the
            // same line, no benefit.
            if originalPoints.count < 3 { continue }

            // Identify which points are inside the brush region.
            var inRegion = [Bool](repeating: false, count: originalPoints.count)
            var anyInRegion = false
            for i in originalPoints.indices {
                let p = originalPoints[i]
                if pointTouchedByStroke(latitude: p.latitude, longitude: p.longitude, stroke: stroke) {
                    inRegion[i] = true
                    anyInRegion = true
                }
            }
            if !anyInRegion { continue }

            // Apply the kernel.  Read positions are from the ORIGINAL
            // points (not the partially-updated newPoints) so the
            // smoothing is a single pass against the input — otherwise
            // the result would depend on iteration order.
            var newPoints = originalPoints
            for i in originalPoints.indices where inRegion[i] {
                let (avgLat, avgLng) = kernelAverage(points: originalPoints, center: i)
                // Preserve elevation and timestamp;  Smooth only moves
                // lat/lon.  The smoothed point at index i is conceptually
                // "the same recording sample, just at the smoothed
                // position" — keeping its time/elevation matches that.
                newPoints[i] = TrackPoint(
                    latitude: avgLat,
                    longitude: avgLng,
                    elevation: originalPoints[i].elevation,
                    time: originalPoints[i].time
                )
            }

            if newPoints != originalPoints {
                track.segments[segIdx].points = newPoints
                touched.append(TouchedSegment(trackId: track.id, segmentId: segment.id))
            }
        }

        if !touched.isEmpty {
            newSession.tracks[trackIndex] = track
        }
        return (newSession, touched)
    }

    // MARK: - Helpers

    /// Uniform-weight average of `points[center]` plus `defaultKernelHalfWidth`
    /// neighbors on each side, clamped to the array bounds.  At the
    /// segment's edges the kernel is asymmetric (fewer points contribute
    /// from the short side) — acceptable;  the alternative of refusing
    /// to smooth edge points would leave visible bumps at segment
    /// boundaries.
    private static func kernelAverage(
        points: [TrackPoint],
        center: Int
    ) -> (latitude: Double, longitude: Double) {
        let lower = max(0, center - defaultKernelHalfWidth)
        let upper = min(points.count - 1, center + defaultKernelHalfWidth)
        var sumLat = 0.0
        var sumLng = 0.0
        var count = 0
        for i in lower...upper {
            sumLat += points[i].latitude
            sumLng += points[i].longitude
            count += 1
        }
        return (sumLat / Double(count), sumLng / Double(count))
    }

    /// Whether a (latitude, longitude) is within radius of any stroke
    /// sample.  Same flat-Euclidean approximation SimplifyBrush uses
    /// (cos(latitude) for the longitude scale factor);  for hiking
    /// scale the curvature error is well below the brush radius.
    private static func pointTouchedByStroke(
        latitude: Double,
        longitude: Double,
        stroke: [StrokeSample]
    ) -> Bool {
        for sample in stroke {
            let metresPerDegree = 111320.0
            let dy = (latitude - sample.latitude) * metresPerDegree
            let lonScale = cos(sample.latitude * .pi / 180.0)
            let dx = (longitude - sample.longitude) * metresPerDegree * lonScale
            let distanceMetres = (dx * dx + dy * dy).squareRoot()
            if distanceMetres <= sample.radiusMeters {
                return true
            }
        }
        return false
    }

    /// One (track, segment) pair affected by the brush apply.  Mirror
    /// of SimplifyBrush.TouchedSegment for caller-side consistency.
    public struct TouchedSegment: Equatable, Sendable {
        public let trackId: UUID
        public let segmentId: UUID

        public init(trackId: UUID, segmentId: UUID) {
            self.trackId = trackId
            self.segmentId = segmentId
        }
    }
}
