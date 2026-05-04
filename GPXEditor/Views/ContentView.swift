// ContentView.swift
//
// The root view of the M0 placeholder window.  Its only job is to prove
// that the app launches, signs, and runs sandboxed - it shows the project's
// display name and nothing else.
//
// This file is replaced wholesale at M2/M5 once the real editing UI lands:
// at that point ContentView becomes the top-level layout host (sidebar +
// map + inspector split view) and the placeholder text below disappears.
// Until then it stays deliberately featureless so any visible content in
// the dev build is unambiguously M0 rather than partially-implemented work.

import SwiftUI

struct ContentView: View {
    var body: some View {
        // The display name is "GPXeditor" with a lowercase 'e' per D-001;
        // the code-side identifier is "GPXEditor" with capital E.  The two
        // are deliberately different - the code identifier follows Swift's
        // PascalCase + acronym-as-word convention, while the display string
        // is what the user sees in the menu bar, About panel, and dock.
        Text("GPXeditor")
            .font(.largeTitle)
            .padding()
            .frame(minWidth: 400, minHeight: 240)
    }
}

#Preview {
    ContentView()
}
