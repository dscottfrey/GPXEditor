// Waypoint.swift
//
// A named point of interest — a campsite marker, a water source, a summit,
// a trailhead.  Waypoints map directly to GPX `<wpt>` elements and use
// Garmin's `<sym>` icon vocabulary so they survive a round-trip through
// any consuming tool that recognizes the standard symbols (D-014's curated
// icon set names align with Garmin sym).
//
// Waypoints are owned by Tracks, not by Segments, in the data model.  The
// sidebar groups them visually under the segment whose extent contains
// them (Docs/05_UI.md), but that grouping is a UI concern computed from
// position — not a stored relationship.  The reasoning: GPX places `<wpt>`
// at the document level (peer to `<trk>`), so Track ownership matches the
// source format and avoids the "which segment does this imported waypoint
// belong to?" question for which there is no general answer.  If a future
// editing flow needs per-segment storage we can revisit; for v1 the
// computed-grouping approach is enough.

import Foundation

/// A named point of interest with a Garmin-style icon symbol.  Identity is
/// stable across edits because the sidebar references waypoints by id.
public struct Waypoint: Identifiable, Equatable, Codable, Sendable {

    /// Stable identity for this waypoint, independent of its name or
    /// position.  Generated when the waypoint is created — either by the
    /// Waypoint Place tool (M5) or by the GPX importer when ingesting a
    /// `<wpt>` from a source file.
    public let id: UUID

    /// Latitude in WGS84 decimal degrees.
    public var latitude: Double

    /// Longitude in WGS84 decimal degrees.
    public var longitude: Double

    /// Elevation in meters above the WGS84 ellipsoid; optional for the
    /// same reasons as `TrackPoint.elevation`.
    public var elevation: Double?

    /// Original recording timestamp; rarely populated for waypoints but
    /// preserved if the source GPX file includes it.
    public var time: Date?

    /// User-visible name shown in the sidebar and on the map.  Empty
    /// string for an unnamed waypoint rather than `nil` so the property
    /// can be edited in a SwiftUI `TextField` without optional-binding
    /// gymnastics.
    public var name: String

    /// The Garmin `<sym>` symbol name.  Drawn from the curated icon set
    /// described in D-014 (Campsite, Water, Restroom, Trailhead, Summit,
    /// Vista, Parking, Hazard, Information, Bridge, Ford, Gate, Photo,
    /// Crossing, Generic).  Stored as a free-form String rather than a
    /// closed enum so an imported waypoint with an unrecognized sym name
    /// (a Garmin variant we don't render) survives round-trip — the
    /// importer doesn't drop unknown values, and the writer emits whatever
    /// is here.  Defaults to `"Generic"` for a freshly-placed waypoint.
    public var sym: String

    /// Optional free-form description, mapping to GPX `<desc>`.
    public var description: String?

    public init(
        id: UUID = UUID(),
        latitude: Double,
        longitude: Double,
        elevation: Double? = nil,
        time: Date? = nil,
        name: String = "",
        sym: String = "Generic",
        description: String? = nil
    ) {
        self.id = id
        self.latitude = latitude
        self.longitude = longitude
        self.elevation = elevation
        self.time = time
        self.name = name
        self.sym = sym
        self.description = description
    }
}
