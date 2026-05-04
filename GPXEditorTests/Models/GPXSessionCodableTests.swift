// GPXSessionCodableTests.swift
//
// End-to-end Codable round-trip for the full GPXSession tree.  The
// project file format (D-010) is JSON-encoded; this test exercises the
// model layer's encode/decode independently of the higher-level
// `Services/ProjectFile.swift` envelope, so a regression in any of the
// nine model types surfaces here rather than buried inside the codec.

import Testing
import Foundation
@testable import GPXEditor

@Suite("GPXSession Codable round-trip")
struct GPXSessionCodableTests {

    /// Build a non-trivial session that touches every model field at
    /// least once: two tracks (one master, one subsidiary), each with
    /// multiple segments and a mix of populated/optional fields, plus
    /// project metadata, a basemap selection, and a viewport.
    private func sampleSession() -> GPXSession {
        let red = HexColor("#E69F00")!     // Okabe-Ito orange
        let blue = HexColor("#56B4E9")!    // Okabe-Ito sky blue
        let green = HexColor("#009E73")!   // Okabe-Ito bluish green

        let masterPoints = [
            TrackPoint(latitude: 0.0001, longitude: 0.0001, elevation: 100, time: Date(timeIntervalSince1970: 1_700_000_000)),
            TrackPoint(latitude: 0.0002, longitude: 0.0002, elevation: 101, time: Date(timeIntervalSince1970: 1_700_000_010)),
            TrackPoint(latitude: 0.0003, longitude: 0.0003, elevation: nil, time: nil),
        ]
        let masterSeg1 = Segment(name: "Climb", color: red, points: masterPoints)
        let masterSeg2 = Segment(color: green, points: [
            TrackPoint(latitude: 0.0010, longitude: 0.0010),
        ])
        let masterTrack = Track(
            name: "Reference recording",
            immutableOriginalBytes: Data("<gpx><!-- placeholder --></gpx>".utf8),
            segments: [masterSeg1, masterSeg2],
            waypoints: [
                Waypoint(latitude: 0.0001, longitude: 0.0001,
                         name: "Trailhead", sym: "Trailhead",
                         description: "Start point"),
            ],
            role: .master,
            recordedDate: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let subSeg = Segment(color: blue, points: [
            TrackPoint(latitude: 0.0001, longitude: 0.00015),
            TrackPoint(latitude: 0.0002, longitude: 0.00025),
        ])
        let subTrack = Track(
            name: "Second pass",
            immutableOriginalBytes: Data("<gpx></gpx>".utf8),
            segments: [subSeg],
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

    @Test("Round-trips a populated session through JSONEncoder/Decoder")
    func roundTripsPopulatedSession() throws {
        // Note: this test exercises only the Models-layer Codable
        // conformance.  The production .gpxeditor codec's date encoding
        // strategy (which trades off readability vs. precision) is a
        // separate concern verified by ProjectFileTests in M1 task #6.
        // Here we use Codable's defaults, which preserve full Date
        // precision, so a model regression surfaces here cleanly.
        let original = sampleSession()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(GPXSession.self, from: data)
        #expect(decoded == original)
    }

    @Test("Round-trips a minimal empty session")
    func roundTripsEmptySession() throws {
        // A freshly-created project before any GPX is imported.  No
        // tracks, no viewport, default basemap, default metadata.
        // ProjectMetadata's defaults use `Date()` (sub-second precision);
        // Codable's default Date strategy preserves that precision
        // exactly.  The .iso8601 truncation question lives at the
        // codec layer.
        let original = GPXSession()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(GPXSession.self, from: data)
        #expect(decoded == original)
    }

    @Test("Preserves immutableOriginalBytes byte-for-byte through round-trip")
    func preservesImmutableOriginalBytes() throws {
        // The whole point of D-008's non-destructive document model is
        // that the original GPX bytes survive Save/Reopen verbatim so
        // Reset to Original works.  Codable's default `Data` encoding
        // is base64; verify bytes match after a round-trip.
        let bytes = Data((0..<256).map { UInt8($0) })  // every byte value
        let track = Track(
            name: "byte-preservation probe",
            immutableOriginalBytes: bytes
        )
        let session = GPXSession(tracks: [track])
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(session)
        let decoded = try decoder.decode(GPXSession.self, from: data)
        #expect(decoded.tracks[0].immutableOriginalBytes == bytes)
    }
}
