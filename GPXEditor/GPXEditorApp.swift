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
        // M1 task #7 swapped the M0 placeholder WindowGroup for a
        // DocumentGroup — the project is now document-based, with one
        // window per open .gpxeditor file plus the standard File -> New
        // / File -> Open / drag-onto-dock plumbing SwiftUI provides
        // automatically when a FileDocument is wired up.
        //
        // The newDocument: closure produces an empty GPXEditorDocument
        // for File -> New.  Each opened or newly-created document yields
        // a $document binding that ContentView reads/writes.
        DocumentGroup(newDocument: GPXEditorDocument()) { configuration in
            ContentView(document: configuration.$document)
        }
        .commands {
            // Replace SwiftUI's default "About GPXeditor" menu item with
            // one that routes through AboutPanel.show() so the build
            // identifier (timestamp + git SHA + dirty marker) appears in
            // the standard About panel's Credits area.  See AboutPanel.swift
            // and Scripts/generate_build_info.sh for why this matters.
            // .commands attaches to the active scene; it migrates with
            // the WindowGroup -> DocumentGroup swap automatically.
            CommandGroup(replacing: .appInfo) {
                Button("About GPXeditor") {
                    AboutPanel.show()
                }
            }
        }
    }
}
