// TrackPoint.swift
//
// A single recorded sample point inside a track segment.  TrackPoints are
// the leaf nodes of the data model — every track is a list of segments and
// every segment is a list of TrackPoints.
//
// Identity by position, not UUID:  unlike Tracks, Segments, and Waypoints,
// a TrackPoint has no stable `id` field.  Selection, undo, and bridge
// messages refer to a TrackPoint by its (track id, segment id, index)
// triple.  The reasoning: track points are added, deleted, inserted, and
// re-ordered constantly during editing — every brush stroke can touch
// thousands of them — and assigning a UUID per point would be pure
// overhead.  Index-based identity is stable enough because the undo system
// (D-009) snapshots whole segments per operation; an undo restores the
// segment and its old indices come back with it.
//
// Per-point timestamps are kept in the working-state model.  The Stats
// panel (M8) computes speed and gradient from them when present.  The
// writer drops them on export (D-012) so exported GPX is unambiguous about
// which points are real recording samples and which were synthesized by
// editing — but in-memory we still want them around for stats and so an
// untouched original-recording point can keep its real timestamp through
// any edit that doesn't move it.

import Foundation

/// A single recorded sample point: latitude, longitude, optional elevation
/// in meters, optional recording timestamp.  No identity field — see file
/// header.
public struct TrackPoint: Equatable, Codable, Sendable {

    /// Latitude in WGS84 decimal degrees, range `[-90.0, 90.0]`.
    public var latitude: Double

    /// Longitude in WGS84 decimal degrees, range `[-180.0, 180.0]`.
    public var longitude: Double

    /// Elevation in meters above the WGS84 ellipsoid as recorded by the
    /// device.  Optional because not every recording includes elevation
    /// (cheap GPS units often omit it; some apps strip it).
    public var elevation: Double?

    /// Original recording timestamp from the source GPX file's `<time>`
    /// child element on the `<trkpt>`.  Optional because not every recording
    /// includes per-point timestamps and many of our use cases (averaging,
    /// adding detail points, simplification) produce points that have no
    /// real recording time.  See D-012 for why exports drop this field
    /// unconditionally.
    public var time: Date?

    public init(
        latitude: Double,
        longitude: Double,
        elevation: Double? = nil,
        time: Date? = nil
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.elevation = elevation
        self.time = time
    }
}
