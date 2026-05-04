// GPXParseError.swift
//
// Structured failure cases for `GPXParser`.  Each case captures enough
// context for a useful error message while keeping the type Equatable so
// tests can assert specific failures via straightforward `==` comparisons.
//
// XMLParser-level errors (malformed XML, mismatched tags, encoding errors)
// are wrapped into `.invalidXML(message:)` with the line and column number
// folded into the message string.  We deliberately don't expose line/column
// as separate associated values because tests would have to predict exact
// positions, and small whitespace adjustments to fixtures would cascade
// into failing assertions.  The message is for humans reading errors;
// tests check the *kind* of failure via case matching.

import Foundation

/// All the ways `GPXParser.parse(_:)` can fail.  Equatable so tests can
/// assert specific failure cases; the underlying types of associated values
/// are simple (String, optionals) for the same reason.
///
/// Conforms to `LocalizedError` so the standard NSAlert / SwiftUI .alert
/// path picks up human-readable per-case messages instead of Swift's
/// raw enum-reflection output.  Per CONVENTIONS.md "Error messages
/// describe, don't accuse," each message names what the parser tried
/// to do and what it observed, without making claims about what the
/// user's file "is" or "isn't" — those are the user's call to make.
public enum GPXParseError: Error, Equatable, Sendable {

    /// XMLParser reported a syntactic error or the document was otherwise
    /// not well-formed.  `message` is a human-readable summary including
    /// the parser's reported line/column when available.
    case invalidXML(message: String)

    /// The `<gpx version="...">` attribute was present but did not name a
    /// version we support (we accept "1.0" and "1.1").  The string is the
    /// offending value.
    case unsupportedVersion(String)

    /// A `lat`, `lon`, or `<ele>` value couldn't be parsed as a Double.
    /// `element` is the parent element name ("trkpt", "wpt", etc.);
    /// `attribute` is the field name ("lat", "lon", "ele"); `value` is the
    /// raw string we received (or nil if the attribute was missing entirely
    /// — though "missing" is reported separately as
    /// `.missingRequiredAttribute`).
    case malformedCoordinate(element: String, attribute: String, value: String?)

    /// A required attribute was absent.  Most commonly: a `<trkpt>` or
    /// `<wpt>` without `lat` or `lon`.  `attribute` may be the literal
    /// attribute name, or a phrase like "lat or lon" when both are
    /// missing — the parser is permissive about which it reports first.
    case missingRequiredAttribute(element: String, attribute: String)

    /// The XML root element wasn't `<gpx>`.  GPX is the only document
    /// type we accept; HTML, plain XML, or another format produces this
    /// error rather than a confusing parse-of-irrelevant-content output.
    case unexpectedRootElement(found: String)

    /// A `<time>` child element's text couldn't be parsed as ISO 8601.
    /// `value` is the offending string.
    case malformedTimestamp(value: String)
}

// MARK: - LocalizedError

extension GPXParseError: LocalizedError {

    /// Human-readable description surfaced to the user via NSAlert or
    /// SwiftUI's standard error-presentation paths.  Phrasing follows
    /// the "describe, don't accuse" rule from CONVENTIONS.md:  each
    /// message names the parser's operation, what it expected, and
    /// what it observed — without claiming what the user's file "is."
    public var errorDescription: String? {
        switch self {
        case .invalidXML(let message):
            return "Couldn't read the file's XML. \(message)"

        case .unsupportedVersion(let version):
            return "This file declares GPX version '\(version)'. GPXeditor reads versions 1.0 and 1.1."

        case .malformedCoordinate(let element, let attribute, let value):
            let observed = value.map { "'\($0)'" } ?? "(empty)"
            return "Couldn't read the '\(attribute)' value \(observed) in a <\(element)> as a number."

        case .missingRequiredAttribute(let element, let attribute):
            return "A <\(element)> element doesn't have a '\(attribute)' attribute. GPX requires it."

        case .unexpectedRootElement(let found):
            return "Expected a <gpx> root element, found <\(found)> instead. The file may be malformed, or another XML format may have been saved with a .gpx extension."

        case .malformedTimestamp(let value):
            return "Couldn't read the timestamp '\(value)'. GPX expects ISO 8601 format like 2026-01-01T12:00:00Z."
        }
    }
}
