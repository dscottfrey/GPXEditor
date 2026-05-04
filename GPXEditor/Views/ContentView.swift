// ContentView.swift
//
// Root view of the document window.  At M1 (the FileDocument /
// DocumentGroup wiring milestone) it accepts a Binding<GPXEditorDocument>
// from the surrounding DocumentGroup and shows minimal placeholder
// content — the project name plus the current track count — to confirm
// the document is wired up and reading correctly.  The real editing UI
// (sidebar + map + inspector split view) lands at M5/M8.
//
// Until then, this view's only purpose is to verify that opening a
// .gpxeditor file populates the binding with a usable GPXSession and
// that File -> New produces an empty document with track count 0.

import SwiftUI

struct ContentView: View {

    /// Two-way binding to the document.  Any mutation propagates back
    /// through DocumentGroup's autosave machinery.  Until the editing UI
    /// lands, this view only reads from the binding — but accepting it
    /// as Binding (not just letting through a value type) keeps the
    /// contract correct from M1 onward.
    @Binding var document: GPXEditorDocument

    var body: some View {
        VStack(spacing: 12) {
            // Display name is "GPXeditor" (lowercase 'e') per D-001.
            // CFBundleDisplayName in Info.plist matches.
            Text("GPXeditor")
                .font(.largeTitle)

            // Track count is the simplest correctness signal:  if
            // import works, this number ticks up; if Reset to Original
            // works, the count is preserved.  Replaced with the real
            // sidebar at M8.
            Text("\(document.session.tracks.count) track\(document.session.tracks.count == 1 ? "" : "s")")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(minWidth: 400, minHeight: 240)
    }
}

#Preview {
    // Provide a non-mutating binding for the preview.  An actual document
    // window in a running build gets its binding from DocumentGroup.
    ContentView(document: .constant(GPXEditorDocument()))
}
