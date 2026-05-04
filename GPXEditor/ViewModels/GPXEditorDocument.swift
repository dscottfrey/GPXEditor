// GPXEditorDocument.swift
//
// SwiftUI FileDocument wrapper around GPXSession.  Bridges the platform-
// agnostic GPXSession model (which lives in Models/ and cannot import
// SwiftUI per CONVENTIONS.md "platform-agnostic data layer") to the
// SwiftUI scene plumbing — DocumentGroup gives ContentView a
// `Binding<GPXEditorDocument>`, mutations to which automatically mark
// the document dirty and trigger autosave per FileDocument's contract.
//
// All on-disk I/O routes through Services/ProjectFile.swift; this type's
// only job is to satisfy the FileDocument protocol and translate
// ProjectFileError into the throws contract that FileDocument expects.
//
// Lives in ViewModels/ because it's the connective tissue between
// Models (GPXSession) and Views (DocumentGroup, ContentView):  it
// imports SwiftUI (which Models/ cannot) but it isn't a screen-scope
// view either.  The choice between ViewModels/ and Views/ for
// FileDocument types is loose; ViewModels/ is the slightly better fit
// per CONVENTIONS.md's description of that folder.

import SwiftUI
import UniformTypeIdentifiers

struct GPXEditorDocument: FileDocument {

    /// The session this document represents.  Mutating this through a
    /// SwiftUI binding (which DocumentGroup provides to ContentView)
    /// automatically marks the document dirty and triggers autosave.
    var session: GPXSession

    /// Custom UTType for the .gpxeditor format.  The string identifier
    /// must match the UTTypeIdentifier in Info.plist's
    /// UTExportedTypeDeclarations entry — they're two halves of the
    /// same registration.  If they ever diverge, FileDocument's load
    /// path silently fails to recognize files Launch Services hands off.
    static var readableContentTypes: [UTType] {
        [UTType(exportedAs: "com.gpxeditor.project")]
    }

    /// Default empty document used by File → New.  An untitled
    /// GPXSession with no tracks, default basemap selection ("osm"),
    /// no viewport, and current timestamps for created/modified.
    init() {
        self.session = GPXSession()
    }

    /// FileDocument's read entry point.  Routed through ProjectFile.read
    /// (which understands the JSON envelope including formatVersion
    /// rejection).  ProjectFileError is bridged into the throws contract
    /// — SwiftUI displays the error via its standard alert path.
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            // FileWrapper had no data — file is missing or unreadable.
            // Use Cocoa's standard error code for "file is corrupt"
            // because there's no other reasonable fallback at this layer.
            throw CocoaError(.fileReadCorruptFile)
        }
        switch ProjectFile.read(data) {
        case .success(let session):
            self.session = session
        case .failure(let error):
            throw error
        }
    }

    /// FileDocument's write entry point.  Routed through ProjectFile.write,
    /// which produces pretty-printed sorted-keys JSON suitable for the
    /// `.gpxeditor` extension.  Returns a regular-file FileWrapper —
    /// the project format is single-file (D-010), not a package bundle.
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let data = try ProjectFile.write(session)
        return FileWrapper(regularFileWithContents: data)
    }
}
