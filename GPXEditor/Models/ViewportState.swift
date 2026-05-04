// ViewportState.swift
//
// The map viewport that should be restored when a project is reopened.
// Captured in the `.gpxeditor` JSON file so the user lands back where
// they were when they saved, rather than being auto-zoomed to fit
// (which is jarring if they were focused on a small region).
//
// Stored as plain numeric fields rather than as a Leaflet-specific
// LatLngBounds or MKCoordinateRegion so the model stays platform-
// agnostic per CONVENTIONS.md.  The MapView (M2) translates between
// this representation and whatever the WebView needs at the bridge
// boundary.

import Foundation

/// A persisted map viewport: center coordinate plus zoom level (in the
/// Leaflet/Slippy-Map convention where 0 is whole-world and ~19 is
/// street-level detail).
public struct ViewportState: Equatable, Codable, Sendable {

    /// Latitude of the map center in WGS84 decimal degrees.
    public var centerLatitude: Double

    /// Longitude of the map center in WGS84 decimal degrees.
    public var centerLongitude: Double

    /// Map zoom level using Leaflet/Slippy-Map convention (0 ≈ world,
    /// ~19 ≈ building-level).  Stored as Double rather than Int because
    /// Leaflet supports fractional zoom and we want to round-trip
    /// whatever the user saved.
    public var zoom: Double

    public init(centerLatitude: Double, centerLongitude: Double, zoom: Double) {
        self.centerLatitude = centerLatitude
        self.centerLongitude = centerLongitude
        self.zoom = zoom
    }
}
