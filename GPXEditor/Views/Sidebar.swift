// Sidebar.swift
//
// The M7.5 track-list sidebar — left pane of ContentView's
// NavigationSplitView.  Lists every track in the project with name,
// point count, segment count, and a master/subsidiary role badge
// when present.  Click a row to select that track for the
// Inspector's track-context mode (M7.5 readout-only — full
// per-segment expansion + edit affordances are M8 territory).
//
// Right-click on a row exposes the three M7.5 track-scoped actions:
// Zoom to fit, Select all points, Delete track.  All three are also
// surfaced via the menu bar (see AppCommands.swift) per CONVENTIONS.md
// "all right-click items reachable via menus."
//
// The sidebar is hideable via NavigationSplitView's built-in toolbar
// toggle (which AppKit also surfaces as View → Show/Hide Sidebar
// automatically, no extra wiring needed on our side).
//
// Per CONVENTIONS.md the file lives in Views/ rather than Components/
// because it's a top-level scene-scope pane (analogous to MapView),
// not a reusable fragment.

import SwiftUI

struct Sidebar: View {

    /// Binding to the document so row content updates as tracks are
    /// added / renamed / deleted / merged.  Read-only at the row
    /// level (we don't mutate from rows directly — actions go
    /// through SessionViewModel).
    @Binding var document: GPXEditorDocument

    /// SessionViewModel for the current window — drives the
    /// selectedSidebarTrackId published property and routes track-
    /// scoped operations.
    @ObservedObject var sessionVM: SessionViewModel

    var body: some View {
        // List with selection bound to the view model's published
        // sidebar-selected-track-id.  SwiftUI's selection binding is
        // typed as the Tag value (UUID here);  picking a row sets
        // the binding, picking nothing clears it.
        List(selection: $sessionVM.selectedSidebarTrackId) {
            // Section header gives the sidebar a clear "Tracks"
            // label even before track rows render.  Empty-state
            // text below the header surfaces when the project has
            // no tracks yet (fresh document).
            Section("Tracks") {
                if document.session.tracks.isEmpty {
                    Text("No tracks yet — File → Import GPX… (⌘⇧I)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                } else {
                    ForEach(document.session.tracks) { track in
                        TrackRow(track: track)
                            .tag(track.id)
                            // Right-click context menu — items wired
                            // up in the next M7.5 task.  Placeholder
                            // entries here so the gesture exists and
                            // visual affordances feel real.  Each
                            // action routes through SessionViewModel.
                            .contextMenu {
                                Button("Zoom to Fit") {
                                    sessionVM.zoomToTrack(trackId: track.id)
                                }
                                Button("Select All Points") {
                                    sessionVM.selectEntireTrack(trackId: track.id)
                                }
                                Divider()
                                Button("Delete Track", role: .destructive) {
                                    sessionVM.deleteTrack(trackId: track.id)
                                }
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 360)
    }
}

// MARK: - TrackRow

/// One row in the sidebar's track list.  Shows the track's name on
/// the first line, point + segment counts on the second, and a small
/// role badge ("Master" / "Subsidiary") when the track has a role
/// assigned.  Density tuned for the macOS sidebar look — compact
/// without truncating the most important field (the name).
private struct TrackRow: View {

    let track: Track

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(track.name)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let role = track.role {
                    Text(roleLabel(role))
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(roleColor(role).opacity(0.18), in: Capsule())
                        .foregroundStyle(roleColor(role))
                }
            }
            Text(secondaryLine)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Computed copy

    /// "N points · M segments" with proper pluralization.  Computed
    /// on each render — track sizes are small enough that walking
    /// segments to sum points is cheap, no caching needed.
    private var secondaryLine: String {
        let pointCount = track.segments.reduce(0) { $0 + $1.points.count }
        let segmentCount = track.segments.count
        let pointWord = pointCount == 1 ? "point" : "points"
        let segmentWord = segmentCount == 1 ? "segment" : "segments"
        return "\(pointCount) \(pointWord) · \(segmentCount) \(segmentWord)"
    }

    private func roleLabel(_ role: TrackRole) -> String {
        switch role {
        case .master: return "Master"
        case .subsidiary: return "Subsidiary"
        }
    }

    /// Tint for the role badge.  Master gets the system accent;
    /// subsidiary gets a more muted grey so the visual distinction
    /// is clear at a glance without color being the only signal
    /// (CONVENTIONS.md "Color is never the only signal").  The
    /// accompanying text label carries the meaning.
    private func roleColor(_ role: TrackRole) -> Color {
        switch role {
        case .master: return .accentColor
        case .subsidiary: return .secondary
        }
    }
}
