// GPXParserTests.swift
//
// End-to-end tests for `GPXParser` against synthetic fixtures in
// `GPXEditorTests/Fixtures/`.  Each test loads a fixture file from the test
// bundle and asserts the parser's output matches the fixture's content
// exactly.
//
// Loading mechanism:  the test bundle's resources are reached via
// `Bundle(for: AnyClass)`.  Because Swift Testing tests are written as
// free functions on suite structs (not classes), there is no `self` whose
// class to use — so we anchor on a private placeholder class declared at
// file scope.  `Bundle(for: TestBundleAnchor.self)` resolves to the
// `GPXEditorTests.xctest` bundle at runtime.
//
// Fixture inclusion:  Xcode 16's `PBXFileSystemSynchronizedRootGroup` auto-
// includes any non-Swift file in `GPXEditorTests/Fixtures/` as a Copy
// Bundle Resources entry on the test target, so `.gpx` files added to the
// folder are reachable via `Bundle(for:).url(forResource:withExtension:)`
// without manual project membership steps.

import Testing
import Foundation
@testable import GPXEditor

/// Anchor class used solely to give `Bundle(for:)` a class reference for
/// looking up the test bundle's resources.  Has no purpose beyond that.
private final class TestBundleAnchor {}

@Suite("GPXParser")
struct GPXParserTests {

    // MARK: - Fixture loading

    /// Errors thrown by `loadFixture(_:)`.  Distinct from `GPXParseError`
    /// so a missing fixture file fails the test with a clear "fixture not
    /// in test bundle" message rather than getting confused with parse
    /// failures.
    private enum FixtureError: Error {
        case notFound(String)
    }

    /// Load the contents of a fixture `.gpx` file from the test bundle.
    /// Pass the bare file name without extension (e.g. `"synth-minimal-1.1"`).
    private func loadFixture(_ name: String) throws -> Data {
        let bundle = Bundle(for: TestBundleAnchor.self)
        guard let url = bundle.url(forResource: name, withExtension: "gpx") else {
            throw FixtureError.notFound(name)
        }
        return try Data(contentsOf: url)
    }

    /// Convenience: parse a fixture by name and unwrap the success case.
    /// Test failures from `try result.get()` surface as Swift-Testing
    /// failures with the underlying `GPXParseError` description, which
    /// is what we want when a fixture we *expected* to parse fails.
    private func parseFixture(_ name: String) throws -> RawGPX {
        let data = try loadFixture(name)
        return try GPXParser.parse(data).get()
    }

    /// ISO 8601 date helper.  Tests assert equality against specific
    /// timestamps from fixtures; most fixtures use the plain-second form,
    /// but the fractional-time fixture needs the alternative formatter.
    /// We try plain first then fall back, matching the parser's own
    /// two-formatter logic.
    private func iso8601(_ s: String) -> Date? {
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let d = plain.date(from: s) { return d }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: s)
    }

    // MARK: - Tests

    @Test("Parses minimal GPX 1.1 with one track, one segment, three points")
    func parsesMinimalGPX11() throws {
        let gpx = try parseFixture("synth-minimal-1.1")

        // File-level fields.
        #expect(gpx.version == "1.1")
        #expect(gpx.creator == "GPXeditor synthetic fixture")
        #expect(gpx.metadataName == "Minimal 1.1 fixture")
        #expect(gpx.metadataTime == iso8601("2026-01-01T00:00:00Z"))
        #expect(gpx.waypoints.isEmpty)
        #expect(gpx.tracks.count == 1)

        // Track-level fields.
        let track = gpx.tracks[0]
        #expect(track.name == "Synthetic Null Island stroll")
        #expect(track.segments.count == 1)

        // Segment-level fields.
        let segment = track.segments[0]
        #expect(segment.points.count == 3)

        // Point-level fields.  Asserted exhaustively against the fixture
        // to catch any field-routing regression (e.g. a future bug where
        // <time> gets attached to the wrong point).
        #expect(segment.points[0].latitude == 0.0001)
        #expect(segment.points[0].longitude == 0.0001)
        #expect(segment.points[0].elevation == 10.0)
        #expect(segment.points[0].time == iso8601("2026-01-01T00:00:00Z"))

        #expect(segment.points[1].latitude == 0.0002)
        #expect(segment.points[1].longitude == 0.0002)
        #expect(segment.points[1].elevation == 11.0)
        #expect(segment.points[1].time == iso8601("2026-01-01T00:00:10Z"))

        #expect(segment.points[2].latitude == 0.0003)
        #expect(segment.points[2].longitude == 0.0003)
        #expect(segment.points[2].elevation == 12.0)
        #expect(segment.points[2].time == iso8601("2026-01-01T00:00:20Z"))
    }

    @Test("Parses minimal GPX 1.0 (metadata as direct children of <gpx>)")
    func parsesMinimalGPX10() throws {
        // GPX 1.0 differs from 1.1 only in metadata placement: <name> and
        // <time> are direct children of <gpx> rather than wrapped in a
        // <metadata> element.  The parser accepts both so legacy 1.0
        // files load without their file-level metadata being silently
        // dropped — see GPXParser.swift's <name>/<time> switch arms.
        let gpx = try parseFixture("synth-minimal-1.0")

        // Version field reflects the source (1.0 vs 1.1).  Track-construction
        // code never branches on this — it's surfaced for diagnostic and
        // export purposes.
        #expect(gpx.version == "1.0")
        #expect(gpx.creator == "GPXeditor synthetic fixture")

        // Metadata fields populated from <gpx><name> and <gpx><time>
        // (the 1.0 placement), not from <gpx><metadata>.
        #expect(gpx.metadataName == "Minimal 1.0 fixture")
        #expect(gpx.metadataTime == iso8601("2026-01-01T00:00:00Z"))

        // Track data parses identically to the 1.1 case — same <trk> /
        // <trkseg> / <trkpt> structure across both versions.
        #expect(gpx.tracks.count == 1)
        let track = gpx.tracks[0]
        #expect(track.name == "Synthetic Null Island stroll (1.0)")
        #expect(track.segments.count == 1)
        #expect(track.segments[0].points.count == 2)
        #expect(track.segments[0].points[0].latitude == 0.0001)
        #expect(track.segments[0].points[1].latitude == 0.0002)
    }

    @Test("Preserves multiple <trkseg> elements as distinct segments")
    func parsesMultiSegmentTrack() throws {
        // D-012 requires segment structure to round-trip from source to
        // export.  This test confirms the parser distinguishes two-segment
        // input from one-segment input — a bug that silently merged
        // segments would break the writer's contract and the D-016
        // self-overlap use case.
        let gpx = try parseFixture("synth-multi-trkseg")

        #expect(gpx.tracks.count == 1)
        let track = gpx.tracks[0]
        #expect(track.name == "Track with two segments")
        #expect(track.segments.count == 2)

        // First segment.
        let seg1 = track.segments[0]
        #expect(seg1.points.count == 2)
        #expect(seg1.points[0].latitude == 0.0001)
        #expect(seg1.points[0].elevation == 10.0)
        #expect(seg1.points[1].latitude == 0.0002)
        #expect(seg1.points[1].elevation == 11.0)

        // Second segment, deliberately starting at a different coordinate
        // range so a "merged into one segment" bug would produce a
        // visibly wrong polyline rather than an undetectable mistake.
        let seg2 = track.segments[1]
        #expect(seg2.points.count == 3)
        #expect(seg2.points[0].latitude == 0.0010)
        #expect(seg2.points[0].elevation == 20.0)
        #expect(seg2.points[2].latitude == 0.0012)
        #expect(seg2.points[2].elevation == 22.0)

        // Per-point timestamps deliberately absent from this fixture —
        // confirm they decoded as nil.
        #expect(seg1.points[0].time == nil)
        #expect(seg2.points[0].time == nil)
    }

    @Test("Handles points with missing <ele> as nil, not as a sentinel")
    func parsesPointsWithMissingElevation() throws {
        // GPX makes <ele> optional, and the data model represents missing
        // elevation as Double?.nil — never as 0.0, NaN, or a carry-forward
        // from the previous point.  This fixture's mixed presence
        // (alternating ele-present / ele-absent) discriminates against
        // both classes of bug.
        let gpx = try parseFixture("synth-no-elevation")

        let points = gpx.tracks[0].segments[0].points
        #expect(points.count == 4)

        #expect(points[0].elevation == 10.0)
        #expect(points[1].elevation == nil)   // self-closing <trkpt/> — no <ele>
        #expect(points[2].elevation == 12.0)
        #expect(points[3].elevation == nil)   // self-closing <trkpt/> — no <ele>

        // lat/lon should be intact on every point regardless of elevation.
        #expect(points[1].latitude == 0.0002)
        #expect(points[3].longitude == 0.0004)
    }

    @Test("Preserves empty and single-point segments without dropping them")
    func parsesDegenerateSegmentCounts() throws {
        // GPX permits segments with zero or one <trkpt>.  Both shapes
        // occur in real recordings (signal-loss splits, immediate pauses,
        // post-cleanup trims).  The parser must preserve them as structural
        // entities — a renderer can choose not to draw a zero-edge
        // polyline, but the data-model invariant is that the track has
        // exactly the segments the source declared.
        let gpx = try parseFixture("synth-degenerate-counts")

        #expect(gpx.tracks.count == 1)
        let track = gpx.tracks[0]
        #expect(track.segments.count == 2)

        // First segment is empty.  Preserved with zero points, NOT
        // silently dropped.
        #expect(track.segments[0].points.isEmpty)

        // Second segment has one point.
        #expect(track.segments[1].points.count == 1)
        #expect(track.segments[1].points[0].latitude == 0.0001)
        #expect(track.segments[1].points[0].longitude == 0.0001)
        #expect(track.segments[1].points[0].elevation == 10.0)
    }

    @Test("Parses file-level waypoints alongside a track without cross-contamination")
    func parsesWaypoints() throws {
        // GPX places <wpt> at the document level (peer to <trk>).  This
        // fixture has both kinds of <name> in the same file — track name
        // and waypoint names — so a parent-context routing bug would
        // produce a clearly wrong result (e.g., the track's name ending
        // up on a waypoint or vice versa).
        let gpx = try parseFixture("synth-with-waypoints")

        #expect(gpx.waypoints.count == 3)

        // Fully-populated waypoint.
        let wpt0 = gpx.waypoints[0]
        #expect(wpt0.latitude == 0.0001)
        #expect(wpt0.longitude == 0.0001)
        #expect(wpt0.elevation == 10.0)
        #expect(wpt0.name == "Trailhead")
        #expect(wpt0.sym == "Trailhead")
        #expect(wpt0.description == "Synthetic start point")

        // Partial waypoint — name and sym only, optional fields nil.
        let wpt1 = gpx.waypoints[1]
        #expect(wpt1.latitude == 0.0005)
        #expect(wpt1.elevation == nil)
        #expect(wpt1.name == "Summit")
        #expect(wpt1.sym == "Summit")
        #expect(wpt1.description == nil)

        // Bare-minimum self-closing waypoint — only lat/lon.
        let wpt2 = gpx.waypoints[2]
        #expect(wpt2.latitude == 0.0010)
        #expect(wpt2.longitude == 0.0010)
        #expect(wpt2.elevation == nil)
        #expect(wpt2.name == nil)
        #expect(wpt2.sym == nil)
        #expect(wpt2.description == nil)

        // Track is present and intact, with its own name not picked up
        // from any waypoint.
        #expect(gpx.tracks.count == 1)
        #expect(gpx.tracks[0].name == "Track alongside waypoints")
        #expect(gpx.tracks[0].segments[0].points.count == 2)
    }

    @Test("Parses standard fields cleanly and silently ignores vendor extensions")
    func parsesAndIgnoresExtensions() throws {
        // Per D-008 / Q2, vendor extensions live only in immutableOriginalBytes;
        // the working-state model never sees them.  This fixture has both
        // gpxtpx:TrackPointExtension (per-point heart rate, cadence,
        // temperature) and gpxx:TrackExtension (track-level display color)
        // — both must be silently dropped by the parser.
        //
        // The parent-context routing in didEndElement protects standard
        // fields from collision with extension fields — gpxtpx:hr's parent
        // isn't "trkpt" or "wpt" or "metadata", so the value is dropped
        // even though we never explicitly check for "gpxtpx:hr" anywhere.
        let gpx = try parseFixture("synth-with-extensions")

        #expect(gpx.tracks.count == 1)
        let track = gpx.tracks[0]
        #expect(track.name == "Track with Garmin extensions")
        #expect(track.segments.count == 1)
        let points = track.segments[0].points
        #expect(points.count == 2)

        // Standard fields parsed correctly despite the extensions
        // siblings inside <trkpt>.  A bug in parent-context routing
        // could have allowed an extension's inner <time> or numeric
        // value to overwrite these.
        #expect(points[0].latitude == 0.0001)
        #expect(points[0].elevation == 10.0)
        #expect(points[0].time == iso8601("2026-01-01T00:00:00Z"))
        #expect(points[1].latitude == 0.0002)
        #expect(points[1].elevation == 11.0)
        #expect(points[1].time == iso8601("2026-01-01T00:00:10Z"))
    }

    @Test("Parses ISO 8601 timestamps with fractional seconds")
    func parsesFractionalSecondTimestamps() throws {
        // The parser keeps two ISO8601DateFormatter instances — one for
        // whole-second timestamps (the common case) and one with
        // .withFractionalSeconds for sub-second precision.  Strava,
        // Garmin watches, and some fitness apps emit the fractional
        // form; the parser tries plain first and falls back to
        // fractional in parseDate(_:).
        let gpx = try parseFixture("synth-fractional-time")

        // Metadata time uses fractional form too.
        #expect(gpx.metadataTime == iso8601("2026-01-01T00:00:00.000Z"))

        let points = gpx.tracks[0].segments[0].points
        #expect(points.count == 3)
        #expect(points[0].time == iso8601("2026-01-01T00:00:00.000Z"))
        #expect(points[1].time == iso8601("2026-01-01T00:00:00.500Z"))
        #expect(points[2].time == iso8601("2026-01-01T00:00:01.250Z"))
    }

    // MARK: - Failure cases
    //
    // Each fixture below triggers exactly one error from GPXParseError.
    // Tests assert via case matching rather than `==` for .invalidXML
    // because the message string varies by XMLParser version.

    @Test("Fails with .invalidXML on malformed XML")
    func failsOnMalformedXML() throws {
        let data = try loadFixture("synth-bad-xml")
        let result = GPXParser.parse(data)
        switch result {
        case .failure(.invalidXML):
            break  // expected
        default:
            Issue.record("Expected .invalidXML, got \(result)")
        }
    }

    @Test("Fails with .unexpectedRootElement when root isn't <gpx>")
    func failsOnWrongRoot() throws {
        let data = try loadFixture("synth-wrong-root")
        let result = GPXParser.parse(data)
        #expect(result == .failure(.unexpectedRootElement(found: "svg")))
    }

    @Test("Fails with .unsupportedVersion on a non-1.0/1.1 version attribute")
    func failsOnUnsupportedVersion() throws {
        let data = try loadFixture("synth-bad-version")
        let result = GPXParser.parse(data)
        #expect(result == .failure(.unsupportedVersion("0.5")))
    }

    @Test("Fails with .malformedCoordinate when lat/lon isn't a number")
    func failsOnMalformedCoordinate() throws {
        let data = try loadFixture("synth-bad-coordinate")
        let result = GPXParser.parse(data)
        #expect(result == .failure(.malformedCoordinate(
            element: "trkpt",
            attribute: "lat",
            value: "not-a-number"
        )))
    }

    @Test("Fails with .missingRequiredAttribute when lat is absent")
    func failsOnMissingLat() throws {
        let data = try loadFixture("synth-missing-lat")
        let result = GPXParser.parse(data)
        #expect(result == .failure(.missingRequiredAttribute(
            element: "trkpt",
            attribute: "lat"
        )))
    }

    @Test("Fails with .malformedTimestamp on an unparseable <time>")
    func failsOnMalformedTimestamp() throws {
        let data = try loadFixture("synth-bad-timestamp")
        let result = GPXParser.parse(data)
        #expect(result == .failure(.malformedTimestamp(value: "not a real timestamp")))
    }
}
