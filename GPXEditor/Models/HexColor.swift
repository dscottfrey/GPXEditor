// HexColor.swift
//
// A typed wrapper around an HTML/CSS-style hex color string ("#RRGGBB" or
// "#RRGGBBAA").  The data model stores color as text rather than as a Cocoa
// or SwiftUI color value because Models/ is platform-agnostic per
// CONVENTIONS.md ("The data and operations layers are platform-agnostic")
// — neither AppKit's NSColor nor SwiftUI's Color may be imported here, so a
// hex string is the only stable on-disk representation that round-trips
// through JSON, survives palette edits in Settings (D-013), and can later
// be mapped to whatever color type the consuming layer needs (NSColor on
// macOS, UIColor on a hypothetical iOS port, a CSS string in JavaScript).
//
// Validation is enforced at construction time so a bad string can never
// silently make it into the model.  Decoding from JSON likewise fails loud
// if the stored value isn't a well-formed hex color, surfacing the failure
// per CONVENTIONS.md "Nothing fails silently."
//
// See D-013 for the per-segment color decision and the "color is never the
// only signal" accessibility rule that motivates storing color as plain
// text rather than tying it to a hardware-display color space.

import Foundation

/// A validated hex-string color in the form `#RRGGBB` (six hex digits) or
/// `#RRGGBBAA` (eight hex digits including alpha).  Equatable, Hashable, and
/// Codable so it composes naturally into the rest of the data model.
public struct HexColor: Equatable, Hashable, Codable, Sendable {

    /// The canonical string form: a leading `#` followed by six or eight
    /// hex digits.  Stored uppercase so equality and hashing are case-stable
    /// across files written on different machines.
    public let value: String

    /// Construct a `HexColor` from a string.  Accepts either the `#RRGGBB`
    /// or `#RRGGBBAA` form.  Returns `nil` if the string isn't a valid hex
    /// color — callers handle the nil rather than getting a silently-bad
    /// value.
    public init?(_ raw: String) {
        guard Self.isValid(raw) else { return nil }
        // Uppercase normalization: "#aabbcc" and "#AABBCC" should compare
        // equal and hash the same so segment colors stay stable across
        // round-trips through different editors or shells.
        self.value = raw.uppercased()
    }

    /// Codable: decode as a String, validating the same way `init(_:)`
    /// does.  An invalid stored color throws a decoding error rather than
    /// silently producing a sentinel value — the project file is meant to
    /// be human-edited too (per D-010), and a malformed hand-edit should
    /// surface visibly.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let parsed = HexColor(raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Not a valid hex color: \(raw)"
            )
        }
        self = parsed
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }

    /// Returns `true` iff `s` is a valid hex color string in one of the two
    /// accepted forms.  Pulled out so tests can exercise validation without
    /// going through the optional initializer.
    public static func isValid(_ s: String) -> Bool {
        // Must start with '#' and be exactly 7 or 9 chars total.
        guard s.first == "#" else { return false }
        guard s.count == 7 || s.count == 9 else { return false }
        // Remaining chars must all be ASCII hex digits.
        let hex = s.dropFirst()
        return hex.allSatisfy { $0.isHexDigit }
    }
}
