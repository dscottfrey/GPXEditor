// SimplifyBrush.swift
//
// The first concrete editing brush (M4).  Per D-015 the brush family
// shares a common architecture, but at M4 we ship just SimplifyBrush
// and defer factoring out a `BrushTool` protocol until M9 brings the
// other brushes online and a real abstraction earns its place.  The
// type here is concrete and self-contained;  the only bridge between
// it and the rest of the system is the `apply(...)` static function.
//
// Algorithm (D-016 says "simplest version that achieves the goal" —
// here that's classical Ramer-Douglas-Peucker on the brushed sub-range):
//
//   1. The brush stroke is a sequence of (lat, lon, radius_meters)
//      samples — one per cursor sample during the drag, posted from JS
//      via apply_brush.
//   2. For each segment in each track of the session, find every
//      contiguous range of point indices where every point falls within
//      `radius_meters` of *some* stroke sample.  These are the ranges
//      the brush "touched."
//   3. For each touched range, run RDPSimplifier on the points in that
//      range plus immediate neighbors as anchors (so the simplified
//      result connects cleanly to the surrounding untouched section).
//      Replace the original range with the surviving points.
//   4. Return the new session.
//
// Two values fixed for v1 (D-016 leaves them tunable for iteration):
//
//   - Default brush radius:  30 metres (passed in by JS;  v1 always
//     sends 30m, but the sample-level radius is preserved on the wire
//     for future variable-radius brushes).
//   - RDP tolerance:  the "aggressiveness" of the simplification.  Set
//     to a fraction of the brush radius so the two scale together —
//     a 30m brush with a 5m tolerance feels right for typical GPS-noise
//     removal.  Tunable based on Scott's first real-track use.
//
// Coordinate-system note:  RDPSimplifier operates in flat 2D Euclidean
// space.  We pass lat/lon directly as y/x;  for hiking-track scale
// (kilometres) the curvature error is negligible relative to the GPS
// noise we're filtering.  The brush radius and tolerance are converted
// from metres to a degree-equivalent at the boundary;  see
// `degreesPerMeter`.
//
// Per CONVENTIONS.md "platform-agnostic data layer," this file is
// Foundation-only.  No SwiftUI, no AppKit, no WebKit.

import Foundation

public enum SimplifyBrush {

    /// RDP tolerance for v1, expressed in metres.  Tuned during M4
    /// verification:  the initial 5m default produced visually
    /// imperceptible reductions on real tracks (4 points dropped from
    /// 1135 — Swift was doing the right thing arithmetically but the
    /// result was invisible).  10m is more aggressive and visibly
    /// removes GPS jitter without distorting real path geometry.
    /// Iteration paths in D-016:  add a slider, or tie tolerance to
    /// brush radius via a configurable ratio.
    public static let defaultToleranceMeters: Double = 10.0

    /// One sample from a brush stroke — the JS-side apply_brush
    /// payload's `stroke.samples` array maps to a list of these.
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

    /// Apply the simplify brush to a single track within a session.
    /// Returns the new session value plus the (track_id, segment_id)
    /// pairs that were touched — caller uses the touched list to drive
    /// a partial bridge update_tracks rather than re-broadcasting every
    /// track in the project.
    ///
    /// `trackId` constrains the operation to one track per call;  if
    /// the brush stroke crosses multiple tracks, the caller invokes
    /// `apply` once per touched track.  This matches the wire format
    /// (one apply_brush per track_id) and keeps the per-call domain
    /// clear.
    public static func apply(
        to session: GPXSession,
        trackId: UUID,
        stroke: [StrokeSample]
    ) -> (session: GPXSession, touched: [TouchedSegment]) {

        guard !stroke.isEmpty else {
            return (session, [])
        }
        guard let trackIndex = session.tracks.firstIndex(where: { $0.id == trackId }) else {
            // Stale or unknown track id — no-op rather than crash.
            return (session, [])
        }

        var newSession = session
        var track = newSession.tracks[trackIndex]
        var touched: [TouchedSegment] = []

        for segIdx in track.segments.indices {
            let segment = track.segments[segIdx]
            let originalPoints = segment.points
            if originalPoints.count < 3 {
                // Nothing to simplify in a 0/1/2-point segment.
                continue
            }

            // Identify which point indices are "in the brush region" —
            // their lat/lon is within radius of some stroke sample.
            // We use the per-sample radius rather than a global radius
            // because future variable-radius brushes might vary.
            var inRegion = [Bool](repeating: false, count: originalPoints.count)
            for i in originalPoints.indices {
                let p = originalPoints[i]
                if pointTouchedByStroke(latitude: p.latitude, longitude: p.longitude, stroke: stroke) {
                    inRegion[i] = true
                }
            }

            // Find contiguous ranges of in-region indices.  Each range
            // gets RDP-simplified independently, with its immediate
            // neighbors (one point on each side, where available) used
            // as fixed endpoints so the simplified subrange reconnects
            // cleanly to the untouched parts of the segment.
            let ranges = contiguousRanges(of: inRegion)
            if ranges.isEmpty { continue }

            // Build the new points array by walking the original and
            // splicing in simplified results for each touched range.
            var newPoints: [TrackPoint] = []
            newPoints.reserveCapacity(originalPoints.count)

            var copyCursor = 0
            for range in ranges {
                // Copy untouched points up to the range's first index
                // (exclusive) — we'll handle that index as the range's
                // anchor below.
                while copyCursor < range.lowerBound {
                    newPoints.append(originalPoints[copyCursor])
                    copyCursor += 1
                }

                // Build the polyline to simplify:  one anchor before
                // (if available), the range itself, one anchor after
                // (if available).  RDP preserves first and last input
                // points;  using the surrounding untouched points as
                // anchors means RDP can drop range-edge points whose
                // perpendicular distance is small relative to the
                // straight line to the anchor — the typical RDP
                // behavior we want.
                let anchorBeforeIndex = range.lowerBound > 0 ? range.lowerBound - 1 : nil
                let anchorAfterIndex = range.upperBound < originalPoints.count - 1 ? range.upperBound + 1 : nil

                var rdpInput: [RDPSimplifier.Point2D] = []
                var inputIndices: [Int] = []
                if let i = anchorBeforeIndex {
                    rdpInput.append(point2D(from: originalPoints[i]))
                    inputIndices.append(i)
                }
                for i in range.lowerBound...range.upperBound {
                    rdpInput.append(point2D(from: originalPoints[i]))
                    inputIndices.append(i)
                }
                if let i = anchorAfterIndex {
                    rdpInput.append(point2D(from: originalPoints[i]))
                    inputIndices.append(i)
                }

                // Convert the metre-tolerance to a degree-equivalent at
                // the latitude of the first point in the range.  Cheap
                // approximation;  full-precision spherical math is
                // unnecessary at hiking-track scale.
                let referenceLatitude = originalPoints[range.lowerBound].latitude
                let toleranceDegrees = degreesPerMeter(latitude: referenceLatitude) * defaultToleranceMeters

                let keptInputPositions = RDPSimplifier.simplify(rdpInput, tolerance: toleranceDegrees)
                let keptOriginalIndices = keptInputPositions.map { inputIndices[$0] }

                // Append the surviving original points, but skip the
                // anchor-before (we've already appended it as part of
                // the untouched copy above) and skip the anchor-after
                // (we'll let the next iteration's untouched-copy phase
                // pick it up).
                for keptIndex in keptOriginalIndices {
                    if keptIndex == anchorBeforeIndex { continue }
                    if keptIndex == anchorAfterIndex { continue }
                    newPoints.append(originalPoints[keptIndex])
                }
                // Advance copyCursor past the range — next iteration
                // (or the trailing copy below) starts at upperBound+1.
                copyCursor = range.upperBound + 1
            }

            // Tail copy:  remaining untouched points after the last range.
            while copyCursor < originalPoints.count {
                newPoints.append(originalPoints[copyCursor])
                copyCursor += 1
            }

            // Defensive — only commit the change if the new array is
            // shorter (simplification can't add points).  Equal-length
            // means no points were within tolerance to drop;  shorter
            // means some were dropped.  Longer would indicate a bug.
            if newPoints.count != originalPoints.count {
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

    /// Whether a point at (latitude, longitude) is within radius_meters
    /// of any stroke sample.  Linear scan — for v1 the stroke sample
    /// counts are small (a brush gesture is at most a couple hundred
    /// samples, the segment a few thousand points;  the inner-product
    /// is a million-or-so comparisons per gesture, well under any
    /// noticeable latency).  If the brush ever gets unwieldy, an R-tree
    /// index over the stroke samples would speed this up.
    private static func pointTouchedByStroke(
        latitude: Double,
        longitude: Double,
        stroke: [StrokeSample]
    ) -> Bool {
        for sample in stroke {
            // Approximate metres-per-degree at the sample's latitude.
            // Conservative — uses the sample's latitude for the
            // longitude factor;  for hiking-track scale (a few km
            // across a single brush stroke) this is plenty accurate.
            let metresPerDegree = 1.0 / degreesPerMeter(latitude: sample.latitude)
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

    /// Approximate degrees per metre at a given latitude.  Latitude
    /// degrees are approximately 111320 metres each globally;
    /// longitude degrees shrink by cos(latitude).  We return a single
    /// scalar (the "y-axis" rate) and the caller applies the cosine
    /// factor when working in x.  Good enough for hiking scale.
    private static func degreesPerMeter(latitude: Double) -> Double {
        return 1.0 / 111320.0
    }

    /// Convert a TrackPoint to RDP's coordinate space.  We use
    /// x = longitude, y = latitude — the algorithm is symmetric in axes
    /// so the choice is purely conventional.  Latitude maps better to
    /// "vertical" if anyone visualizes the inputs.
    private static func point2D(from p: TrackPoint) -> RDPSimplifier.Point2D {
        return RDPSimplifier.Point2D(x: p.longitude, y: p.latitude)
    }

    /// Find contiguous ranges of `true` in a Bool array.  Returned as
    /// inclusive index ranges (lower...upper).  An array of all-false
    /// returns [].
    private static func contiguousRanges(of flags: [Bool]) -> [ClosedRange<Int>] {
        var ranges: [ClosedRange<Int>] = []
        var start: Int? = nil
        for i in flags.indices {
            if flags[i] {
                if start == nil { start = i }
            } else if let s = start {
                ranges.append(s...(i - 1))
                start = nil
            }
        }
        if let s = start {
            ranges.append(s...(flags.count - 1))
        }
        return ranges
    }

    /// One (track, segment) pair affected by the brush apply.  Mirror
    /// of DeleteOperation.TouchedSegment so callers can use both
    /// operations through the same diff-broadcast path.
    public struct TouchedSegment: Equatable, Sendable {
        public let trackId: UUID
        public let segmentId: UUID

        public init(trackId: UUID, segmentId: UUID) {
            self.trackId = trackId
            self.segmentId = segmentId
        }
    }
}
