# 02 — Map View and JS↔Swift Bridge (STUB)

> **Status: stub.** Section headings outline intended scope; bodies are placeholders. Full bodies to be drafted before M2, since this is the directive M2 depends on most directly.

## Scope

The Map subsystem covers the WKWebView wrapper, the JavaScript-side editor running inside it (Leaflet plus our custom `editor.js`), the JS↔Swift bridge protocol, the basemap selector, and the `WKContentRuleList` enforcement of the network allow-list. Spans `Views/MapView.swift` (the SwiftUI/`NSViewRepresentable` wrapper), `Services/MapBridge.swift` (the Swift side of the bridge), and `WebResources/` (the web layer — see `Docs/03_WEB_RESOURCES.md` for vendored asset rules).

## WKWebView setup (in `Views/MapView.swift`)

To be expanded. `NSViewRepresentable` wrapping `WKWebView`. Loads `WebResources/index.html` via `loadFileURL(_:allowingReadAccessTo:)` with read access scoped to the `WebResources/` folder. Configuration: JavaScript enabled, `allowsBackForwardNavigationGestures` off, `navigationDelegate` rejects any non-local navigation. The compiled `WKContentRuleList` (see SECURITY.md) is applied to the WebView's `WKUserContentController` at setup time.

## Bridge architecture (in `Services/MapBridge.swift`)

To be expanded. `MapBridge` owns the `WKScriptMessageHandler` registration (handler name `gpxBridge`) and the helper for sending Swift→JS messages via `evaluateJavaScript`. Stateless beyond the WebView reference; routing decisions happen at the `MessageDispatcher` layer that consumes parsed messages. `MapBridge` is the only file in `Services/` that imports WebKit (per CONVENTIONS.md platform-agnostic-data-layer carve-out).

## Message envelope shape

To be expanded; full convention described in CONVENTIONS.md "JavaScript ↔ Swift bridge protocol." Every message in either direction has the form `{type: "verb_in_snake_case", id?: "uuid-string", payload: {...}}`. Strict validation on receive: unknown types and malformed payloads are logged and discarded, never silently mutate state.

## Message type catalog

To be expanded into a full schema reference. Initial set of message types needed for M2 through M9, grouped by direction:

**Swift → JS:**
- `load_session` — full project state for initial render
- `update_tracks` — partial update after Swift-side mutation
- `set_basemap` — switch tile layer
- `render_brush_preview` — show transient overlay during a drag
- `clear_brush_preview` — remove transient overlay on commit or cancel
- `highlight_selection` — visualize the current selection in the map view

**JS → Swift:**
- `points_selected` — selection state changed (marquee, lasso, click)
- `delete_points` — delete request from a gesture
- `move_point` — vertex drag committed
- `add_point_on_line` — click-on-line insertion
- `place_waypoint` — Waypoint Place tool gesture
- `apply_brush` — brush stroke committed (with brush type and parameters)
- `request_segment_stats` — query for segment-level statistics (with `id` for response correlation)
- `log` — structured log message (replaces `console.log` in production code)

Each message type has a documented payload schema. Schema documentation will be filled in here when this stub is expanded.

## Basemap selector

To be expanded. UI control in the map view (toggle button opening a list, or a segmented control). Active basemap is per-project state (saved in the `.gpxeditor` file) with a global default in Settings. List of available basemaps is the curated set from D-008 / SECURITY.md network allow-list. Switch action: send `set_basemap` to JS with the new tile URL template; JS swaps the Leaflet tile layer.

## Initialization sequence

To be expanded. Document load → WebView attach → `index.html` load → JS initialization (Leaflet map created, default basemap loaded) → JS sends `ready` to Swift → Swift sends `load_session` with the current project state → JS draws polylines, waypoints, and zooms to fit. All state flows from Swift; JS never holds authoritative document state (per CONVENTIONS.md Swift-as-source-of-truth invariant).

## Cross-references

- `DECISIONS.md` D-007 (app shell architecture), D-008 (tile source picker)
- `CONVENTIONS.md` JavaScript ↔ Swift bridge protocol, Swift-as-source-of-truth invariant
- `SECURITY.md` Network allow-list, `WKContentRuleList` enforcement
- `Docs/03_WEB_RESOURCES.md` Vendored asset rules
- `Docs/04_EDITING.md` Tools and brushes that use this bridge
