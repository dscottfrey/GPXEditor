// NetworkAllowList.swift
//
// The single source of truth for which network destinations the application
// is permitted to reach.  Two consumers read from this:
//
//   1. ContentRuleListBuilder compiles the tile-server domains into a
//      WKContentRuleList so the WebView blocks anything else at the WebKit
//      layer (SECURITY.md "Enforcement mechanism" mandates this for every
//      tile fetch originating in the WebView, since Leaflet issues its own
//      <img> requests outside our direct control).
//
//   2. The elevation service (M7) and any other Swift-side URLSession
//      consumer validates the request URL against `swiftSideEndpoints`
//      before allowing the request to proceed.
//
// Both lists are deliberately short.  Adding to either is a SECURITY.md
// update plus a code change here — they are kept in sync because the
// rule list is rebuilt from this file at startup.  Removing a basemap
// from BasemapCatalog must remove its domains from this list too;
// orphan domains in the allow-list aren't exploitable but they violate
// the "minimum capability" posture documented in SECURITY.md.
//
// The list as of M2:  D-008 / SECURITY.md curated tile sources, plus the
// elevation API which is added at M7 (kept in this file from the start
// so the data structure doesn't need to grow at that point).
//
// This file is platform-agnostic per CONVENTIONS.md "The data and
// operations layers are platform-agnostic" — it imports Foundation only
// and does not touch WebKit.  The WebKit-bound consumer is
// ContentRuleListBuilder.

import Foundation

/// Curated network allow-list for GPXeditor.  Static — there is no
/// run-time mutation path.  D-015 documents why custom user-added tile
/// URLs are out of scope for v1.
public enum NetworkAllowList {

    /// Hosts the WebView is permitted to fetch tiles from.  Each entry
    /// is a host string;  exact matches and "*.<host>" wildcards are both
    /// supported by ContentRuleListBuilder's compilation step.  Subdomain
    /// rotation in Leaflet's {s} placeholder (typically a/b/c) is handled
    /// by the wildcard form.
    ///
    /// Order matches the basemap selector's display order in the UI —
    /// purely cosmetic, no semantic meaning.
    public static let tileServerHosts: [String] = [
        // OpenStreetMap Standard — default basemap.  No subdomain rotation
        // on this domain (osm.org consolidated to a single host).
        "tile.openstreetmap.org",

        // OpenTopoMap — rotates across a/b/c.tile.opentopomap.org.
        "*.tile.opentopomap.org",
        "tile.opentopomap.org",   // direct host kept for any non-subdomain references

        // USGS National Map — single host, no rotation.
        "basemap.nationalmap.gov",

        // Esri World Imagery — single host, served via ArcGIS Online.
        "server.arcgisonline.com",

        // CyclOSM — OSM-France tile server, rotates across a/b/c subdomains.
        // The published URL template uses {s}.tile-cyclosm.openstreetmap.fr;
        // wildcard match covers a/b/c.
        "*.tile-cyclosm.openstreetmap.fr",
    ]

    /// Hosts the Swift-side URLSession traffic is permitted to reach.
    /// Currently just OpenTopoData for the M7 Pin to Ground feature.
    /// SECURITY.md "Enforcement mechanism" mandates that every URLSession
    /// request through the app validates against this list.
    public static let swiftSideEndpoints: [String] = [
        "api.opentopodata.org",
    ]
}
