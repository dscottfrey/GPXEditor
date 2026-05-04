// GPXEditorApp.swift
//
// The application entry point.  Declares the @main App type and the scene
// graph hosted by SwiftUI's runtime.
//
// At M0 (project skeleton) the scene graph is a single placeholder
// WindowGroup containing ContentView.  At M1 this is replaced by a
// DocumentGroup wired to the .gpxeditor FileDocument so File -> Open,
// File -> Save, File -> New, drag-onto-dock, and Finder file association
// all work through SwiftUI's native document plumbing rather than custom
// AppKit glue.  See HANDOFF.md "M1 - GPX I/O and project file format" and
// Decision D-008 for why the document model is structured this way.

import SwiftUI

@main
struct GPXEditorApp: App {
    var body: some Scene {
        // WindowGroup is intentionally placeholder shell for M0 only.  M1
        // swaps this for a DocumentGroup and the project becomes
        // document-based (one window per open .gpxeditor project).  The
        // .commands modifier below is Scene-attached, so it migrates to
        // the DocumentGroup along with the rest of the scene wiring.
        WindowGroup {
            ContentView()
        }
        .commands {
            // Replace SwiftUI's default "About GPXeditor" menu item with
            // one that routes through AboutPanel.show() so the build
            // identifier (timestamp + git SHA + dirty marker) appears in
            // the standard About panel's Credits area.  See AboutPanel.swift
            // and Scripts/generate_build_info.sh for why this matters.
            CommandGroup(replacing: .appInfo) {
                Button("About GPXeditor") {
                    AboutPanel.show()
                }
            }
        }
    }
}
