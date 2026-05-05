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
    }
}

#Preview {
    ContentView(document: .constant(GPXEditorDocument()))
}
