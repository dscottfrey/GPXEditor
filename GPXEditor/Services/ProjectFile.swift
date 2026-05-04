// ProjectFile.swift
//
// JSON codec for the `.gpxeditor` project file format (D-010).  Wraps a
// `GPXSession` with a top-level `formatVersion` field, encodes to pretty-
// printed sorted-keys JSON for human-readability and git-diff stability,
// and decodes back with explicit checking against newer-format files.
//
// Design choices:
//
// - Single-file JSON, no external references.  D-008's non-destructive
//   document model embeds each Track's original GPX bytes inline (as
//   base64 inside a JSON string when round-tripped through Codable's
//   default Data encoding); the project is fully self-contained.
//
// - `formatVersion` is an Int, monotonically increasing.  Per Q4 from
//   the M1 design pass:  simpler than semver for the "clean rejection
//   on encountering newer formats" semantics.  The value 1 is assigned
//   to the initial format; any future schema-breaking change bumps it.
//
// - Pretty-printed + sorted-keys output matches D-010's "human-readable
//   for debugging, line-diffable for git review" requirement.  The
//   trade-off (slightly larger files due to whitespace) is acceptable
//   at the realistic scale of a few tracks per project (D-010
//   "Consequences").
//
// - Date fields are encoded as ISO 8601 strings.  Project metadata
//   timestamps (createdAt, modifiedAt) are second-precision in
//   practice; per-point timestamps inside Tracks are sub-second-capable
//   in the data model but encoded as second-precision here too (the
//   .iso8601 strategy without .withFractionalSeconds).  If
//   sub-second precision in saved projects ever matters, switch to
//   .withFractionalSeconds — but no current feature consumes that
//   precision (Stats panel works at the second level).
//
// - Newer-format rejection happens BEFORE the body decodes, by reading
//   `formatVersion` from a "header" pre-parse.  This produces a clean
//   `.unsupportedFormatVersion(N)` error rather than a confusing
//   .decodingFailed for what may be many missing-field complaints.

import Foundation

/// The on-disk envelope for a `.gpxeditor` project file.  Exposes a
/// minimal API:  `write(_:)` to encode a session, `read(_:)` to decode
/// one (or surface a structured error).
public enum ProjectFile {

    /// The `formatVersion` value this build of the app writes when it
    /// saves a project.  Bumped only when the on-disk schema changes
    /// in a way that older apps cannot read.
    public static let currentFormatVersion: Int = 1

    /// Encode a `GPXSession` to pretty-printed JSON.  The result is
    /// suitable for writing to a `.gpxeditor` file.
    public static func write(_ session: GPXSession) throws -> Data {
        let envelope = Envelope(
            formatVersion: currentFormatVersion,
            session: session
        )
        return try writeEncoder.encode(envelope)
    }

    /// Decode a `.gpxeditor` file's bytes into a `GPXSession`.  Returns
    /// `.failure(.unsupportedFormatVersion(N))` if the file declares a
    /// formatVersion higher than this build supports, or
    /// `.failure(.decodingFailed(...))` for any other JSON-shape problem.
    public static func read(_ data: Data) -> Result<GPXSession, ProjectFileError> {
        // Pre-parse just the formatVersion field so a newer-format
        // rejection produces a clean, specific error rather than the
        // possibly-confusing "JSON didn't match shape" cascade that
        // would result from running the full decoder on a newer-format
        // body that doesn't match our expectations.
        do {
            let header = try readDecoder.decode(VersionHeader.self, from: data)
            if header.formatVersion > currentFormatVersion {
                return .failure(.unsupportedFormatVersion(header.formatVersion))
            }
        } catch {
            // Couldn't even read the header — propagate as a generic
            // decoding failure with the underlying message.
            return .failure(.decodingFailed(message: "\(error)"))
        }

        do {
            let envelope = try readDecoder.decode(Envelope.self, from: data)
            return .success(envelope.session)
        } catch {
            return .failure(.decodingFailed(message: "\(error)"))
        }
    }

    // MARK: - Internal envelope

    /// The on-disk shape:  a thin wrapper carrying the schema version
    /// alongside the session payload.  Kept private — callers see only
    /// `GPXSession` going in and `GPXSession` coming out; the
    /// formatVersion is an internal codec concern.
    private struct Envelope: Codable {
        let formatVersion: Int
        let session: GPXSession
    }

    /// Lightweight pre-parse type for reading just the formatVersion
    /// field.  Used to reject newer-format files cleanly before
    /// attempting a full decode that might fail for a flood of less-
    /// specific reasons.
    private struct VersionHeader: Decodable {
        let formatVersion: Int
    }

    // MARK: - Encoder / decoder configuration

    /// Encoder used by `write(_:)`.  Pretty-printed and sorted-keys
    /// for human-readable, git-diff-stable output.  ISO 8601 dates
    /// for the same reason — a date in a hand-edited JSON file should
    /// read as a date, not as an opaque double.
    private static let writeEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    /// Decoder used by `read(_:)`.  Mirrors the encoder's date strategy
    /// so dates round-trip correctly.
    private static let readDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
