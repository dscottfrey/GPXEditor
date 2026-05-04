// TrackImporterTests.swift
//
// Integration tests for the importer + Reset to Original operation.
// Exercise the full M1 I/O loop end-to-end:
//
//   1.  Read a synthetic GPX fixture's bytes.
//   2.  Run TrackImporter.importTracks to produce working-state Tracks.
//   3.  Wrap in a GPXSession, write via ProjectFile, read back.
//   4.  Mutate the track (simulate user editing).
//   5.  Call TrackImporter.resetTrackToOriginal.
//   6.  Assert the track is back to its as-imported state, with the
//       original identity (UUID) and role preserved.
//
// This is the M1 task #8 verification of the contract specified in
// D-008 (non-destructive document model) and Docs/01_DOCUMENT.md
// (Reset to Original behavior).

import Testing
import Foundation
@testable import GPXEditor

private final class TestBundleAnchor {}

@Suite("TrackImporter")
struct TrackImporterTests {

    // MARK: - Fixture loading

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

    // MARK: - Import

    @Test("Wraps a parsed GPX into Track values with UUIDs, palette colors, and original bytes preserved")
    func importsMinimalFixture() throws {
        let bytes = try loadFixture("synth-minimal-1.1")
        let result = TrackImporter.importTracks(
            from: bytes,
            sourceFilename: "synth-minimal-1.1.gpx",
            existingTrackCount: 0
        )

        let tracks = try result.get()
        #expect(tracks.count == 1)

        let track = tracks[0]

        // Name comes from <trk><name>, not the filename fallback,
        // because the fixture has an explicit track name.
        #expect(track.name == "Synthetic Null Island stroll")

        // Original bytes preserved verbatim per D-008.
        #expect(track.immutableOriginalBytes == bytes)

        // Recorded date taken from <metadata><time>.
        #expect(track.recordedDate != nil)

        // Default role is unaffiliated — the user marks master /
        // subsidiary later via the sidebar (M9).
        #expect(track.role == nil)

        // One segment with three points (matching the fixture).
        #expect(track.segments.count == 1)
        let segment = track.segments[0]
        #expect(segment.points.count == 3)

        // Palette color from slot 0 (existingTrackCount == 0).
        #expect(segment.color == DefaultPalette.colors[0])

        // Coordinates intact.
        #expect(segment.points[0].latitude == 0.0001)
        #expect(segment.points[2].elevation == 12.0)
    }

    @Test("Falls back to the source filename (sans extension) when GPX has no <trk><name>")
    func usesFilenameFallback() throws {
        // Build a synthetic GPX with no <trk><name> in memory.  Easier
        // than maintaining a separate fixture for this single edge case.
        let gpx = """
            <?xml version="1.0" encoding="UTF-8"?>
            <gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">
              <trk>
                <trkseg>
                  <trkpt lat="0.0" lon="0.0"/>
                </trkseg>
              </trk>
            </gpx>
            """
        let bytes = Data(gpx.utf8)

        let tracks = try TrackImporter.importTracks(
            from: bytes,
            sourceFilename: "morning-hike.gpx",
            existingTrackCount: 0
        ).get()

        // Track name fallback chain:  GPX <trk><name> (nil) ->
        // filename without extension ("morning-hike") -> generic
        // "Imported track" placeholder.  Filename wins here.
        #expect(tracks[0].name == "morning-hike")
    }

    @Test("Default 'Imported track' name when neither <trk><name> nor filename is supplied")
    func usesGenericFallback() throws {
        let gpx = """
            <?xml version="1.0" encoding="UTF-8"?>
            <gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">
              <trk>
                <trkseg>
                  <trkpt lat="0.0" lon="0.0"/>
                </trkseg>
              </trk>
            </gpx>
            """
        let tracks = try TrackImporter.importTracks(
            from: Data(gpx.utf8),
            sourceFilename: nil,
            existingTrackCount: 0
        ).get()
        #expect(tracks[0].name == "Imported track")
    }

    @Test("Palette offset advances per segment so multiple imports don't collide on slot 0")
    func paletteOffsetAdvancesAcrossImports() throws {
        let bytes = try loadFixture("synth-multi-trkseg")

        // First import:  existingTrackCount = 0.  Two segments take
        // slots 0 and 1.
        let firstBatch = try TrackImporter.importTracks(
            from: bytes,
            sourceFilename: nil,
            existingTrackCount: 0
        ).get()
        #expect(firstBatch[0].segments[0].color == DefaultPalette.colors[0])
        #expect(firstBatch[0].segments[1].color == DefaultPalette.colors[1])

        // Second import into a session that already has 2 segments
        // worth of color cursor advancement.  Two new segments take
        // slots 2 and 3 — no collision with the earlier import.
        let secondBatch = try TrackImporter.importTracks(
            from: bytes,
            sourceFilename: nil,
            existingTrackCount: 2
        ).get()
        #expect(secondBatch[0].segments[0].color == DefaultPalette.colors[2])
        #expect(secondBatch[0].segments[1].color == DefaultPalette.colors[3])
    }

    @Test("File-level waypoints attach to the first track only")
    func waypointsAttachToFirstTrack() throws {
        let bytes = try loadFixture("synth-with-waypoints")
        let tracks = try TrackImporter.importTracks(
            from: bytes,
            sourceFilename: nil,
            existingTrackCount: 0
        ).get()

        // The fixture has one track; all three file-level waypoints
        // attach to it.
        #expect(tracks.count == 1)
        #expect(tracks[0].waypoints.count == 3)

        // Waypoint names round-trip through the importer.  The "" name
        // case (waypoint with no <name>) maps to empty-string (not nil)
        // because Waypoint.name is non-optional.
        let names = Set(tracks[0].waypoints.map(\.name))
        #expect(names.contains("Trailhead"))
        #expect(names.contains("Summit"))
        #expect(names.contains(""))   // bare wpt with no name
    }

    // MARK: - Reset to Original

    @Test("Reset to Original re-parses the original bytes and preserves track identity + role")
    func resetToOriginalRevertsGeometry() throws {
        let bytes = try loadFixture("synth-minimal-1.1")
        let imported = try TrackImporter.importTracks(
            from: bytes,
            sourceFilename: nil,
            existingTrackCount: 0
        ).get()
        var track = imported[0]

        // Capture invariants we expect to survive reset.
        let originalId = track.id
        let originalImmutable = track.immutableOriginalBytes
        track.role = .master                           // mark as master
        let masterRole = track.role

        // Mutate the working state — simulate user editing.  Drop one
        // point, change another's coordinates, mutate the segment color.
        track.segments[0].points.remove(at: 0)
        track.segments[0].points[0] = TrackPoint(latitude: 99.0, longitude: 99.0, elevation: 999)
        track.segments[0].color = HexColor("#FF0000")!
        #expect(track.segments[0].points.count == 2)   // started with 3
        #expect(track.segments[0].points[0].latitude == 99.0)

        // Reset.
        let reset = try TrackImporter.resetTrackToOriginal(track, paletteOffset: 0).get()

        // Identity preserved.  This is what the sidebar uses to
        // reference a track across the reset operation — the user's
        // selection state, master/subsidiary tagging, etc. all key off
        // the UUID.
        #expect(reset.id == originalId)

        // Role preserved.
        #expect(reset.role == masterRole)

        // Immutable original bytes still intact (and equal to what the
        // input track held — Reset shouldn't alter them).
        #expect(reset.immutableOriginalBytes == originalImmutable)

        // Geometry reverted to the as-imported state.  Three points
        // (the fixture's count), original lat/lon/ele.
        #expect(reset.segments.count == 1)
        #expect(reset.segments[0].points.count == 3)
        #expect(reset.segments[0].points[0].latitude == 0.0001)
        #expect(reset.segments[0].points[2].elevation == 12.0)

        // Name reverted to the as-imported name.  (v1 interpretation
        // of "display metadata preserved" is loose — see TrackImporter
        // header for the discussion.)
        #expect(reset.name == "Synthetic Null Island stroll")
    }

    // MARK: - Full integration: Import -> Save -> Reopen -> Reset

    @Test("End-to-end: Import GPX -> Save .gpxeditor -> Reopen -> Reset to Original survives the round trip")
    func fullIntegrationRoundTrip() throws {
        // Step 1:  Import a GPX fixture into a fresh session.
        let bytes = try loadFixture("synth-multi-trkseg")
        let imported = try TrackImporter.importTracks(
            from: bytes,
            sourceFilename: "synth-multi-trkseg.gpx",
            existingTrackCount: 0
        ).get()

        // Wrap in a GPXSession that the document layer would carry.
        var session = GPXSession(
            metadata: ProjectMetadata(
                name: "Round-trip session",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                modifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
            ),
            tracks: imported
        )

        // Capture identity and role from the imported track.
        let trackId = session.tracks[0].id
        session.tracks[0].role = .master
        let assignedRole = session.tracks[0].role

        // Step 2:  Save through the project-file codec (simulates File
        // -> Save writing the .gpxeditor JSON envelope).
        let projectFileBytes = try ProjectFile.write(session)

        // Step 3:  Reopen — decode the .gpxeditor bytes back into a
        // GPXSession (simulates File -> Open of the saved project).
        let reopenedSession = try ProjectFile.read(projectFileBytes).get()

        // Sanity:  the reopened session has the same track, same id,
        // same role.  Original bytes preserved verbatim through the
        // base64 path in ProjectFile.
        #expect(reopenedSession.tracks.count == 1)
        let reopenedTrack = reopenedSession.tracks[0]
        #expect(reopenedTrack.id == trackId)
        #expect(reopenedTrack.role == assignedRole)
        #expect(reopenedTrack.immutableOriginalBytes == bytes)

        // Step 4:  Mutate the working state to simulate user editing
        // after the reopen.  Delete a segment.
        var editedTrack = reopenedTrack
        let originalSegmentCount = editedTrack.segments.count
        editedTrack.segments.removeFirst()
        #expect(editedTrack.segments.count == originalSegmentCount - 1)

        // Step 5:  Reset to Original.  Should re-parse the preserved
        // bytes and restore the segment count.
        let resetTrack = try TrackImporter.resetTrackToOriginal(
            editedTrack,
            paletteOffset: 0
        ).get()

        // Identity + role still preserved across reset.
        #expect(resetTrack.id == trackId)
        #expect(resetTrack.role == assignedRole)

        // Geometry restored.
        #expect(resetTrack.segments.count == originalSegmentCount)
    }
}
