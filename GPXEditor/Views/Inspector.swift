// Inspector.swift
//
// The M7.5 inspector pane — right side of ContentView, attached via
// SwiftUI's `.inspector(isPresented:)` modifier (macOS 14+).
// Read-only at M7.5;  edit affordances (per-point lat/lon editing,
// per-segment color, per-track rename) wait for M8.
//
// Mode selection priority:
//
//   1. Selection has exactly one point → Point mode:  lat / lon /
//      elevation / timestamp readout for that point.  The single-
//      most-useful mode for verifying Pin to Ground / Snap to Ground
//      did the right thing.
//
//   2. Selection has more than one point → Multi-point mode:  count
//      summary only.  The elevation graph overlay below the map is
//      the primary visualization for multi-point selections;  the
//      inspector doesn't try to duplicate it.
//
//   3. Sidebar has a track selected (and selection is empty) → Track
//      mode:  the named track's name / point count / segment count
//      / recorded date.
//
//   4. Otherwise (nothing selected anywhere) → Project mode:  basic
//      project metadata (track count, active basemap).
//
// The mode is recomputed on every body invocation from the view
// model's @Published state, so any selection change re-renders the
// inspector through SwiftUI's normal observation flow.

import SwiftUI

struct Inspector: View {

    /// Binding to the document — drives Project mode's content.
    @Binding var document: GPXEditorDocument

    /// Per-window editing state — drives Point / Multi-point / Track
    /// modes via observation of `selection` and
    /// `selectedSidebarTrackId`.
    @ObservedObject var sessionVM: SessionViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch mode {
            case .point(let ref):
                pointSection(ref)
            case .multiPoint(let count):
                multiPointSection(count: count)
            case .track(let trackId):
                trackSection(trackId: trackId)
            case .project:
                projectSection
            }
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Mode resolution

    /// Read the active mode from the view-model state.  Pure
    /// computation;  no side effects.
    private var mode: Mode {
        if let ref = sessionVM.selection.singlePointReference {
            return .point(ref)
        }
        if !sessionVM.selection.isEmpty {
            return .multiPoint(count: sessionVM.selection.count)
        }
        if let trackId = sessionVM.selectedSidebarTrackId {
            return .track(trackId: trackId)
        }
        return .project
    }

    private enum Mode {
        case point(Selection.PointReference)
        case multiPoint(count: Int)
        case track(trackId: UUID)
        case project
    }

    // MARK: - Point mode

    /// Resolve the named (track, segment, index) triple to its
    /// TrackPoint and render lat / lon / ele / time as labelled
    /// readouts.  Stale references render an "unavailable" notice
    /// rather than crashing — defensive against any race where the
    /// selection lags a Delete operation.
    @ViewBuilder
    private func pointSection(_ ref: Selection.PointReference) -> some View {
        sectionHeader("Point")
        if let point = resolvePoint(ref) {
            row("Latitude", formatCoordinate(point.latitude))
            row("Longitude", formatCoordinate(point.longitude))
            row("Elevation", formatElevation(point.elevation))
            row("Time", formatTimestamp(point.time))
        } else {
            Text("Point reference no longer resolves.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func resolvePoint(_ ref: Selection.PointReference) -> TrackPoint? {
        guard let track = document.session.tracks.first(where: { $0.id == ref.trackId }),
              let segment = track.segments.first(where: { $0.id == ref.segmentId }),
              ref.pointIndex >= 0, ref.pointIndex < segment.points.count
        else { return nil }
        return segment.points[ref.pointIndex]
    }

    // MARK: - Multi-point mode

    /// Brief summary for multi-point selection.  The elevation graph
    /// below the map is the primary visualization;  the inspector
    /// just gives a count + a "see graph" prompt.
    @ViewBuilder
    private func multiPointSection(count: Int) -> some View {
        sectionHeader("Selection")
        row("Points", "\(count)")
        let segmentCount = uniqueSegmentCount()
        row("Segments touched", "\(segmentCount)")
        Text("Elevation graph for the selection is shown below the map.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 4)
    }

    /// How many distinct (track, segment) pairs the current selection
    /// touches.  Pure read of the canonical selection.
    private func uniqueSegmentCount() -> Int {
        var seen: Set<SegmentKey> = []
        for ref in sessionVM.selection.points {
            seen.insert(SegmentKey(trackId: ref.trackId, segmentId: ref.segmentId))
        }
        return seen.count
    }

    private struct SegmentKey: Hashable {
        let trackId: UUID
        let segmentId: UUID
    }

    // MARK: - Track mode

    /// Track-level info for the sidebar-selected track.  Read-only
    /// at M7.5 — the rename affordance and per-segment expansion are
    /// M8 territory.
    @ViewBuilder
    private func trackSection(trackId: UUID) -> some View {
        sectionHeader("Track")
        if let track = document.session.tracks.first(where: { $0.id == trackId }) {
            row("Name", track.name)
            let pointCount = track.segments.reduce(0) { $0 + $1.points.count }
            row("Points", "\(pointCount)")
            row("Segments", "\(track.segments.count)")
            row("Waypoints", "\(track.waypoints.count)")
            if let role = track.role {
                row("Role", role == .master ? "Master" : "Subsidiary")
            }
            if let recorded = track.recordedDate {
                row("Recorded", formatTimestamp(recorded))
            }
        } else {
            Text("Track not found.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Project mode

    /// Basic project metadata when nothing is selected.  Useful as
    /// a default state — lets the inspector pane give the user
    /// orientation rather than going blank.
    @ViewBuilder
    private var projectSection: some View {
        sectionHeader("Project")
        row("Tracks", "\(document.session.tracks.count)")
        row("Basemap", document.session.selectedBasemapId)
        Text("Click a track in the sidebar, or select points on the map, for more detail.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 4)
    }

    // MARK: - Reusable cells

    /// Small section header — keeps the inspector visually
    /// segmented without forcing a heavy NSBox / GroupBox.
    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .padding(.bottom, 4)
    }

    /// One labelled-value row.  Label is secondary-styled, value is
    /// primary.  Aligned via HStack so columns line up across rows
    /// even with variable-length labels.
    @ViewBuilder
    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .font(.body)
                .textSelection(.enabled)
            Spacer()
        }
    }

    // MARK: - Formatting

    /// Lat/lon to 6 decimal places — about 11cm precision at the
    /// equator, more than enough for any GPX use and not so many
    /// digits that the field becomes hard to read at a glance.
    private func formatCoordinate(_ value: Double) -> String {
        String(format: "%.6f°", value)
    }

    /// Elevation in meters with 1 decimal place.  Nil renders as a
    /// dash with a clarifying note rather than "0.0 m" (which would
    /// be misleading — no elevation recorded is different from
    /// elevation = 0).
    private func formatElevation(_ value: Double?) -> String {
        guard let value = value else { return "—" }
        return String(format: "%.1f m", value)
    }

    /// ISO-8601 in UTC for unambiguity.  Matches the GPX file's
    /// time-format convention (D-012);  the user can copy-paste the
    /// value into other tools without timezone confusion.
    private func formatTimestamp(_ date: Date?) -> String {
        guard let date = date else { return "—" }
        return Self.timestampFormatter.string(from: date)
    }

    /// Static so the formatter is reused across rows rather than
    /// reconstructed (init is non-trivial for ISO8601DateFormatter).
    private static let timestampFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
