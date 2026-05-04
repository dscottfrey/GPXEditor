// TrackImporter.swift
//
// Promotes the parser's `RawGPX` intermediate into one or more working-
// state `Track` values, doing the work the parser deliberately doesn't:
// generating UUIDs for tracks/segments/waypoints, assigning palette
// colors to segments, attaching the immutable original bytes per D-008,
// and falling back to a default name when the source file lacks one.
//
// This is the boundary between "what the XML literally said" (RawGPX)
// and "what the working-state editing model needs" (Track).  Keeping it
// separate from the parser means the parser stays focused on XML and
// the working-state shape can evolve (UUID strategy, color picking,
// name fallback heuristics) without touching parser code.
//
// Also hosts the per-track Reset to Original operation:  re-parse the
// immutable original bytes and produce a fresh Track value with the
// same identity (id) and master/subsidiary role as the input, but
// fresh segments / waypoints / recordedDate from the re-parse.  Per
// D-008 the original bytes are preserved verbatim, so this is always
// possible without touching the filesystem.

import Foundation

/// Convert parsed GPX (RawGPX) into working-state Track values, and
/// reset existing Tracks back to their as-imported state.  Stateless
/// — every entry point is a pure function of its inputs.
public enum TrackImporter {

    /// Parse `data` as GPX bytes and produce one Track per `<trk>` in
    /// the source.  The original bytes are stored verbatim in each
    /// resulting Track's `immutableOriginalBytes` (per D-008) so a
    /// later Reset to Original is byte-exact.
    ///
    /// - Parameters:
    ///   - data: raw GPX file bytes.
    ///   - sourceFilename: optional filename (e.g. "morning-hike.gpx")
    ///     used as a fallback Track name when the GPX file's
    ///     `<trk><name>` is absent.  Pass nil if no filename context
    ///     applies (e.g. when called from a paste-from-clipboard flow).
    ///   - existingTrackCount: how many tracks the destination session
    ///     already contains.  Used to choose the starting palette
    ///     color so newly-imported tracks don't collide with existing
    ///     ones in the same project.
    public static func importTracks(
        from data: Data,
        sourceFilename: String?,
        existingTrackCount: Int
    ) -> Result<[Track], GPXParseError> {
        switch GPXParser.parse(data) {
        case .failure(let err):
            return .failure(err)
        case .success(let raw):
            return .success(buildTracks(
                from: raw,
                immutableBytes: data,
                sourceFilename: sourceFilename,
                existingTrackCount: existingTrackCount
            ))
        }
    }

    /// Reset a Track to its as-imported state.  Re-parses
    /// `track.immutableOriginalBytes` and produces a fresh Track value
    /// preserving only the input's identity (`id`) and master/
    /// subsidiary role; segments, waypoints, name, and recordedDate
    /// are taken from the re-parse.
    ///
    /// Per `Docs/01_DOCUMENT.md`, "the track's identity, color,
    /// position in the master/subsidiary hierarchy, and other display
    /// metadata are preserved; only the point geometry resets."  In
    /// v1 we interpret "color preserved" loosely:  the new segments
    /// receive fresh palette colors based on their position in the
    /// session, since the original-import-time per-segment colors
    /// aren't recoverable without per-segment ancestry tracking.
    /// Documented as a known v1 limitation in the integration test.
    ///
    /// - Parameters:
    ///   - track: the Track to reset.
    ///   - paletteOffset: the Track's position in the session's
    ///     `tracks` array, used for palette color selection.
    public static func resetTrackToOriginal(
        _ track: Track,
        paletteOffset: Int
    ) -> Result<Track, GPXParseError> {
        switch GPXParser.parse(track.immutableOriginalBytes) {
        case .failure(let err):
            return .failure(err)
        case .success(let raw):
            // The immutable original bytes came from a single source
            // file's import.  If multi-track, take the first one (the
            // most common shape — single-track per file).  If empty
            // (degenerate), produce a Track with empty segments.
            let fresh = buildTracks(
                from: raw,
                immutableBytes: track.immutableOriginalBytes,
                sourceFilename: nil,
                existingTrackCount: paletteOffset
            ).first
            ?? Track(
                id: track.id,
                name: track.name,
                immutableOriginalBytes: track.immutableOriginalBytes
            )

            // Preserve identity (id) and role; replace everything else
            // with the freshly-parsed values.
            return .success(Track(
                id: track.id,
                name: fresh.name,
                immutableOriginalBytes: track.immutableOriginalBytes,
                segments: fresh.segments,
                waypoints: fresh.waypoints,
                role: track.role,
                recordedDate: fresh.recordedDate
            ))
        }
    }

    // MARK: - Internal

    /// Translate every `RawTrack` in `raw` into a working-state Track.
    /// File-level waypoints are attached to the FIRST track (the most
    /// common shape for single-track files); a future enhancement
    /// could distribute waypoints by spatial proximity but D-008's
    /// "track owns its waypoints" model lets us punt on that for v1.
    private static func buildTracks(
        from raw: RawGPX,
        immutableBytes: Data,
        sourceFilename: String?,
        existingTrackCount: Int
    ) -> [Track] {
        // Strip the file extension (".gpx") off the filename for use
        // as a Track-name fallback — "morning-hike.gpx" reads better
        // as "morning-hike" in the sidebar than with the extension.
        let nameFallback: String? = {
            guard let f = sourceFilename else { return nil }
            return (f as NSString).deletingPathExtension
        }()

        // Track which palette slot to use next.  Each track increments
        // the offset based on its segment count, so two tracks each
        // with three segments occupy slots 0,1,2 and 3,4,5 respectively
        // rather than colliding at 0,1,2 and 0,1,2.
        var paletteCursor = existingTrackCount

        let tracks: [Track] = raw.tracks.enumerated().map { (offset, rawTrack) in
            let segments: [Segment] = rawTrack.segments.map { rawSeg in
                let segment = Segment(
                    id: UUID(),
                    color: DefaultPalette.color(at: paletteCursor),
                    points: rawSeg.points.map { rawPt in
                        TrackPoint(
                            latitude: rawPt.latitude,
                            longitude: rawPt.longitude,
                            elevation: rawPt.elevation,
                            time: rawPt.time
                        )
                    }
                )
                paletteCursor += 1
                return segment
            }

            // Attach file-level waypoints to the FIRST track only.
            // Subsequent tracks in a multi-track file get no waypoints
            // unless the GPX explicitly placed them inside the track
            // (which the spec doesn't allow — wpt is doc-level only).
            let waypoints: [Waypoint] = (offset == 0)
                ? raw.waypoints.map { rawWpt in
                    Waypoint(
                        id: UUID(),
                        latitude: rawWpt.latitude,
                        longitude: rawWpt.longitude,
                        elevation: rawWpt.elevation,
                        time: rawWpt.time,
                        name: rawWpt.name ?? "",
                        sym: rawWpt.sym ?? "Generic",
                        description: rawWpt.description
                    )
                }
                : []

            // Name fallback chain:  the GPX's <trk><name>, then the
            // source filename (without extension), then a generic
            // "Imported track" placeholder.
            let name = rawTrack.name
                ?? nameFallback
                ?? "Imported track"

            return Track(
                id: UUID(),
                name: name,
                immutableOriginalBytes: immutableBytes,
                segments: segments,
                waypoints: waypoints,
                role: nil,  // unaffiliated by default; user marks master / subsidiary later
                recordedDate: raw.metadataTime
            )
        }

        return tracks
    }
}
