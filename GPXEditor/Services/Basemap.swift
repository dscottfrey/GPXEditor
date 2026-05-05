// Basemap.swift
//
// Value type describing one entry in the curated basemap catalog (D-008,
// D-015, SECURITY.md "Allowed endpoints").  Each Basemap value carries
// everything two consumers need:
//
//   - The basemap selector UI (Components/BasemapSelectorView.swift) reads
//     `id`, `displayName`, and uses `attribution` for the secondary label.
//   - MapBridge encodes `id`, `tileURLTemplate`, `attribution`, `maxZoom`
//     into a `set_basemap` bridge message when the active basemap changes.
//
// `allowedHosts` doesn't go through the bridge — it feeds
// ContentRuleListBuilder, which compiles a WKContentRuleList covering
// every host across every basemap in the catalog.  Holding the host list
// on the Basemap rather than only on NetworkAllowList means adding a
// basemap is genuinely one place:  add an entry to BasemapCatalog,
// supplying its hosts, and both the UI selector and the network
// allow-list pick it up.
//
// Platform-agnostic per CONVENTIONS.md.  Foundation only.

import Foundation

/// One entry in the curated basemap catalog.  Identity by stable string
/// id (persisted in `.gpxeditor` files via `GPXSession.selectedBasemapId`),
/// not by index — adding or reordering entries in BasemapCatalog must
/// preserve the persistence contract.
public struct Basemap: Identifiable, Equatable, Sendable {

    /// Stable identifier used in the on-disk project format and in the
    /// `set_basemap` bridge message.  Never changes once shipped;  if a
    /// basemap is replaced (different tile source under the same name),
    /// give the replacement a new id and let GPXSession's "unknown id
    /// falls back to default" path handle old projects gracefully.
    public let id: String

    /// User-visible display name shown in the basemap selector.
    public let displayName: String

    /// Leaflet-style URL template with {s}/{z}/{x}/{y} placeholders.
    /// Sent through the bridge to `editor.js` which hands it directly to
    /// `L.tileLayer(...)`.  The {s} subdomain rotation, if used, is
    /// handled by Leaflet (default subdomains 'abc' which matches the
    /// convention every tile source we ship uses).
    public let tileURLTemplate: String

    /// Attribution string shown by Leaflet's attribution control.  Per
    /// the OSMF tile usage policy and OpenTopoMap / CyclOSM / Esri
    /// individual requirements this must be visible on the map.  Free
    /// HTML is allowed by Leaflet (it renders the string into the
    /// attribution control), but we keep entries to plain text or
    /// minimal anchor links to keep the payload small and CSP-friendly.
    public let attribution: String

    /// Maximum zoom level supported by this tile source.  Beyond this,
    /// Leaflet renders an empty layer at the over-zoomed level.
    /// Conservative defaults are fine — over-zooming is fixable later
    /// per source if a real use case wants deeper detail.
    public let maxZoom: Int

    /// Hosts this basemap fetches tiles from.  Strings are either exact
    /// hosts (e.g., "tile.openstreetmap.org") or "*.<host>" wildcard
    /// patterns covering subdomain rotations.  Aggregated across the
    /// catalog by ContentRuleListBuilder into the WKContentRuleList.
    public let allowedHosts: [String]

    public init(
        id: String,
        displayName: String,
        tileURLTemplate: String,
        attribution: String,
        maxZoom: Int,
        allowedHosts: [String]
    ) {
        self.id = id
        self.displayName = displayName
        self.tileURLTemplate = tileURLTemplate
        self.attribution = attribution
        self.maxZoom = maxZoom
        self.allowedHosts = allowedHosts
    }
}
