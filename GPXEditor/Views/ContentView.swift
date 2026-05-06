// ContentView.swift
//
// Root view of the document window.  At M3 it composes:
//
//   - MapView (the WKWebView surface running Leaflet + editor.js).
//   - BasemapSelectorView pinned to the top-right as an overlay.
//   - The per-window SessionViewModel — created here as @StateObject so
//     each document window has its own selection / tool state, published
//     into FocusedValues so AppCommands menu items can address the
//     active window's view model.
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

    var body: some View {
        // MapView is the entire screen at M3;  the SwiftUI overlay
        // stack draws the basemap selector above it without occupying
        // its own frame.  Padding around the overlay keeps the picker
        // from kissing the window edges.
        MapView(document: $document, sessionVM: sessionVM)
            .overlay(alignment: .topTrailing) {
                BasemapSelectorView(document: $document)
                    .padding(12)
            }
            // Stopgap track-count overlay until the sidebar lands at
            // M8.  Without any track-listing UI, users have no way
            // to know how many tracks the project contains, and
            // gates like "Merge Track Into…" (which require tracks
            // >= 2) become invisible when their preconditions
            // aren't met.  Delete this overlay when the M8 sidebar
            // ships — the sidebar is the proper home for project-
            // structure visibility.
            .overlay(alignment: .topLeading) {
                Text("Tracks: \(document.session.tracks.count)")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                    .padding(12)
            }
            .frame(minWidth: 640, minHeight: 480)
            // Publish the document binding (already in M2) and the
            // SessionViewModel into FocusedValues so menu commands
            // can find both.  Both bindings/values are scene-scoped:
            // when this window isn't frontmost, neither is visible to
            // commands.
            .focusedSceneValue(\.document, $document)
            .focusedSceneValue(\.sessionViewModel, sessionVM)
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
    }
}

#Preview {
    ContentView(document: .constant(GPXEditorDocument()))
}
