// ContentRuleListBuilder.swift
//
// Compiles a WKContentRuleList from BasemapCatalog's aggregated host list.
// SECURITY.md "Enforcement mechanism" mandates this rule list — every
// network request originating in the WebView is matched against it before
// any actual HTTP traffic occurs;  anything not matching the allow list is
// blocked at the WebKit layer, defending against tile-fetching code paths
// that bypass our own catalog (e.g., a vendored library that quietly
// hits a CDN).
//
// Compilation is asynchronous (WebKit's API is async).  The MapView
// coordinator awaits the compiled rule list before showing the WebView so
// the rule list is in place before the first tile fetch can occur — a
// race that, if lost, would let the initial fetch escape the rule list.
//
// This is one of the few `Services/` files that imports WebKit, alongside
// MapBridge.  CONVENTIONS.md "The data and operations layers are platform-
// agnostic" carves out this exception — the rule list is fundamentally a
// WebKit concept and there's no portable equivalent worth mocking.

import Foundation
import WebKit

/// Builder for the WebView's content rule list.  Stateless;  exposes a
/// single async function that produces a compiled WKContentRuleList from
/// the current BasemapCatalog.  The rule list's identifier is stable so
/// WebKit's compiled-rule-list cache across launches gives us a fast path
/// when the catalog hasn't changed.
public enum ContentRuleListBuilder {

    /// Stable identifier for the compiled rule list.  WebKit caches
    /// compiled rule lists by identifier in the user data directory;
    /// using a stable identifier means the second-and-later launches
    /// skip recompilation when the source hasn't changed.  Rotating
    /// this string forces a recompile, which is appropriate when
    /// changing the rule structure (not the host list — that's handled
    /// by automatic invalidation when the encoded JSON changes).
    public static let ruleListIdentifier = "com.gpxeditor.app.tile-allow-list-v1"

    /// Compile a content rule list from the catalog.  Throws if WebKit's
    /// compiler rejects the JSON — that should never happen because the
    /// JSON is generated, not user-supplied, but errors here indicate a
    /// programmer bug in this file (a bad rule shape) and should surface
    /// rather than be silently absorbed.
    @MainActor
    public static func compile() async throws -> WKContentRuleList {
        let json = try generateRuleListJSON()

        // WKContentRuleListStore.default() is the per-user-data-directory
        // store.  Compilation deduplicates against the identifier — if a
        // rule list with this identifier already exists and its source
        // matches, WebKit returns the cached compilation.
        guard let store = WKContentRuleListStore.default() else {
            throw ContentRuleListBuilderError.storeUnavailable
        }
        let ruleList = try await store.compileContentRuleList(
            forIdentifier: ruleListIdentifier,
            encodedContentRuleList: json
        )
        guard let ruleList else {
            throw ContentRuleListBuilderError.compilationProducedNil
        }
        return ruleList
    }

    /// Build the JSON the rule list compiler expects.  WKContentRuleList's
    /// JSON format is documented at
    /// developer.apple.com/documentation/safariservices/creating-a-content-blocker
    /// (the content-blocker format originally introduced for Safari content
    /// blockers, repurposed here for WebView resource gating).
    ///
    /// Three rule kinds, in this order (last match wins):
    ///
    ///   1. A default block-everything rule that catches anything not
    ///      explicitly allowed.
    ///   2. An allow rule for `file://` so locally-loaded resources from
    ///      the app bundle (index.html, editor.js, vendored libraries)
    ///      are never blocked.  The loadFileURL access scope is the
    ///      primary defense for local file loads, but on some WebKit
    ///      paths the rule list applies to file:// too — explicit allow
    ///      removes any ambiguity.
    ///   3. One allow rule per allowed host pattern, expressed as a
    ///      `url-filter` regex matching the *resource* URL.  Important
    ///      caveat:  WebKit's `if-domain` filters by the **page's**
    ///      first-party domain, NOT by the resource's domain — so for
    ///      our cross-origin tile fetches (page is file://, tiles are
    ///      https://) `if-domain` never fires.  We use `url-filter`
    ///      regex on the resource URL instead, which is what the
    ///      content-blocker format actually intends for this case.
    static func generateRuleListJSON() throws -> String {
        var rules: [[String: Any]] = []

        // (1) Default block.  Note `unless-top-url` is not applied —
        // we want this rule to match every resource by default, then be
        // overridden by the allow rules below.
        rules.append([
            "trigger": [
                "url-filter": ".*",
                "resource-type": [
                    "image",
                    "raw",
                    "fetch",
                    "websocket",
                    "media",
                    "ping",
                    "other",
                ],
            ],
            "action": [
                "type": "block",
            ],
        ])

        // (2) Allow file://.  Belt-and-suspenders alongside loadFileURL's
        // access-scope restriction.  The pattern matches scheme + ":"
        // anchored at the start of the URL.
        rules.append([
            "trigger": [
                "url-filter": "^file:",
            ],
            "action": [
                "type": "ignore-previous-rules",
            ],
        ])

        // (3) Allow tile-server hosts.  Each host pattern from
        // BasemapCatalog turns into one regex matching the resource URL.
        let aggregatedHosts = Set(BasemapCatalog.all.flatMap { $0.allowedHosts })
        for hostPattern in aggregatedHosts.sorted() {
            rules.append([
                "trigger": [
                    "url-filter": urlFilterRegex(forHostPattern: hostPattern),
                ],
                "action": [
                    "type": "ignore-previous-rules",
                ],
            ])
        }

        // Encode to JSON string.  WebKit's compiler wants a string.
        let data = try JSONSerialization.data(withJSONObject: rules, options: [])
        guard let json = String(data: data, encoding: .utf8) else {
            throw ContentRuleListBuilderError.jsonEncodingFailed
        }
        return json
    }

    /// Convert a host pattern from BasemapCatalog ("tile.openstreetmap.org"
    /// or "*.tile-cyclosm.openstreetmap.fr") into a `url-filter` regex
    /// matching only HTTPS resource URLs on that host.
    ///
    /// HTTP is deliberately excluded — every tile source we ship serves
    /// HTTPS, mixed-content blocking would silently break HTTP fallbacks
    /// anyway, and an HTTP allow would weaken the network posture for no
    /// realistic gain.
    static func urlFilterRegex(forHostPattern hostPattern: String) -> String {
        // Escape dots so they match literal `.` rather than any character.
        // url-filter is a "limited regex" but supports `\.` and `[^...]`.
        // Backslashes in Swift source need to be doubled;  the resulting
        // string is what WebKit parses as a regex.
        if hostPattern.hasPrefix("*.") {
            let suffix = String(hostPattern.dropFirst(2))
            let escapedSuffix = suffix.replacingOccurrences(of: ".", with: "\\.")
            // [^/]+\. matches one or more non-slash characters followed by a dot —
            // i.e., a single subdomain label and the connecting dot.  Multi-level
            // subdomains aren't a concern for our tile sources (none use them).
            return "^https://[^/]+\\.\(escapedSuffix)/"
        } else {
            let escaped = hostPattern.replacingOccurrences(of: ".", with: "\\.")
            return "^https://\(escaped)/"
        }
    }
}

/// Errors specific to rule-list compilation.  Per CONVENTIONS.md "Nothing
/// fails silently," every failure surfaces a typed error that the caller
/// can log or alert against;  we never coerce a compilation failure into
/// a "no rule list" fallback because that would silently disable the
/// network allow-list.
public enum ContentRuleListBuilderError: Error, LocalizedError {

    /// `WKContentRuleListStore.default()` returned nil.  Theoretically
    /// possible if the user data directory is unwritable;  in practice
    /// this never happens for a sandboxed macOS app under normal
    /// conditions.
    case storeUnavailable

    /// WebKit's compiler returned nil with no error — should not occur
    /// per the documented API contract, but we handle it explicitly so
    /// the caller doesn't unwrap nil.
    case compilationProducedNil

    /// JSONSerialization produced bytes that could not be UTF-8 decoded.
    /// JSONSerialization always emits UTF-8, so this is an "impossible"
    /// case kept here because the type signature requires handling it.
    case jsonEncodingFailed

    public var errorDescription: String? {
        switch self {
        case .storeUnavailable:
            return "WebKit's content rule list store is unavailable; map cannot enforce its tile-server allow-list."
        case .compilationProducedNil:
            return "WebKit's content rule list compiler returned no result; the allow-list could not be installed."
        case .jsonEncodingFailed:
            return "Internal error: rule-list JSON could not be UTF-8 encoded."
        }
    }
}
