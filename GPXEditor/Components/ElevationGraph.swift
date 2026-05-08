// ElevationGraph.swift
//
// The M7.5 elevation graph — wide-and-short bar at the bottom of
// the detail pane, visible only when a non-empty selection exists.
// Renders elevation against cumulative distance for the selected
// points using Swift Charts.
//
// Non-contiguous selections (e.g., a marquee that catches both ends
// of an out-and-back track) are rendered as separate runs with
// visible gaps between them — the "more magnified" form preferred
// over showing the whole track with selection highlighted.  Each
// contiguous run is its own LineMark series in the chart, which
// Swift Charts honors by NOT connecting lines across series — the
// gap appears naturally.
//
// X-axis units:  cumulative distance within the selection, using
// the haversine great-circle formula on lat/lon pairs (small
// dependency-free, accurate to ~0.5% which is well within "good
// enough for a visualization").  Inter-run gaps are inserted as a
// fixed fraction of the total selection length so the runs visually
// separate without dominating the chart for a small gap or
// vanishing for a huge one.
//
// Y-axis units:  meters above the WGS84 ellipsoid (the same units
// the GPX file stores).  Points with no elevation are skipped — a
// missing-elevation point in the middle of a run breaks that run
// into two sub-runs at the same x-axis position.  This is honest
// (we shouldn't fabricate a value to keep the line continuous) and
// rare in practice (tracks either have elevations or don't).
//
// Per CONVENTIONS.md the file lives in Components/ since it's a
// reusable UI fragment smaller than a screen.

import SwiftUI
import Charts

struct ElevationGraph: View {

    /// Read access to the document — drives the lookup from
    /// PointReference to lat/lon/elevation.
    @Binding var document: GPXEditorDocument

    /// View model whose @Published selection drives the graph
    /// content.  When selection clears, the parent view is
    /// responsible for hiding/dismissing the graph;  this view
    /// renders an empty chart rather than EmptyView when the
    /// selection is empty so the slide-in animation has a stable
    /// view identity.
    @ObservedObject var sessionVM: SessionViewModel

    var body: some View {
        let runs = computeRuns()
        VStack(alignment: .leading, spacing: 4) {
            chartHeader(runs: runs)
            chart(runs: runs)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(12)
    }

    // MARK: - Header

    /// Small header line above the chart showing what's being
    /// plotted.  Useful orientation when the chart's contents
    /// aren't intuitive at a glance (a 50-point selection across
    /// two runs in different parts of an out-and-back).
    @ViewBuilder
    private func chartHeader(runs: [Run]) -> some View {
        HStack(spacing: 8) {
            Text("Elevation")
                .font(.caption)
                .fontWeight(.semibold)
            if runs.count > 1 {
                Text("\(runs.count) runs · \(totalPoints(runs)) points")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let first = runs.first {
                Text("\(first.points.count) points")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let range = elevationRange(runs) {
                Text("min \(formatEle(range.min)) · max \(formatEle(range.max))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func totalPoints(_ runs: [Run]) -> Int {
        runs.reduce(0) { $0 + $1.points.count }
    }

    private func elevationRange(_ runs: [Run]) -> (min: Double, max: Double)? {
        var minEle: Double = .greatestFiniteMagnitude
        var maxEle: Double = -.greatestFiniteMagnitude
        var saw = false
        for run in runs {
            for p in run.points {
                if let ele = p.elevation {
                    saw = true
                    if ele < minEle { minEle = ele }
                    if ele > maxEle { maxEle = ele }
                }
            }
        }
        return saw ? (minEle, maxEle) : nil
    }

    private func formatEle(_ value: Double) -> String {
        String(format: "%.0f m", value)
    }

    // MARK: - Chart

    /// The Swift Chart itself.  Each Run is its own LineMark series
    /// so Swift Charts doesn't connect lines across runs — the
    /// gaps are the visual signal that the selection is non-
    /// contiguous.  Mode-specific styling:  small dot at each
    /// point so individual elevations are visible at low point
    /// counts;  thin line so the trend is readable at high counts.
    @ViewBuilder
    private func chart(runs: [Run]) -> some View {
        Chart {
            ForEach(runs) { run in
                ForEach(run.points) { p in
                    if let ele = p.elevation {
                        LineMark(
                            x: .value("Distance", p.x),
                            y: .value("Elevation", ele),
                            series: .value("Run", run.id.uuidString)
                        )
                        .foregroundStyle(.blue)
                        PointMark(
                            x: .value("Distance", p.x),
                            y: .value("Elevation", ele)
                        )
                        .foregroundStyle(.blue)
                        .symbolSize(12)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(format: DistanceFormat())
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisTick()
                AxisValueLabel(format: ElevationFormat())
            }
        }
        .frame(height: 120)
    }

    // MARK: - Run computation

    /// Walk the canonical selection, group by (track, segment),
    /// and split each group into contiguous index runs.  Each run
    /// gets a per-point x-coordinate that's cumulative haversine
    /// distance from the run's first point.  Inter-run x-offsets
    /// are computed so consecutive runs get separated by a fixed
    /// visual gap (5% of total selection length) that reads as
    /// "broken line" on the chart without dominating the axis.
    private func computeRuns() -> [Run] {

        // Collect refs grouped by (trackId, segmentId) and sort
        // each group by pointIndex.  We don't try to preserve any
        // particular order across groups — just walk groups in a
        // deterministic order (sorted by trackId then segmentId).
        var groups: [SegmentKey: [Int]] = [:]
        for ref in sessionVM.selection.points {
            let key = SegmentKey(trackId: ref.trackId, segmentId: ref.segmentId)
            groups[key, default: []].append(ref.pointIndex)
        }
        for key in groups.keys {
            groups[key]?.sort()
        }

        // Walk groups in deterministic order.  Within each group,
        // split into contiguous index runs (consecutive integers).
        let sortedKeys = groups.keys.sorted { lhs, rhs in
            if lhs.trackId != rhs.trackId {
                return lhs.trackId.uuidString < rhs.trackId.uuidString
            }
            return lhs.segmentId.uuidString < rhs.segmentId.uuidString
        }

        var runs: [Run] = []
        for key in sortedKeys {
            guard let indices = groups[key] else { continue }
            guard let track = document.session.tracks.first(where: { $0.id == key.trackId }),
                  let segment = track.segments.first(where: { $0.id == key.segmentId })
            else { continue }

            // Split indices into contiguous runs.
            var currentRun: [Int] = []
            var contigRuns: [[Int]] = []
            for idx in indices {
                if let last = currentRun.last, idx != last + 1 {
                    contigRuns.append(currentRun)
                    currentRun = [idx]
                } else {
                    currentRun.append(idx)
                }
            }
            if !currentRun.isEmpty {
                contigRuns.append(currentRun)
            }

            // Build Run objects from each contiguous index sequence.
            for indexRun in contigRuns {
                var points: [RunPoint] = []
                var cumulativeDistance: Double = 0
                var prevPoint: TrackPoint?
                for idx in indexRun {
                    guard idx >= 0, idx < segment.points.count else { continue }
                    let pt = segment.points[idx]
                    if let prev = prevPoint {
                        cumulativeDistance += haversineDistance(
                            lat1: prev.latitude, lon1: prev.longitude,
                            lat2: pt.latitude, lon2: pt.longitude
                        )
                    }
                    points.append(RunPoint(
                        id: UUID(),
                        x: cumulativeDistance,
                        elevation: pt.elevation
                    ))
                    prevPoint = pt
                }
                if !points.isEmpty {
                    runs.append(Run(id: UUID(), points: points))
                }
            }
        }

        // Now offset each run's x-coordinates so they appear in
        // sequence on the chart with a fixed-fraction gap between
        // them.  A gap of 5% of total length is enough to read as
        // "broken" without dominating the axis.
        let totalIntrinsic = runs.reduce(0) { $0 + ($1.points.last?.x ?? 0) }
        let gap = max(totalIntrinsic * 0.05, 1.0)
        var offset: Double = 0
        var offsetRuns: [Run] = []
        for run in runs {
            let shifted = run.points.map { p in
                RunPoint(id: p.id, x: p.x + offset, elevation: p.elevation)
            }
            offsetRuns.append(Run(id: run.id, points: shifted))
            offset += (run.points.last?.x ?? 0) + gap
        }
        return offsetRuns
    }

    // MARK: - Run model (private)

    private struct Run: Identifiable {
        let id: UUID
        let points: [RunPoint]
    }

    private struct RunPoint: Identifiable {
        let id: UUID
        let x: Double            // cumulative distance, with run offset applied
        let elevation: Double?   // nil = no recorded elevation
    }

    private struct SegmentKey: Hashable {
        let trackId: UUID
        let segmentId: UUID
    }

    // MARK: - Haversine distance

    /// Haversine great-circle distance in meters between two
    /// (lat, lon) points in degrees.  Adequate accuracy
    /// (~0.5%) for visualization purposes;  a more accurate
    /// formula (Vincenty) would be overkill for the chart.
    private func haversineDistance(
        lat1: Double, lon1: Double,
        lat2: Double, lon2: Double
    ) -> Double {
        let earthRadius: Double = 6_371_000  // meters
        let φ1 = lat1 * .pi / 180
        let φ2 = lat2 * .pi / 180
        let Δφ = (lat2 - lat1) * .pi / 180
        let Δλ = (lon2 - lon1) * .pi / 180
        let a = sin(Δφ / 2) * sin(Δφ / 2)
              + cos(φ1) * cos(φ2)
              * sin(Δλ / 2) * sin(Δλ / 2)
        let c = 2 * atan2(sqrt(a), sqrt(1 - a))
        return earthRadius * c
    }
}

// MARK: - Axis formatters

/// X-axis formatter — meters or kilometers depending on magnitude,
/// because a 50-point selection might span 100m or 50km.
private struct DistanceFormat: FormatStyle {
    func format(_ value: Double) -> String {
        if value >= 1_000 {
            return String(format: "%.1f km", value / 1_000)
        }
        return String(format: "%.0f m", value)
    }
}

/// Y-axis formatter — meters with 0 decimal places.  GPX
/// elevations are typically integer-meter precision anyway.
private struct ElevationFormat: FormatStyle {
    func format(_ value: Double) -> String {
        String(format: "%.0f m", value)
    }
}
