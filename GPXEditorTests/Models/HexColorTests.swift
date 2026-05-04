// HexColorTests.swift
//
// Coverage for the HexColor wrapper:  format validation, case
// normalization, and the Codable single-value-container behavior that
// the project-file codec relies on.

import Testing
import Foundation
@testable import GPXEditor

@Suite("HexColor")
struct HexColorTests {

    // MARK: - Validation

    @Test("Accepts 6-digit hex form (RRGGBB)")
    func acceptsSixDigitForm() {
        #expect(HexColor("#1A2B3C") != nil)
        #expect(HexColor("#000000") != nil)
        #expect(HexColor("#FFFFFF") != nil)
    }

    @Test("Accepts 8-digit hex form (RRGGBBAA)")
    func acceptsEightDigitForm() {
        #expect(HexColor("#1A2B3C4D") != nil)
        #expect(HexColor("#00000000") != nil)
        #expect(HexColor("#FFFFFFFF") != nil)
    }

    @Test("Rejects strings without leading hash")
    func rejectsMissingHash() {
        #expect(HexColor("1A2B3C") == nil)
        #expect(HexColor("FFFFFF") == nil)
    }

    @Test("Rejects wrong-length strings")
    func rejectsWrongLength() {
        #expect(HexColor("#1") == nil)
        #expect(HexColor("#12345") == nil)        // 5 digits
        #expect(HexColor("#1234567") == nil)      // 7 digits
        #expect(HexColor("#123456789") == nil)    // 9 digits
        #expect(HexColor("") == nil)
        #expect(HexColor("#") == nil)
    }

    @Test("Rejects non-hex characters")
    func rejectsNonHexCharacters() {
        #expect(HexColor("#GGHHII") == nil)
        #expect(HexColor("#12345Z") == nil)
        #expect(HexColor("#1A 2B3C") == nil)      // embedded space
    }

    // MARK: - Case normalization

    @Test("Normalizes lowercase input to uppercase canonical form")
    func normalizesToUppercase() {
        // Two HexColors built from differently-cased equivalent strings
        // should compare equal and serialize identically — that's what
        // makes git diffs of the project file stable across machines.
        let lower = HexColor("#aabbcc")
        let upper = HexColor("#AABBCC")
        let mixed = HexColor("#AaBbCc")
        #expect(lower == upper)
        #expect(mixed == upper)
        #expect(lower?.value == "#AABBCC")
    }

    // MARK: - Codable

    @Test("Encodes as a JSON string in single-value form")
    func encodesAsJSONString() throws {
        let color = HexColor("#1A2B3C")!
        let data = try JSONEncoder().encode(color)
        let json = String(data: data, encoding: .utf8)
        // JSONEncoder of a single-value container yields a bare quoted
        // string, not an object — the project file format depends on
        // this so colors read naturally in a hand-edited JSON file.
        #expect(json == "\"#1A2B3C\"")
    }

    @Test("Decodes a valid hex color from a JSON string")
    func decodesValidString() throws {
        let json = "\"#FF8800\"".data(using: .utf8)!
        let color = try JSONDecoder().decode(HexColor.self, from: json)
        #expect(color.value == "#FF8800")
    }

    @Test("Decoding throws on a malformed hex string")
    func decodingThrowsOnInvalid() {
        // Per CONVENTIONS.md "Nothing fails silently": a malformed value
        // in the project file must surface as a decoding error rather
        // than become a sentinel.  This is what protects a hand-edited
        // .gpxeditor file from going subtly wrong.
        let json = "\"not-a-color\"".data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(HexColor.self, from: json)
        }
    }
}
