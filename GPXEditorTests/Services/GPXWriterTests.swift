// GPXWriterTests.swift
//
// Round-trip tests for `GPXWriter` against the same synthetic fixtures
// used by `GPXParserTests`.  Each test parses a fixture, writes it back
// out, parses the writer's output, and asserts the re-parsed RawGPX
// matches the original — confirming the writer faithfully preserves
// every field the parser produced.
//
// Round-trip lossiness is deliberately documented:
//
// - The `version` field always becomes "1.1" in the writer's output
//   regardless of the source version, per D-012.  Tests normalize the
//   original RawGPX's version to "1.1" before comparison.
//
// - Vendor extensions are dropped on parse; the writer doesn't emit
//   them; the re-parser sees none.  Round-trip equality holds because
//   both the parsed and re-parsed RawGPX have no extension data.
//
// - Sub-second timestamp precision is preserved because formatDate(_:)
//   in GPXWriter detects the fractional component and uses
//   .withFractionalSeconds when needed.

import Testing
import Foundation
@testable import GPXEditor

/// Anchor class used solely to give `Bundle(for:)` a class reference for
/// looking up the test bundle's resources.  Same pattern as
/// GPXParserTests; defined again here because it's file-private.
private final class TestBundleAnchor {}

@Suite("GPXWriter round-trip")
struct GPXWriterTests {

    // MARK: - Fixture helpers

    private enum FixtureError: Error {
        case notFound(String)
    }

    private func loadFixture(_ name: String) throws -> Data {
        let bundle = Bundle(for: TestBundleAnchor.self)
        guard let url = bundle.url(forResource: name, withExtension: "gpx") else {
            throw FixtureError.notFound(name)
        }
        return try Data(contentsOf: url)
    }

    // MARK: - Round-trip tests

    /// Parameterized round-trip: parse fixture, write, parse again,
    /// assert equality (modulo the writer's version normalization).
    /// One test invocation per fixture name; Swift Testing reports
    /// each one separately so a failure points at the specific input.
    @Test(
        "Round-trips happy-path fixtures through write -> parse",
        arguments: [
            "synth-minimal-1.1",
            "synth-minimal-1.0",
            "synth-multi-trkseg",
            "synth-no-elevation",
            "synth-degenerate-counts",
            "synth-with-waypoints",
            "synth-with-extensions",
            "synth-fractional-time",
        ]
    )
    func roundTrips(_ fixtureName: String) throws {
        let originalData = try loadFixture(fixtureName)
        let originalParsed = try GPXParser.parse(originalData).get()
        let written = GPXWriter.write(originalParsed)
        let reparsed = try GPXParser.parse(written).get()

        // Writer always emits version="1.1" — normalize the original
        // before comparison.  This is the only field the writer
        // intentionally changes.
        var normalized = originalParsed
        normalized.version = "1.1"

        #expect(reparsed == normalized)
    }

    // MARK: - Specific output-shape tests

    @Test("Emits XML declaration + <gpx version=\"1.1\"> root element")
    func emitsExpectedHeader() throws {
        let raw = RawGPX(version: "1.0", creator: "test", tracks: [])
        let written = GPXWriter.write(raw)
        let s = String(data: written, encoding: .utf8) ?? ""

        // The XML declaration is required for the file to be recognized
        // as XML by some strict parsers (and it's standard practice
        // even when optional).
        #expect(s.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>"))

        // Root element always declares 1.1, never the input version.
        #expect(s.contains("<gpx version=\"1.1\""))

        // Default namespace declaration matches the GPX 1.1 schema URI.
        #expect(s.contains("xmlns=\"http://www.topografix.com/GPX/1/1\""))
    }

    @Test("Falls back to default creator when input has nil creator")
    func defaultsCreatorWhenNil() throws {
        let raw = RawGPX(version: nil, creator: nil)
        let written = GPXWriter.write(raw)
        let s = String(data: written, encoding: .utf8) ?? ""

        // We use "GPXeditor" as the fallback creator — matches the
        // app's display name (D-001) and identifies the producer
        // unambiguously to anyone inspecting the resulting file.
        #expect(s.contains("creator=\"GPXeditor\""))
    }

    @Test("Empty <trkseg> emits as self-closing tag, not <trkseg></trkseg>")
    func emitsEmptySegmentSelfClosing() throws {
        let raw = RawGPX(tracks: [
            RawTrack(name: "test", segments: [RawSegment(points: [])]),
        ])
        let written = GPXWriter.write(raw)
        let s = String(data: written, encoding: .utf8) ?? ""

        #expect(s.contains("<trkseg/>"))
        #expect(!s.contains("<trkseg>\n    </trkseg>"))
    }

    @Test("Whole-second timestamps emit without fractional seconds")
    func wholeSecondTimestampsOmitFraction() throws {
        let date = ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z")!
        let raw = RawGPX(metadataTime: date)
        let written = GPXWriter.write(raw)
        let s = String(data: written, encoding: .utf8) ?? ""

        // Should not have ".000" — the fractional formatter would
        // produce that and it's noise we don't want for whole-second
        // input.
        #expect(s.contains("2026-01-01T00:00:00Z"))
        #expect(!s.contains("2026-01-01T00:00:00.000Z"))
    }

    @Test("Sub-second timestamps emit with fractional seconds preserved")
    func fractionalTimestampsKeepFraction() throws {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = f.date(from: "2026-01-01T00:00:00.500Z")!
        let raw = RawGPX(metadataTime: date)
        let written = GPXWriter.write(raw)
        let s = String(data: written, encoding: .utf8) ?? ""

        // Output must include the .500 fractional component or round-
        // trip preservation breaks for fixtures like synth-fractional-time.
        #expect(s.contains("2026-01-01T00:00:00.500Z"))
    }

    @Test("XML-special characters in text are escaped")
    func escapesXMLSpecialCharacters() throws {
        // Track name with all the standard XML-special characters:
        // & < > are required; " and ' are noise but still valid XML.
        let raw = RawGPX(tracks: [
            RawTrack(name: "Smith & Jones <\"Big Trail\">", segments: []),
        ])
        let written = GPXWriter.write(raw)
        let s = String(data: written, encoding: .utf8) ?? ""

        // & < > all escape in text content; quotes pass through (they're
        // only special inside attribute values, not text).
        #expect(s.contains("Smith &amp; Jones &lt;\"Big Trail\"&gt;"))
        #expect(!s.contains("Smith & Jones"))   // raw & must not survive
    }
}
