// ContentView.swift
//
// Root view of the document window.  At M2 (map view + basemap selector)
// it composes the MapView (the WKWebView surface running Leaflet +
// editor.js) with a BasemapSelectorView overlay pinned to the top-right.
//
// The real editing UI grows in around this:  the sidebar / inspector /
// stats split-view layout lands at M8.  Until then ContentView is a
// minimal frame around MapView so the WebView fills the window.
//
// Track count is no longer displayed — at M2 the WebView itself shows
// the user whether tracks are present.  If a regression test wants the
// pre-M2 "track count" verification, it can read
// `document.session.tracks.count` directly.

import SwiftUI

struct ContentView: View {

    /// Two-way binding to the document.  Mutations propagate back
    /// through DocumentGroup's autosave machinery — the basemap
    /// selector writes through this binding when the user picks a
    /// different basemap, and future milestones write track edits and
    /// viewport state the same way.
    @Binding var document: GPXEditorDocument

    var body: some View {
        // MapView is the entire screen at M2;  the SwiftUI overlay
        // stack draws the basemap selector above it without occupying
        // its own frame.  Padding around the overlay keeps the picker
        // from kissing the window edges.
        MapView(document: $document)
            .overlay(alignment: .topTrailing) {
                BasemapSelectorView(document: $document)
                    .padding(12)
            }
            // Larger minimum so a sensible map area is always visible.
            // The minimum is generous because tile rendering at small
            // sizes wastes time and looks bad;  users can still resize
            // smaller if they really want to.
            .frame(minWidth: 640, minHeight: 480)
            // Publish this window's document binding into FocusedValues
            // so menu commands (AppCommands.swift) can find the active
            // document via @FocusedBinding(\.document).
            .focusedSceneValue(\.document, $document)
    }
}

#Preview {
    ContentView(document: .constant(GPXEditorDocument()))
}
