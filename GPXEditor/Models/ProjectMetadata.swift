// ProjectMetadata.swift
//
// Project-level metadata for a `.gpxeditor` session: the user-visible
// project name plus a pair of timestamps the file format carries for
// debuggability and for any future "recently opened" UI that wants to
// sort by modification time.
//
// Deliberately small.  The GPX file format has its own metadata (file-
// level `<metadata>` element with name, desc, author, link, time,
// keywords, bounds) — that lives on Track via `Track.recordedDate` and
// the immutable original bytes.  ProjectMetadata is about the *project*,
// not the source GPX inside it.
//
// See D-010 for the project file format.  These fields are stored in the
// `.gpxeditor` JSON document and are part of the format's stable shape;
// adding fields here means bumping the project file format version
// in `Services/ProjectFile.swift` (M1).

import Foundation

/// User-visible project metadata.  Distinct from any per-Track metadata
/// (which mirrors the source GPX file's `<metadata>` element).
public struct ProjectMetadata: Equatable, Codable, Sendable {

    /// User-visible project name, shown in the document title bar.
    /// Defaults to "Untitled" for a freshly created project; the user
    /// can rename via Save As.
    public var name: String

    /// When the project was first created (the moment the user picked
    /// File → New).  Never updated after construction.
    public let createdAt: Date

    /// When the project was last saved.  Updated on every successful
    /// write through the FileDocument codec.
    public var modifiedAt: Date

    public init(
        name: String = "Untitled",
        createdAt: Date = Date(),
        modifiedAt: Date = Date()
    ) {
        self.name = name
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }
}
