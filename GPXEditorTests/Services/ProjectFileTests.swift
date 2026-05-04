// ProjectFileTests.swift
//
// Codec tests for the `.gpxeditor` JSON envelope.  Covers:  round-tripping
// a populated GPXSession, round-tripping a freshly-created empty session,
// preserving the immutableOriginalBytes byte-for-byte through Codable's
// base64 encoding, and rejecting newer-format files cleanly.

import Testing
import Foundation
@testable import GPXEditor

@Suite("ProjectFile codec")
struct ProjectFileTests {

    /// Build a non-trivial session that exercises every model field —
    /// duplicated from GPXSessionCodableTests with whole-second dates so
    /// the ISO-8601 date strategy used by ProjectFile (which doesn't
    /// preserve sub-second precision) round-trips exactly.
    private func sampleSession() -> GPXSession {
        let red = HexColor("#E69F00")!
        let blue = HexColor("#56B4E9")!

        let masterTrack = Track(
            name: "Reference recording",
            immutableOriginalBytes: Data("<gpx><!-- placeholder --></gpx>".utf8),
            segments: [
                Segment(name: "Climb", color: red, points: [
                    TrackPoint(latitude: 0.0001, longitude: 0.0001, elevation: 100,
                               time: Date(timeIntervalSince1970: 1_700_000_000)),
                    TrackPoint(latitude: 0.0002, longitude: 0.0002, elevation: 101,
                               time: Date(timeIntervalSince1970: 1_700_000_010)),
                ]),
            ],
            waypoints: [
                Waypoint(latitude: 0.0001, longitude: 0.0001,
                         name: "Trailhead", sym: "Trailhead",
                         description: "Start point"),
            ],
            role: .master,
            recordedDate: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let subTrack = Track(
            name: "Second pass",
            immutableOriginalBytes: Data("<gpx></gpx>".utf8),
            segments: [
                Segment(color: blue, points: [
                    TrackPoint(latitude: 0.0001, longitude: 0.00015),
                ]),
            ],
            role: .subsidiary
        )

        return GPXSession(
            metadata: ProjectMetadata(
                name: "Round-trip fixture",
                createdAt: Date(timeIntervalSince1970: 1_699_000_000),
                modifiedAt: Date(timeIntervalSince1970: 1_700_000_500)
            ),
            tracks: [masterTrack, subTrack],
            selectedBasemapId: "opentopomap",
            viewport: ViewportState(
                centerLatitude: 0.00015,
                centerLongitude: 0.00015,
                zoom: 16.5
            )
        )
    }

    // MARK: - Round-trip

    @Test("Round-trips a populated session through write/read")
    func roundTripsPopulatedSession() throws {
        let original = sampleSession()
        let data = try ProjectFile.write(original)
        let decoded = try ProjectFile.read(data).get()
        #expect(decoded == original)
    }

    @Test("Round-trips a default-constructed empty session")
    func roundTripsEmptySession() throws {
        // ProjectMetadata's default init uses Date() which has sub-second
        // precision; ProjectFile encodes via .iso8601 (whole-second).
        // Construct explicit whole-second timestamps so this test exercises
        // pure round-trip without precision-loss noise.
        let original = GPXSession(
            metadata: ProjectMetadata(
                name: "Untitled",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                modifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        )
        let data = try ProjectFile.write(original)
        let decoded = try ProjectFile.read(data).get()
        #expect(decoded == original)
    }

    @Test("Preserves immutableOriginalBytes byte-for-byte through base64")
    func preservesOriginalBytes() throws {
        // Codable's default Data encoding is base64; verify every byte
        // value (0..<256) survives the round trip.  This is the part of
        // the schema that protects D-008's non-destructive document
        // contract — the original GPX bytes must survive Save/Reopen
        // verbatim so Reset to Original works.
        let bytes = Data((0..<256).map { UInt8($0) })
        let track = Track(
            name: "byte-preservation probe",
            immutableOriginalBytes: bytes,
            segments: []
        )
        let session = GPXSession(
            metadata: ProjectMetadata(
                name: "test",
                createdAt: Date(timeIntervalSince1970: 0),
                modifiedAt: Date(timeIntervalSince1970: 0)
            ),
            tracks: [track]
        )

        let data = try ProjectFile.write(session)
        let decoded = try ProjectFile.read(data).get()
        #expect(decoded.tracks[0].immutableOriginalBytes == bytes)
    }

    // MARK: - Output shape

    @Test("Output is pretty-printed JSON with sorted keys")
    func outputIsPrettyPrintedAndSorted() throws {
        let session = GPXSession(
            metadata: ProjectMetadata(
                name: "demo",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                modifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
            ),
            selectedBasemapId: "osm"
        )
        let data = try ProjectFile.write(session)
        let json = String(data: data, encoding: .utf8) ?? ""

        // Pretty-printed: contains newlines (compact JSON would be
        // single-line).
        #expect(json.contains("\n"))

        // The envelope's formatVersion field is present at the top
        // level — a hand-editor reading the file should see it
        // immediately, and old apps reading newer files use it for
        // version rejection.
        #expect(json.contains("\"formatVersion\""))
        #expect(json.contains("\"session\""))

        // Sorted keys means "formatVersion" appears textually BEFORE
        // "session" (f < s).  This is what makes the file's text shape
        // stable across machines / Swift versions and produces clean
        // git diffs.
        let formatVersionRange = json.range(of: "\"formatVersion\"")
        let sessionRange = json.range(of: "\"session\"")
        #expect(formatVersionRange != nil)
        #expect(sessionRange != nil)
        if let fv = formatVersionRange, let s = sessionRange {
            #expect(fv.lowerBound < s.lowerBound)
        }
    }

    // MARK: - Newer-format rejection

    @Test("Rejects files with formatVersion higher than the current schema")
    func rejectsNewerFormatVersion() throws {
        // Construct a JSON payload that claims formatVersion = 999 and
        // is otherwise empty.  The body shape doesn't matter — version
        // pre-parse should fail before the full decode runs.
        let json = """
        {
            "formatVersion": 999,
            "session": {}
        }
        """
        let data = Data(json.utf8)
        let result = ProjectFile.read(data)
        #expect(result == .failure(.unsupportedFormatVersion(999)))
    }

    @Test("Returns .decodingFailed for malformed JSON")
    func returnsDecodingFailedForMalformedJSON() throws {
        let data = Data("this is not JSON".utf8)
        let result = ProjectFile.read(data)
        switch result {
        case .failure(.decodingFailed):
            break  // expected
        default:
            Issue.record("Expected .decodingFailed, got \(result)")
        }
    }

    @Test("Returns .decodingFailed when required fields are missing")
    func returnsDecodingFailedForIncompleteJSON() throws {
        // Valid JSON but doesn't have the envelope shape — formatVersion
        // is missing entirely.  Should fail at the version-header pre-parse
        // and surface as .decodingFailed.
        let data = Data("{\"unrelated\": true}".utf8)
        let result = ProjectFile.read(data)
        switch result {
        case .failure(.decodingFailed):
            break  // expected
        default:
            Issue.record("Expected .decodingFailed, got \(result)")
        }
    }
}
