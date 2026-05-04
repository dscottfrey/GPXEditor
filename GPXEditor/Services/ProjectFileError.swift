// ProjectFileError.swift
//
// Structured failure cases for `ProjectFile.read(_:)`.  The codec wraps
// JSONDecoder failures into more specific cases when it can recognize
// the underlying problem (newer-format rejection in particular has its
// own case so the UI can present a clearer message than "decoding
// failed").

import Foundation

/// All the ways `ProjectFile.read(_:)` can fail.
public enum ProjectFileError: Error, Equatable, Sendable {

    /// The on-disk JSON declared a `formatVersion` higher than this
    /// build of the app supports.  The associated value is the version
    /// number the file claimed.  Per D-010, the codec rejects newer
    /// formats cleanly rather than attempting partial loads — better to
    /// surface a "this project was saved with a newer version" message
    /// than to silently drop fields that the older app doesn't know
    /// how to read.
    case unsupportedFormatVersion(Int)

    /// JSONDecoder raised a decoding error.  The associated string is a
    /// human-readable description suitable for surfacing in an alert;
    /// the original DecodingError detail is folded in at the call site.
    /// This wraps the wide variety of "the JSON shape doesn't match
    /// what we expect" failures (missing required field, type mismatch,
    /// invalid base64 in immutableOriginalBytes, etc.) so callers don't
    /// have to handle DecodingError's many cases.
    case decodingFailed(message: String)
}
