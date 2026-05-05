# 02 — Map View and JS↔Swift Bridge

This directive specifies the architecture and protocol that connect Swift to the Leaflet-based map editor running inside `WKWebView`. M2 (Map view and basemap selector) is the milestone that lands this code; M3 onward extends the message catalog as new editing features come online. Read SECURITY.md "Network allow-list" and "Vendored web assets" before touching anything in this directive — the rules there are non-negotiable and several of the choices below are downstream of them.

## Scope

The Map subsystem comprises:

- **`Views/MapView.swift`** — the SwiftUI `NSViewRepresentable` that wraps `WKWebView` and exposes it to the rest of the app.
- **`Services/MapBridge.swift`** — the Swift side of the JS↔Swift bridge, hosting the `WKScriptMessageHandler` and the `evaluateJavaScript` dispatch helpers.
- **`Services/MessageDispatcher.swift`** — routes parsed inbound messages to operation handlers; keeps `MapBridge` itself stateless beyond its WebView reference.
- **`Services/BasemapCatalog.swift`** — the curated list of tile-source definitions (display name, attribution, tile URL template), the single source of truth from which both the basemap selector UI and the `WKContentRuleList` are derived.
- **`Services/NetworkAllowList.swift`** — exposes the allowed tile-server domains (consumed by `BasemapCatalog` and the rule-list builder) and the allowed Swift-side endpoints (consumed by the elevation service in M7).
- **`Services/ContentRuleListBuilder.swift`** — compiles a `WKContentRuleList` from `BasemapCatalog` at app startup.
- **`WebResources/index.html`** — the host page loaded by the WebView. CSP-locked, loads vendored libraries and `editor.js`.
- **`WebResources/editor.js`** — the JS-side editor: bridge dispatcher, Leaflet glue, render pipeline, gesture handlers.

The bridge protocol's envelope shape and validation discipline are stated project-wide in CONVENTIONS.md "JavaScript ↔ Swift bridge protocol"; this document is the catalog of concrete message types and their payloads.

## WKWebView setup

### `MapView` (in `Views/MapView.swift`)

`MapView` is a SwiftUI `NSViewRepresentable` whose `makeNSView(context:)` constructs a single `WKWebView` configured as follows. The configuration is non-default in several places; the reasons matter and are documented inline so a future maintainer doesn't "clean them up" without realizing what they do.

- **`WKWebViewConfiguration.userContentController`** — the controller is constructed first because both `WKContentRuleList` (allow-list enforcement) and `WKScriptMessageHandler` (the bridge) attach to it. The `gpxBridge` handler is registered with `add(_:name:)`. The rule list compiled by `ContentRuleListBuilder` is applied via `add(_:)` synchronously on the main actor before the WebView loads any URL — applying it after a load would let the initial tile fetch escape the rule list.

- **`defaultWebpagePreferences.allowsContentJavaScript = true`** — required; the editor cannot run otherwise. (This replaces the deprecated `WKPreferences.javaScriptEnabled` on macOS 14+; D-006 pins us to that floor.)

- **`preferences.javaScriptCanOpenWindowsAutomatically = false`** — the editor never opens new windows; blocking this denies an entire class of accidents if a vendored asset ever calls `window.open`.

- **`allowsBackForwardNavigationGestures = false`** — the WebView is a single-page editor surface, not a browser. A swipe gesture that navigates "back" away from `index.html` would leave the editor in an unrecoverable state.

- **`allowsLinkPreview = false`** — link preview popovers don't make sense in a map editor and would introduce a path for unexpected resource loads.

- **`navigationDelegate`** — set to a small delegate that allows the initial `file://` load of `index.html` and **denies every subsequent navigation request**. The editor does not navigate; if `editor.js` ever attempts to set `window.location` or follow a link, the navigation is canceled and a bridge violation is logged. This is belt-and-suspenders alongside the `WKContentRuleList`.

- **`developerExtrasEnabled`** — set to `true` only in Debug builds (gated on `#if DEBUG`). This enables the WebView's right-click → Inspect Element and the Web Inspector. Release builds ship with developer tools off because they are an unnecessary surface in shipped software, even though the tools require user action to invoke.

- **`customUserAgent`** — set to `GPXeditor/<version> (+<repo URL>)` per SECURITY.md "Identifying User-Agent." The default WKWebView UA identifies as Safari, which is wrong for an embedded application and would conceal us from tile-server operators. The value is built from the same build-info string the About panel displays; until M10 the repository URL is a placeholder. Applies to every basemap, not just OSM-derived ones — set once at WebView construction.

### Loading `index.html`

The WebView loads `WebResources/index.html` via `loadFileURL(_:allowingReadAccessTo:)`. The `allowingReadAccessTo:` URL is the `WebResources/` folder inside the app bundle — **not** the bundle root, **not** `URL(fileURLWithPath: "/")`, and **not** the user's home directory. Scoping read access to `WebResources/` means a misbehaving JS file cannot `fetch('file:///etc/passwd')`; the file URL handler will refuse the read because `/etc` is outside the granted scope.

CSP in `index.html` declares `default-src 'self'` plus `connect-src 'self'` plus an explicit allowlist of tile-server origins for `img-src`. The CSP is enforcement layered on top of the `WKContentRuleList`; either alone would be sufficient for the threat model, but cheap defense-in-depth is worth having.

### Why this isn't `WKWebView`'s default configuration

Several of the settings above (the navigation delegate, the link preview block, the back-forward gesture block) are not the WKWebView default. They exist because the WebView in GPXeditor is a single-page application surface controlled by us, not a general-purpose browser, and the defaults assume the latter. The project-wide rule (CONVENTIONS.md "Nothing fails silently") applies here too: every blocked navigation is logged with the URL it tried to reach, so a future bug that triggers an unexpected navigation surfaces immediately.

## Bridge architecture

### `MapBridge` (in `Services/MapBridge.swift`)

`MapBridge` is `@MainActor`-bound (WKWebView's APIs require main-actor) and owns three responsibilities:

1. **Inbound:** receive `WKScriptMessage` instances on the `gpxBridge` handler, decode the envelope, and hand the parsed message off to `MessageDispatcher`. Decoding failures, schema violations, and unknown message types are logged via `os_log` with the `MapBridge` subsystem and discarded — they never silently mutate state.

2. **Outbound:** serialize a `BridgeMessage` to JSON and call `webView.evaluateJavaScript("window.gpxEditor.handleMessage(...)")`. Errors returned from `evaluateJavaScript` are logged at warning level (a JS-side decode failure shouldn't crash the app) and surface as a bridge violation in the log.

3. **Lifecycle:** registered as the `WKScriptMessageHandler` on the WebView's user content controller for the `gpxBridge` handler name. `userContentController(_:didReceive:)` dispatches inbound messages.

`MapBridge` is the only file in `Services/` that imports `WebKit`. CONVENTIONS.md "The data and operations layers are platform-agnostic" carves out exactly this exception. Other `Services/` types (parsers, brushes, operations) must remain WebKit-free so a hypothetical future iOS port can lift them without modification.

### `MessageDispatcher` (in `Services/MessageDispatcher.swift`)

The dispatcher takes a typed `InboundMessage` enum and routes to an operation handler. It does not mutate state itself; it calls methods on `SessionViewModel` (M8 introduces this view model formally; for M2's `ready` and `log` messages, the dispatcher hands directly to lightweight handlers). The split between `MapBridge` and `MessageDispatcher` exists so the bridge plumbing (WebKit-bound) and the routing logic (pure Swift, easily unit-testable with synthesized messages) can evolve independently.

### Threading and re-entrancy

All bridge traffic is main-actor. Operations that may take measurable time (Pin to Ground in M7, reading a large session into JS at load time) farm work out to background tasks via `Task.detached` or actor methods, then post their results back to the main actor and out through the bridge. The bridge itself does not block on long-running work.

The `evaluateJavaScript` API is asynchronous; concurrent calls are serialized by WebKit internally. The dispatcher does not enforce its own ordering on outbound calls — Swift→JS messages arrive in dispatch order and are handled in receipt order by `editor.js`'s message queue.

## Message envelope shape

Every message in either direction has the form:

```json
{
  "type": "verb_in_snake_case",
  "id": "optional-uuid-for-correlation",
  "payload": { /* type-specific data */ }
}
```

This shape is defined project-wide in CONVENTIONS.md "JavaScript ↔ Swift bridge protocol." Three rules govern its use; all are absolute and enforced by both sides:

1. **`type` is snake_case.** The protocol is language-neutral on purpose — neither Swift's camelCase nor JS's camelCase wins. Snake_case avoids both.
2. **`id` is present only when correlation is needed.** Most messages are fire-and-forget; query-style messages that expect a response (e.g., `request_segment_stats`) carry an `id` (UUID string) that the response echoes back.
3. **Strict validation on receive.** An unknown `type`, a malformed payload, or a payload missing required fields is logged as a bridge violation and discarded. No silent state mutation. No "best-effort" partial application. No fallback to a default.

### Swift-side encoding

Inbound messages are decoded into a tagged-union `InboundMessage` enum where each case carries its own typed payload struct. `Codable` does the work; the `type` discriminator drives the `init(from:)` switch. Outbound messages are encoded the symmetric way — an `OutboundMessage` enum with typed payload structs encodes through `Encodable` to JSON, which `MapBridge` injects into the `evaluateJavaScript` call.

### JS-side encoding

`editor.js` defines a small `BridgeMessage` factory that produces well-formed envelopes and a single `handleMessage(message)` entry point that dispatches by `message.type`. Validation on the JS side mirrors Swift: an unknown `type` or a payload missing a required field is reported back to Swift via the `log` message at error severity, and the message is dropped.

### Coordinate and identifier conventions

These conventions apply to every payload that carries spatial or identity data; defining them once here keeps each message's schema concise.

- **Latitude / longitude** — `"lat"` and `"lon"` (lowercase short form). WGS84 decimal degrees. JSON `number`. Range `[-90, 90]` for `lat`, `[-180, 180]` for `lon`.
- **Elevation** — `"ele"`. Meters above the WGS84 ellipsoid. JSON `number` or `null` (omitted-from-source elevation is preserved as `null` rather than dropped).
- **Timestamp** — `"time"`. ISO 8601 with explicit `Z` UTC suffix, e.g. `"2024-09-15T14:32:01Z"`. JSON `string` or `null`. Matches GPX's own `xsd:dateTime` formatting.
- **Track identity** — `"track_id"`. UUID string in lowercase canonical 8-4-4-4-12 form.
- **Segment identity** — `"segment_id"`. Same UUID form.
- **TrackPoint identity** — `(track_id, segment_id, point_index)` triple. TrackPoints have no UUID of their own (see TrackPoint.swift's file header for why); their identity is positional within a segment, and the bridge speaks that identity directly.
- **Color** — `"color"`. `#RRGGBB` hex string with leading `#`. Matches the in-memory `HexColor` representation; D-013 keeps colors as hex strings for project-file portability.
- **Waypoint identity** — `"waypoint_id"`. UUID string.

## Message type catalog

The catalog covers M2 through M9. Each entry names the direction, gives the payload schema, and marks the milestone that introduces it. Adding a new message type is a code change plus an entry in this section; removing one is a code change plus a deprecation note that stays here for one release before the entry is deleted.

### Swift → JS

#### `load_session` (M2)
Sent once after JS reports `ready` (see Initialization sequence). Contains the full project state for initial render.

```json
{
  "type": "load_session",
  "payload": {
    "tracks": [
      {
        "track_id": "uuid",
        "name": "string",
        "role": "master" | "subsidiary" | null,
        "segments": [
          {
            "segment_id": "uuid",
            "color": "#RRGGBB",
            "points": [
              {"lat": <number>, "lon": <number>, "ele": <number|null>, "time": "<iso8601|null>"}
            ]
          }
        ],
        "waypoints": [
          {"waypoint_id": "uuid", "lat": <number>, "lon": <number>, "name": "string", "symbol": "string"}
        ]
      }
    ],
    "active_basemap_id": "string",
    "viewport": {"center_lat": <number>, "center_lon": <number>, "zoom": <number>} | null
  }
}
```

`viewport` is `null` on first load of a session that has no saved viewport; JS auto-zooms to fit the master track in that case. Per-point timestamps are preserved on the wire (the in-memory model still has them — D-012 only drops them on GPX *export*) so the Stats panel can compute speed and gradient from real timestamps when present.

#### `update_tracks` (M3)
Partial update sent after a Swift-side mutation. JS replaces the named tracks' rendering state and leaves untouched tracks alone.

```json
{
  "type": "update_tracks",
  "payload": {
    "tracks": [<same shape as load_session.tracks[*]>]
  }
}
```

The wire format is "replace these tracks entirely" rather than a finer-grained per-segment or per-point diff. The simpler shape is fast enough at the realistic scale of GPXeditor projects (a few tracks, thousands of points) and avoids a whole class of consistency bugs that diff protocols are heir to. Iteration to a finer diff is a future optimization if profiling shows a hot path here.

#### `set_basemap` (M2)
Switch the Leaflet tile layer. Sent when the user picks a basemap from the selector or when a session is loaded with a non-default `active_basemap_id`.

```json
{
  "type": "set_basemap",
  "payload": {
    "basemap_id": "string",
    "tile_url_template": "https://example.org/tiles/{z}/{x}/{y}.png",
    "attribution": "string",
    "max_zoom": <number>
  }
}
```

`tile_url_template` is sent on the wire even though `editor.js` could in principle hold the catalog itself, because keeping the catalog single-sourced in Swift (`BasemapCatalog`) and shipping the tile URL through the bridge means JS can't drift from Swift's notion of "what the user picked." Adding a basemap is a Swift-side change.

#### `render_brush_preview` (M4)
Show the transient overlay during a brush drag. Brush gestures originate in JS; this message is Swift's response when it has computed what the result of the in-progress stroke would look like.

```json
{
  "type": "render_brush_preview",
  "payload": {
    "brush_type": "simplify" | "smooth" | "average" | "add_detail",
    "preview_geometry": {
      "track_id": "uuid",
      "segment_id": "uuid",
      "previewed_points": [
        {"index": <number>, "lat": <number>, "lon": <number>}
      ],
      "added_points": [
        {"insertion_index": <number>, "lat": <number>, "lon": <number>}
      ],
      "removed_indices": [<number>]
    }
  }
}
```

The preview is purely visual — JS does not commit it to its rendering state. On commit (`apply_brush`), Swift sends the canonical `update_tracks` message; JS replaces the preview with the real result.

#### `clear_brush_preview` (M4)
Remove the transient overlay. Sent on commit (followed by `update_tracks`) or on cancel.

```json
{"type": "clear_brush_preview", "payload": {}}
```

#### `highlight_selection` (M3)
Visualize the canonical selection. Selection state lives in Swift; JS only renders what Swift tells it to render.

```json
{
  "type": "highlight_selection",
  "payload": {
    "selection": [
      {"track_id": "uuid", "segment_id": "uuid", "point_indices": [<number>]}
    ]
  }
}
```

An empty array clears the highlight.

#### `set_tool` (M3)
Notify JS that the active editing tool has changed. JS reads this to decide which gesture to attach to the next mouse drag — rectangle for `point` (marquee), free-form polygon for `lasso`. Added at M3 because the original directive's assumption that JS would infer the tool from gesture context was brittle (a user expects "the lasso tool draws a lasso every time"; gesture is the result, not the cause).

```json
{
  "type": "set_tool",
  "payload": {"tool": "point" | "lasso"}
}
```

JS clears any in-progress marquee or lasso state on receipt — half-finished gestures under the new tool would be confusing.

### JS → Swift

#### `ready` (M2)
Posted once by `editor.js` when the page is fully loaded, Leaflet has initialized, and the bridge dispatcher is wired. Triggers Swift's `load_session`.

```json
{"type": "ready", "payload": {"editor_version": "string"}}
```

`editor_version` is a build-time string from `editor.js` so a Swift/JS version mismatch (e.g., during a botched vendored-asset update) is visible in logs.

#### `points_selected` (M3)
Selection gesture committed in JS (marquee, lasso, click). Swift updates its canonical selection state and replies with `highlight_selection` to confirm the new state.

```json
{
  "type": "points_selected",
  "payload": {
    "modifier": "replace" | "add" | "subtract",
    "selection": [
      {"track_id": "uuid", "segment_id": "uuid", "point_indices": [<number>]}
    ]
  }
}
```

`modifier` describes how the new selection combines with the existing one (plain click is `replace`, shift-click is `add`, option-click is `subtract`). Swift owns the merge logic; JS only reports the gesture.

#### `delete_points` (M3)
Delete request from a gesture (the Delete key path goes through Swift menu handling, not the bridge; this message exists for click-driven deletes triggered inside the WebView).

```json
{
  "type": "delete_points",
  "payload": {
    "track_id": "uuid",
    "segment_id": "uuid",
    "point_indices": [<number>]
  }
}
```

#### `move_point` (M5)
Vertex drag committed.

```json
{
  "type": "move_point",
  "payload": {
    "track_id": "uuid",
    "segment_id": "uuid",
    "point_index": <number>,
    "lat": <number>,
    "lon": <number>
  }
}
```

The drag's intermediate frames are pure JS rendering and do not generate bridge traffic. Only the commit (mouseup) sends a message; Swift mutates the model and re-broadcasts `update_tracks`. This is the canonical pattern for direct-manipulation gestures: JS shows the user a fluent live preview, Swift owns the commit.

#### `add_point_on_line` (M5)
Click-on-line insertion.

```json
{
  "type": "add_point_on_line",
  "payload": {
    "track_id": "uuid",
    "segment_id": "uuid",
    "after_index": <number>,
    "lat": <number>,
    "lon": <number>
  }
}
```

`after_index` is the index of the point preceding the insertion. Inserting at the start of a segment uses `after_index: -1`.

#### `place_waypoint` (M8)
Waypoint Place tool gesture. The icon is chosen in the Swift-side icon picker; JS only reports where the click landed.

```json
{
  "type": "place_waypoint",
  "payload": {
    "lat": <number>,
    "lon": <number>,
    "track_id": "uuid"
  }
}
```

`track_id` is the track the waypoint should be associated with — typically the master, but the user may pick a different one in the inspector. (GPX places `<wpt>` at document level; project-internal track association is captured in Track.swift's data model.)

#### `apply_brush` (M4, extended through M9)
Brush stroke committed. The payload describes the stroke's geometry; Swift re-runs the brush operation against authoritative state to produce the canonical result.

```json
{
  "type": "apply_brush",
  "payload": {
    "brush_type": "simplify" | "smooth" | "average" | "add_detail",
    "track_id": "uuid",
    "stroke": {
      "kind": "region" | "path",
      "samples": [
        {"lat": <number>, "lon": <number>, "radius_meters": <number>}
      ]
    }
  }
}
```

The brush type's `kind` ("region" or "path") corresponds to D-015's two `BrushTool` specializations. Region brushes (Simplify, Smooth, Average) typically generate one sample per cursor position; path brushes (Add Detail) generate dense samples along the cursor path.

The "Swift re-runs the operation against authoritative state" rule matters for the Swift-as-source-of-truth invariant. JS's preview is computed against JS's local copy of the data, which lags Swift by however many `update_tracks` messages haven't been applied yet; if Swift trusted the preview's *result* it could commit a stale operation. By trusting only the *gesture* (the stroke geometry) and re-running, Swift's commit always reflects the authoritative state at the moment of commit.

#### `request_segment_stats` (M8)
Query-style message; correlates a response via `id`.

```json
{
  "type": "request_segment_stats",
  "id": "uuid",
  "payload": {"track_id": "uuid", "segment_id": "uuid"}
}
```

Swift replies with `segment_stats_result` (Swift→JS) carrying the same `id`. The Stats panel itself is a SwiftUI view, not a JS view; this message exists for the rare case where JS needs aggregate information for a hover tooltip or selection summary in the WebView.

#### `log` (M2)
Structured log message. Replaces `console.log` in shipped code per CONVENTIONS.md "console.log is not for production."

```json
{
  "type": "log",
  "payload": {
    "level": "debug" | "info" | "warning" | "error",
    "message": "string",
    "context": {<arbitrary diagnostic object>} | null
  }
}
```

Swift forwards the message to `os_log` with severity matching `level`. The `context` field is free-form JSON — it goes into the log line as the message's structured payload and surfaces in Console.app for diagnosis.

## Basemap selector

### UI control

A small toggle button in the map view's top-right corner opens a popover menu listing the available basemaps. The active basemap is shown with a checkmark. Picking a different basemap dispatches `set_basemap` to JS and updates the per-project `active_basemap_id`. The popover layout is a simple vertical list with the basemap's display name and a one-line attribution preview; no thumbnail in v1 (the Occam's Razor call — thumbnails would require pre-rendered tile images, an entire image pipeline, and offline storage for what is fundamentally a one-time selection per project).

### Catalog source of truth

`Services/BasemapCatalog.swift` defines the list as a static array of `Basemap` values. Each entry:

```swift
struct Basemap {
    let id: String                  // stable identifier, e.g. "osm-standard"
    let displayName: String         // user-visible, e.g. "OpenStreetMap"
    let tileURLTemplate: String     // e.g. "https://tile.openstreetmap.org/{z}/{x}/{y}.png"
    let attribution: String         // shown in the map view per OSM/etc. requirements
    let maxZoom: Int
    let allowedDomains: [String]    // contributes to NetworkAllowList / WKContentRuleList
}
```

Adding a basemap is a Swift-side change to this file plus an addition to SECURITY.md's network allow-list (the two are kept in sync because the rule list is rebuilt from `BasemapCatalog`'s `allowedDomains` at startup). Removing a basemap is the symmetric change.

The initial catalog mirrors the SECURITY.md "Allowed endpoints" list:
- OpenStreetMap Standard (`tile.openstreetmap.org`) — default
- OpenTopoMap (`tile.opentopomap.org`)
- USGS National Map (`basemap.nationalmap.gov`)
- Esri World Imagery (`server.arcgisonline.com`)
- CyclOSM (`*.tile-cyclosm.openstreetmap.fr`, `{s}`-rotation across `a` / `b` / `c`)

NOAA Charts was evaluated for inclusion at M2 and deferred to v2 — see HANDOFF.md's deferred parking lot for the rationale and re-evaluation triggers.

### Per-project persistence

`active_basemap_id` is part of `GPXSession` (M8 wires the corresponding setter; M2 hardcodes "osm-standard" until the session model exposes the field). Saved in the `.gpxeditor` JSON envelope per D-010. A global default for new projects is in Settings (M8 territory; M2 hardcodes the default to `"osm-standard"`).

### Rule list compilation

`ContentRuleListBuilder` produces a JSON string from `BasemapCatalog.allowedDomains` matching `WKContentRuleList`'s format, then calls `WKContentRuleListStore.default().compileContentRuleList(forIdentifier:encodedContentRuleList:)`. The compiled rule list is added to the WebView's user content controller before the initial load. Compilation happens once at app startup; the result is reused across all WebView instances (which currently means one — but a future split-view could open multiple).

The default rule (in `editor.js`-owned tile-layer code) is "load only allowed tiles." The rule list adds "block everything else originating from the WebView at the WebKit layer," which catches misbehavior that bypasses Leaflet's tile-layer abstraction (e.g., a vendored library that quietly hits a CDN). Both layers exist; either alone would be insufficient.

## Initialization sequence

The order of operations from app launch to "user can edit" matters because several setup steps depend on others having completed. Specified explicitly here so an implementation drift can be diagnosed against the expected sequence.

1. **App launches.** `GPXEditorApp.swift` boots SwiftUI; the user opens or creates a `.gpxeditor` document via `FileDocument`.
2. **`MapView` is constructed.** `makeNSView(context:)` runs.
3. **`MapBridge` is constructed.** Holds a weak reference back to `MapView` for its WebView.
4. **`WKWebViewConfiguration` is built.** User content controller created. `WKContentRuleList` (compiled at startup) added. `gpxBridge` script message handler registered with `MapBridge` as the handler.
5. **`WKWebView` is constructed.** Configuration applied. `navigationDelegate` set to the navigation guard.
6. **`loadFileURL(_:allowingReadAccessTo:)`** loads `WebResources/index.html` with read access scoped to `WebResources/`.
7. **`index.html` parses; CSP applies; vendored libraries load.** Leaflet and `simplify.js` are loaded via local `<script>` tags. CSP blocks anything else. `editor.js` loads last.
8. **`editor.js` initializes.** Creates the Leaflet map instance with the default basemap tile layer. Wires `window.gpxEditor.handleMessage` for incoming Swift→JS messages. Wires bridge gesture handlers but does not yet render anything (no session loaded).
9. **JS sends `ready`.** Posted via `window.webkit.messageHandlers.gpxBridge.postMessage(...)`.
10. **Swift receives `ready`.** `MapBridge` decodes; `MessageDispatcher` routes; the `SessionViewModel` (or, in M2, a temporary equivalent) responds by encoding the current `GPXSession` into a `load_session` payload.
11. **Swift sends `load_session`.** `MapBridge.evaluateJavaScript(...)` injects the message into JS.
12. **JS draws.** Polylines for each segment with the per-segment color and the contrasting halo (D-013 accessibility), waypoints with their icons, viewport set per `viewport` payload or auto-fit-to-master if `null`.
13. **User can edit.** Subsequent gesture-driven messages flow per the catalog above.

This sequence is the same on every load — fresh document, opened existing project, restored from autosave. The single deviation is that an empty document (no tracks yet) sends a `load_session` with `tracks: []` and JS does nothing visible until the first Import GPX.

## Bridge violations and logging

A *bridge violation* is any case where one side sends something the other side cannot validate: unknown `type`, missing required field, wrong shape. Both sides treat violations identically:

1. Log the violation (`os_log` on Swift; the `log` message at error severity from JS to Swift).
2. Discard the message; do not partially apply it.
3. Continue accepting subsequent messages.

The Swift log subsystem is `com.gpxeditor.app.MapBridge`; the category is `bridge`. Filtering Console.app to that subsystem during development surfaces every violation in one place.

A burst of violations indicates a real bug — typically a Swift/JS schema mismatch from a partial update, or a vendored-asset update that introduced unexpected behavior. Treat such bursts as "stop and diagnose," not "continue past."

## What does not go through the bridge

CONVENTIONS.md "What does not go through the bridge" applies. Static configuration that doesn't change after startup — color palette defaults, the curated waypoint icon set, the Leaflet library itself — is loaded by JS at startup from `WebResources/`. The bridge carries dynamic project state and gesture-driven operations only.

The `BasemapCatalog` straddles this line: the catalog's *contents* are static (compiled in), but the *active selection* is per-project state and is communicated via the bridge. Sending `set_basemap` with the URL template included keeps JS out of the catalog-knowledge business.

## Cross-references

- `DECISIONS.md` D-007 (app shell architecture: SwiftUI + WKWebView + Leaflet), D-008 (non-destructive session — informs `load_session` payload shape), D-013 (per-segment color storage, halo rendering rule), D-015 (brush family architecture — drives `apply_brush` and `render_brush_preview`)
- `CONVENTIONS.md` "JavaScript ↔ Swift bridge protocol", "Swift is the source of truth", "Nothing fails silently", "The data and operations layers are platform-agnostic" (the `MapBridge` carve-out)
- `SECURITY.md` "Network allow-list" (authoritative on which tile domains are permitted), "Vendored web assets" (CSP, hash-pinning), "Sandbox entitlements" (network client entitlement enabling tile fetches)
- `Docs/03_WEB_RESOURCES.md` Vendored asset rules and update protocol
- `Docs/04_EDITING.md` Tools and operations that use the bridge messages catalogued here
- `HANDOFF.md` Deferred parking lot (NOAA Charts deferred to v2; rationale and re-evaluation triggers there)
