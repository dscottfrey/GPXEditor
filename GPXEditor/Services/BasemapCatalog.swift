// BasemapCatalog.swift
//
// The curated, build-time list of basemaps GPXeditor ships with.  Single
// source of truth — the SwiftUI selector reads from it, the bridge sends
// the active entry to JS via `set_basemap`, and the WKContentRuleList is
// compiled from the union of every entry's `allowedHosts`.
//
// Decisions backing this list:
//
//   - D-008 / D-015:  curated, build-time, no user-added URLs in v1.
//   - HANDOFF.md Open Inputs #3 (resolved 2026-05-05):  NOAA Charts
//     deferred to v2 — no XYZ tile endpoint available.
//   - HANDOFF.md Open Inputs #4 (resolved 2026-05-05):  CyclOSM uses the
//     OSM-France mirror with {s}-rotation across a/b/c.
//
// The IDs (`"osm"`, `"opentopo"`, etc.) are persistence contracts — they
// appear in `.gpxeditor` files via GPXSession.selectedBasemapId.  Never
// rename an existing id;  add new ones for new entries.  Removing an id
// is graceful per GPXSession's comment ("Persisting an unknown id ... is
// non-fatal: the UI falls back to the default basemap and a warning
// surfaces") but every removal is still a SECURITY.md update.
//
// Platform-agnostic.  Foundation only;  no WebKit.

import Foundation

/// The catalog.  Static list, no runtime mutation path.
public enum BasemapCatalog {

    /// Every basemap available in this build.  Display order is the order
    /// of this array.  The first entry is the default for newly-created
    /// projects (matches `GPXSession.selectedBasemapId`'s init default
    /// of `"osm"` — keep these aligned).
    public static let all: [Basemap] = [

        // ─── OpenStreetMap Standard ─────────────────────────────────
        // Default basemap.  Single host, no subdomain rotation since OSM
        // consolidated to one host years ago.  Attribution per the
        // OSMF tile usage policy (operations.osmfoundation.org/policies/tiles).
        Basemap(
            id: "osm",
            displayName: "OpenStreetMap",
            tileURLTemplate: "https://tile.openstreetmap.org/{z}/{x}/{y}.png",
            attribution: "© OpenStreetMap contributors",
            maxZoom: 19,
            allowedHosts: ["tile.openstreetmap.org"]
        ),

        // ─── OpenTopoMap ────────────────────────────────────────────
        // Topographic rendering, ideal for hiking tracks.  Uses a/b/c
        // subdomain rotation;  the wildcard host pattern in the rule
        // list covers all three.  Attribution combines OSM (data) and
        // OpenTopoMap (rendering, SRTM elevation).
        Basemap(
            id: "opentopo",
            displayName: "OpenTopoMap",
            tileURLTemplate: "https://{s}.tile.opentopomap.org/{z}/{x}/{y}.png",
            attribution: "Map data: © OpenStreetMap contributors, SRTM | Map style: © OpenTopoMap (CC-BY-SA)",
            maxZoom: 17,
            allowedHosts: ["*.tile.opentopomap.org", "tile.opentopomap.org"]
        ),

        // ─── USGS National Map (Topo) ───────────────────────────────
        // US-only authoritative topographic.  Single host, no rotation.
        // The tile server itself is an ArcGIS REST tile service that
        // happens to also work as plain XYZ at the path below.
        Basemap(
            id: "usgs",
            displayName: "USGS Topo",
            tileURLTemplate: "https://basemap.nationalmap.gov/arcgis/rest/services/USGSTopo/MapServer/tile/{z}/{y}/{x}",
            attribution: "Tiles courtesy of the U.S. Geological Survey",
            maxZoom: 16,
            allowedHosts: ["basemap.nationalmap.gov"]
        ),

        // ─── Esri World Imagery ─────────────────────────────────────
        // Aerial / satellite imagery for visual track verification.
        // Single host.  Attribution per Esri's terms — names the imagery
        // providers Esri aggregates.
        Basemap(
            id: "esri-imagery",
            displayName: "Satellite (Esri)",
            tileURLTemplate: "https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}",
            attribution: "Tiles © Esri — Source: Esri, Maxar, Earthstar Geographics, and the GIS User Community",
            maxZoom: 19,
            allowedHosts: ["server.arcgisonline.com"]
        ),

        // ─── CyclOSM ────────────────────────────────────────────────
        // Cycle- and hike-oriented OSM rendering, hosted by OSM-France.
        // Uses {s} rotation across a/b/c subdomains.  Governed by the
        // OSMF tile usage policy — in particular the User-Agent rule
        // documented in SECURITY.md "Identifying User-Agent" applies.
        Basemap(
            id: "cyclosm",
            displayName: "CyclOSM",
            tileURLTemplate: "https://{s}.tile-cyclosm.openstreetmap.fr/cyclosm/{z}/{x}/{y}.png",
            attribution: "© OpenStreetMap contributors, CyclOSM & OSM-FR",
            maxZoom: 20,
            allowedHosts: ["*.tile-cyclosm.openstreetmap.fr"]
        ),
    ]

    /// Lookup by id;  used by MapBridge to encode the active basemap into
    /// a `set_basemap` payload.  Returns nil for unknown ids — callers
    /// fall back to `defaultBasemap` per GPXSession's contract.
    public static func basemap(forId id: String) -> Basemap? {
        return all.first(where: { $0.id == id })
    }

    /// Default basemap used when (a) a new project is created and (b) a
    /// loaded project's `selectedBasemapId` is not in the catalog.
    /// Currently the OSM Standard entry (the first in `all`).
    public static var defaultBasemap: Basemap {
        // Force-unwrap is safe because `all` is statically non-empty;
        // this would only fail in a build where someone deleted every
        // entry, which would also break the WKContentRuleList compilation
        // and surface immediately in development.
        return all.first!
    }
}
