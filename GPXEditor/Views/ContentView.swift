// ContentView.swift
//
// Root view of the document window.  At M7.5 it composes:
//
//   - A NavigationSplitView with the track-list Sidebar on the left
//     and the MapView (WKWebView surface running Leaflet + editor.js)
//     as the detail.  Sidebar is hideable via NavigationSplitView's
//     built-in toolbar toggle (which AppKit also surfaces as
//     View → Show/Hide Sidebar automatically — no extra wiring).
//   - BasemapSelectorView pinned to the top-right of the detail as
//     an overlay.
//   - The per-window SessionViewModel — created here as @StateObject
//     so each document window has its own selection / tool / sidebar-
//     selection state, published into FocusedValues so AppCommands
//     menu items can address the active window's view model.
//
// The wiring of SessionViewModel.documentBinding and .undoManager
// happens here too:  SwiftUI's @StateObject creates the view model
// before the binding/undo-manager are available, so we connect them
// via .onAppear and .onChange — the SessionViewModel guards against
// nil references with no-op fallbacks for any race during teardown.

import SwiftUI

struct ContentView: View {

    /// Two-way binding to the document.  Mutations propagate back
    /// through DocumentGroup's autosave machinery.  The basemap
    /// selector and SessionViewModel both write through this binding.
    @Binding var document: GPXEditorDocument

    /// Per-window editing state (selection, active tool).  @StateObject
    /// because SwiftUI must own the lifecycle:  one SessionViewModel
    /// per window, alive for the window's lifetime.
    @StateObject private var sessionVM = SessionViewModel()

    /// The document window's UndoManager.  Pulled from the SwiftUI
    /// environment;  injected into SessionViewModel so its delete /
    /// future operations register undo against the correct manager.
    @Environment(\.undoManager) private var undoManager

    /// M7.5 inspector pane visibility.  Defaults to visible —
    /// during the M7.5/M8 testing-and-build phase the inspector is
    /// the primary verification tool, so showing it on first launch
    /// surfaces it before the user has to discover the toggle.
    /// SwiftUI's .inspector(isPresented:) modifier provides the
    /// toolbar toggle button and the View-menu Show/Hide entry
    /// automatically.
    @State private var inspectorPresented: Bool = true

    var body: some View {
        NavigationSplitView {
            // Left pane:  M7.5 track-list sidebar.  Hideable via
            // the NavigationSplitView toolbar toggle / View menu.
            Sidebar(document: $document, sessionVM: sessionVM)
        } detail: {
            // Detail pane:  MapView fills the available space.  The
            // basemap selector is anchored at the top-right corner
            // as an overlay so it floats above the WebView without
            // claiming layout space of its own.  The M7.5 elevation
            // graph is anchored at the bottom and slides in/out
            // based on selection state — visible only when the
            // selection has at least one point, hidden otherwise.
            MapView(document: $document, sessionVM: sessionVM)
                .overlay(alignment: .topTrailing) {
                    BasemapSelectorView(document: $document)
                        .padding(12)
                }
                .overlay(alignment: .bottom) {
                    if !sessionVM.selection.isEmpty {
                        ElevationGraph(document: $document, sessionVM: sessionVM)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: sessionVM.selection.isEmpty)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 1000, minHeight: 480)
        // M7.5 inspector pane.  `.inspector(isPresented:)` adds a
        // hideable right-side pane and (on macOS 14+) automatically
        // surfaces a toolbar toggle plus the View → Show/Hide
        // Inspector menu entry.  Default visible because the
        // inspector is the primary verification surface during the
        // current build phase.
        .inspector(isPresented: $inspectorPresented) {
            Inspector(document: $document, sessionVM: sessionVM)
                .inspectorColumnWidth(min: 220, ideal: 260, max: 360)
        }
            // Publish the document binding (already in M2) and the
            // SessionViewModel into FocusedValues so menu commands
            // can find both.  Both bindings/values are scene-scoped:
            // when this window isn't frontmost, neither is visible to
            // commands.
            .focusedSceneValue(\.document, $document)
            // SessionViewModel must be published with `.focusedSceneObject`
            // (and read with `@FocusedObject` in AppCommands) rather than
            // `.focusedSceneValue` + `@FocusedValue`, because the latter
            // pair does not subscribe to the ObservableObject's
            // @Published changes.  Result of getting that wrong:  every
            // selection-aware menu command (Delete, Reverse Track, Pin
            // to Ground, etc.) reads a stale `selection.isEmpty` value
            // and never re-evaluates after `selectAll()` populates the
            // selection — making the menu items appear permanently
            // disabled in fresh-untitled documents until something
            // forces a fresh evaluation (e.g., save+reopen).  See
            // HANDOFF.md M7 outcome notes for the diagnostic trail.
            .focusedSceneObject(sessionVM)
            // Connect SessionViewModel to its environment dependencies.
            // .onAppear handles the first attach;  .onChange handles
            // the case where SwiftUI hands us a different undoManager
            // instance later (which can happen when scenes recompose).
            .onAppear {
                sessionVM.documentBinding = $document
                sessionVM.undoManager = undoManager
            }
            .onChange(of: undoManager) { _, newUndoManager in
                sessionVM.undoManager = newUndoManager
            }
            // M5 follow-up:  Edit-Coordinates sheet driven by the
            // session VM's published request state.  The right-click
            // context-menu's "Edit Coordinates…" item sets
            // `editCoordinatesRequest`;  SwiftUI presents the sheet;
            // the sheet's onCommit calls applyMovePoint with the
            // entered values.
            .sheet(item: $sessionVM.editCoordinatesRequest) { request in
                EditCoordinatesSheet(
                    initialLatitude: request.initialLatitude,
                    initialLongitude: request.initialLongitude,
                    onCommit: { newLat, newLon in
                        sessionVM.applyMovePoint(
                            trackId: request.trackId,
                            segmentId: request.segmentId,
                            pointIndex: request.pointIndex,
                            latitude: newLat,
                            longitude: newLon
                        )
                    }
                )
            }
            // M6:  Merge-Track-Picker sheet.  The Edit menu's "Merge
            // Track Into…" item (and the right-click vertex menu's
            // same item) sets `mergeTracksRequest`;  SwiftUI presents
            // the picker;  the picker's onCommit calls applyMergeTracks
            // after running its NSAlert confirmation.
            .sheet(item: $sessionVM.mergeTracksRequest) { request in
                MergeTrackPickerSheet(
                    destinationName: request.destinationName,
                    candidates: request.candidates,
                    onCommit: { sourceId in
                        sessionVM.applyMergeTracks(
                            sourceId: sourceId,
                            destinationId: request.destinationId
                        )
                    }
                )
            }
            // M6:  Trim Track dialog.  The Edit menu's "Trim Track…"
            // item (and the right-click vertex-menu equivalent) sets
            // `trimTrackRequest`;  the sheet's onPreview drives the
            // live red-marker overlay via SessionViewModel's
            // `trimPreviewGroups` published state, which MapView
            // observes and dispatches over the bridge.  onDismiss
            // (fired on any close path including Escape) clears the
            // preview;  onCommit applies the trim with undo.
            .sheet(item: $sessionVM.trimTrackRequest) { request in
                TrimTrackSheet(
                    trackName: request.trackName,
                    timestampRange: request.timestampRange,
                    onPreview: { startBefore, endAfter in
                        sessionVM.updateTrimPreview(
                            trackId: request.trackId,
                            startBefore: startBefore,
                            endAfter: endAfter
                        )
                    },
                    onCommit: { startBefore, endAfter in
                        sessionVM.applyTrimTrack(
                            trackId: request.trackId,
                            startBefore: startBefore,
                            endAfter: endAfter
                        )
                    },
                    onDismiss: {
                        sessionVM.clearTrimPreview()
                    }
                )
            }
            // M7:  Pin-to-Ground confirmation-and-progress sheet.  The
            // Edit menu's "Pin to Ground…" item (and downstream paths)
            // sets `pinToGroundRequest`;  the sheet runs its own async
            // ElevationService loop with progress and Cancel, then
            // calls back into applyPinToGround with the parallel
            // elevations on success.  The sheet manages its own
            // network state — the view model is the commit point only.
            .sheet(item: $sessionVM.pinToGroundRequest) { request in
                PinToGroundSheet(
                    request: request,
                    onCommit: { refs, newElevations in
                        sessionVM.applyPinToGround(
                            refs: refs,
                            newElevations: newElevations,
                            actionName: "Pin to Ground"
                        )
                    }
                )
            }
    }
}

#Preview {
    ContentView(document: .constant(GPXEditorDocument()))
}
