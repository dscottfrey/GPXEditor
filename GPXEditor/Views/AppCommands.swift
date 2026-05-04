// AppCommands.swift
//
// SwiftUI Commands that extend the app's menu bar with project-specific
// actions:  primarily the File -> Import GPX... command that brings new
// tracks into the active document.
//
// Why this lives in Views/ rather than ViewModels/:  Commands are a
// SwiftUI Scene-level affordance (they're attached via .commands on
// the DocumentGroup) and depend on FocusedValues to find the active
// document.  Both are SwiftUI-native concepts; the file imports
// SwiftUI freely.
//
// The focused-document binding is the trick that makes per-document
// commands work in a multi-document app.  The DocumentGroup creates
// a fresh document binding for each window; ContentView publishes
// that binding into FocusedValues via .focusedSceneValue; the menu
// command consumes it via @FocusedBinding.  When no document window
// is frontmost, the binding is nil and the command disables itself.

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - FocusedValues plumbing
//
// SwiftUI's FocusedValues is a typed bag indexed by FocusedValueKey
// types.  Adding a key here makes the corresponding @FocusedBinding
// property wrapper work in any Commands or View descendant of a
// scene that publishes the value via .focusedSceneValue.

private struct DocumentFocusedValueKey: FocusedValueKey {
    typealias Value = Binding<GPXEditorDocument>
}

extension FocusedValues {
    /// The currently-focused window's document binding, or nil when no
    /// document window is frontmost (e.g. the Settings window or no
    /// windows at all).  Set in ContentView.body via .focusedSceneValue.
    var document: Binding<GPXEditorDocument>? {
        get { self[DocumentFocusedValueKey.self] }
        set { self[DocumentFocusedValueKey.self] = newValue }
    }
}

// MARK: - Commands

/// File-menu commands for GPXeditor.  Currently provides the Import
/// GPX... action; future tasks (M5+) extend this with Export GPX,
/// Export KML, etc.
struct AppCommands: Commands {

    /// The active document binding, or nil when no document window is
    /// frontmost.  Used by Import GPX to determine which session
    /// receives the imported tracks.
    @FocusedBinding(\.document) private var document: GPXEditorDocument?

    var body: some Commands {
        // Place Import GPX in the File menu, after the standard
        // New / Open / Save group.  CommandGroup(after: .newItem)
        // appends to the section that holds File -> New (.newItem).
        CommandGroup(after: .newItem) {
            Button("Import GPX…") {
                runImportGPX()
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])
            .disabled(document == nil)
        }
    }

    // MARK: - Import GPX implementation

    /// Run NSOpenPanel filtered to .gpx files, parse the chosen file
    /// via TrackImporter, append the resulting tracks to the active
    /// document's session.
    ///
    /// Errors are surfaced via NSAlert.  We deliberately do NOT use
    /// `try?` to swallow them ("nothing fails silently" per
    /// CONVENTIONS.md):  parser errors carry meaningful diagnostic
    /// information that the user might need to act on.
    @MainActor
    private func runImportGPX() {
        // No active document means nothing to import into.  The button
        // is disabled in this case but defensive guard guards against
        // any future code path that calls runImportGPX directly.
        guard document != nil else { return }

        // Configure the panel.  GPX files are UTType-registered system-
        // wide as com.topografix.gpx; UTType(filenameExtension:) finds
        // the registered type if Launch Services knows it, falling
        // back to plain XML matching otherwise.
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a GPX file to import."
        if let gpxType = UTType(filenameExtension: "gpx") {
            panel.allowedContentTypes = [gpxType]
        }

        guard panel.runModal() == .OK, let url = panel.url else {
            return  // user cancelled — not an error
        }

        // Read the file's bytes.  Permission to read is granted by the
        // sandbox via the user's NSOpenPanel selection; we do not need
        // a security-scoped bookmark here because we read the bytes
        // immediately and never re-access the URL.
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            presentImportError("Couldn't read file: \(error.localizedDescription)")
            return
        }

        // Run the importer.  existingTrackCount is the destination
        // session's current count; new tracks get palette colors that
        // start one slot past it.
        let existingCount = document?.session.tracks.count ?? 0
        let result = TrackImporter.importTracks(
            from: data,
            sourceFilename: url.lastPathComponent,
            existingTrackCount: existingCount
        )

        switch result {
        case .success(let newTracks):
            // Append to the document's session.  Reading and writing
            // through @FocusedBinding's projected setter keeps the
            // mutation in the SwiftUI document machinery's view —
            // autosave fires, the document goes "dirty," undo is
            // registered automatically.
            $document.wrappedValue?.session.tracks.append(contentsOf: newTracks)

        case .failure(let parseError):
            presentImportError("Couldn't import GPX: \(parseError)")
        }
    }

    /// Surface an import error via a modal NSAlert.  Used for both file-
    /// read errors and parser errors.  M5+ might replace this with a
    /// SwiftUI alert; for M1 the modal AppKit alert is the simplest
    /// thing that satisfies the "nothing fails silently" rule.
    @MainActor
    private func presentImportError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Import Failed"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
