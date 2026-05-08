# GPXeditor — Glossary

A learning reference for terminology used in this project's code, docs, and design discussions.  Built up over time as terms come up in conversation that would benefit from a clear definition.  Not exhaustive — terms get added when they earn their entry, not preemptively.

## How to read this

Each entry has two registers:

- **Plain-English summary.**  What the term means without assuming you already know the surrounding jargon.  Roughly:  what would you tell a smart friend who asks "wait, what's a coordinator?"
- **Technical detail.**  How it's expressed in this codebase — file paths, type names, related Apple-framework specifics — so you can move from understanding-the-concept to finding-the-code.

Cross-references to other entries are **bolded** so the doc reads as a connected mental model, not a list of isolated definitions.  The audience is anyone learning the project from the inside:  Scott six months from now, an external reader who clones the repo, future Claude sessions joining mid-project.

## Contents

1. [The bridge — JS ↔ Swift messaging](#the-bridge--js--swift-messaging)
2. [Apple frameworks](#apple-frameworks)
3. [The web side — JavaScript & Leaflet](#the-web-side--javascript--leaflet)
4. [GPX domain](#gpx-domain)
5. [Editing model](#editing-model)
6. [Elevation lookup (M7)](#elevation-lookup-m7)
7. [Window panes (M7.5)](#window-panes-m75)
8. [Architecture](#architecture)
9. [Distribution & security](#distribution--security)

---

## The bridge — JS ↔ Swift messaging

### Bridge

The plumbing that lets the two halves of the app talk to each other.

The Mac app is split in two.  The native macOS UI (windows, menus, file dialogs, undo/redo) is written in **Swift**.  The map view (basemap tiles, drawn track lines, mouse interactions) runs inside an embedded web browser — see **WKWebView** — and is written in JavaScript using the **Leaflet** library.  These two halves can't directly call each other's functions;  they communicate by passing JSON messages back and forth.

The bridge is everything that supports that:  the message format, the Swift code that reads incoming messages and sends outgoing ones, and the JavaScript code that does the same on its side.

Code:  `Services/MapBridge.swift`, `Services/MessageDispatcher.swift`, `Services/BridgeMessage.swift`, `Services/BridgePayloads.swift`, `WebResources/editor.js`.  Spec:  `Docs/02_MAP_AND_BRIDGE.md`.

### Message

One note passed across the **bridge**.  Has a `type` (what kind of message it is), an optional `id` (for matching responses to requests, rarely used in practice), and a **payload** (the actual data).

Example:  `{ "type": "move_point", "payload": { "track_id": "...", "point_index": 5, "lat": 45.0, "lon": -120.0 } }` — sent from JavaScript to Swift after the user drags a vertex on the map.

### Envelope

The outer shape of a **message** — the part that holds the type, id, and payload fields.  Like the envelope on a physical letter:  it tells you what kind of letter it is and where it's going, but the actual content (the **payload**) is sealed inside.

In code, the envelope is the JSON object `{ type, id?, payload }`.

Code:  `RawInboundMessage` in `Services/BridgeMessage.swift`.

### Payload

The data part of a **message**, inside the **envelope**.  Each message type has its own specific payload shape — some carry track IDs, some carry coordinates, some are empty.

Code:  `Services/BridgePayloads.swift` (one struct per payload type).

### Dispatcher

The piece of code that looks at an incoming **message**'s type and sends it to the right handler.  Like a mailroom clerk:  a `move_point` message goes to the move-point handler, an `apply_brush` message goes to the brush handler.  If the type is unknown or the payload is malformed, the dispatcher logs a "bridge violation" and discards the message rather than crashing.

Code:  `Services/MessageDispatcher.swift`.

### Inbound / Outbound

**Inbound** = JavaScript → Swift (e.g. user clicks something on the map, JS tells Swift).  **Outbound** = Swift → JavaScript (e.g. Swift updates the model, tells JS to re-render).

The bridge handles both directions, but the code is somewhat asymmetric:  inbound goes through Apple's **WKScriptMessageHandler** API, outbound goes through **evaluateJavaScript**.

### Wire format

How data looks when it's actually crossing the **bridge** — JSON, with `snake_case` keys (e.g. `track_id` not `trackId`).

Swift internally uses camelCase (`trackId`) and JavaScript also uses camelCase, but the wire format uses snake_case so neither language's convention dominates the protocol.  Encoders and decoders convert between the styles automatically at the bridge boundary.

### Round-trip

Encoding a value to the **wire format** and then decoding it back — and getting the same value out.  Used as a correctness check.  "The GPX parser/writer round-trips Garmin files cleanly" means parse a Garmin GPX, write it back, and the resulting file is structurally equivalent.

The M3 UUID-case bug was a round-trip bug:  Swift sent uppercase IDs to JavaScript, JavaScript stored them as lowercase, the response came back uppercase, and the lookup failed silently because the case didn't match.  See `HANDOFF.md`'s M3 outcome notes.

---

## Apple frameworks

### WKWebView

Apple's embedded web browser.  A `WKWebView` is a window into a self-contained web environment — JavaScript inside it runs in an isolated process with its own memory and its own DOM (web page tree).  The map view in this app is a `WKWebView` displaying a local HTML file with **Leaflet** inside.

`WK` stands for WebKit, the engine that powers Safari.

Code:  `Views/MapView.swift` constructs the `WKWebView`.

### WKScriptMessageHandler

The Apple-API plumbing that lets JavaScript inside a **WKWebView** call into the host Swift app.  JavaScript posts messages to a registered handler name (we use `gpxBridge`);  the Swift side receives them on a delegate method.

Code:  the `ScriptMessageHandlerProxy` private class in `Services/MapBridge.swift`.

### evaluateJavaScript

The Apple API that lets the host Swift app run a piece of JavaScript inside a **WKWebView**.  Used to send **outbound** messages — Swift composes a JS expression like `window.gpxEditor.handleMessage({...})` and asks WebKit to run it.

### NSViewRepresentable

The SwiftUI hook that lets you embed an AppKit view (the legacy macOS UI framework, still alive under the SwiftUI surface) inside a SwiftUI window.  **WKWebView** is an AppKit view, so to display it inside a SwiftUI window we wrap it in an `NSViewRepresentable`.

Code:  `Views/MapView.swift` is an `NSViewRepresentable`.

### Coordinator

A SwiftUI pattern for state that needs to outlive a view's render lifecycle.  SwiftUI views are descriptions that get re-created on every state change;  if you need an object that survives across re-renders and acts as a delegate for AppKit-style callbacks, you put it in a coordinator.

The map view's coordinator owns the **bridge**, holds the cached snapshot of last-rendered state (so re-renders only diff/send what changed), and acts as the WebView's navigation delegate.

Code:  the `Coordinator` nested class in `Views/MapView.swift`.

### @MainActor

A Swift concurrency annotation meaning "this code must run on the main thread."  UI code runs on the main thread because AppKit/SwiftUI APIs aren't thread-safe;  data-only code can run anywhere.

Most of this app's UI-touching code is `@MainActor`.  Pure data and operation code in `Models/` and `Services/` is platform-agnostic (per `CONVENTIONS.md`) — neither `@MainActor` nor any other actor isolation, so it can run on any thread.

### nonisolated

The opposite of **@MainActor** — code explicitly NOT bound to any actor.  Sometimes used on a method of a `@MainActor` class to satisfy a protocol whose method isn't main-actor-bound.

The recent fix in `MapView.swift` removed a `nonisolated` annotation from the navigation-delegate method that became wrong when Apple's SDK started requiring main-actor for `WKNavigationAction.request`.  See commit `a2eed55`.

### FileDocument

SwiftUI's native macOS document type.  By conforming our app's document to `FileDocument`, we get File→Open, File→Save As, drag-onto-dock, Finder file association, and undo/redo for free — Apple's framework handles the dialogs and routing.

Code:  `GPXEditorDocument` in the app.

### NSUndoManager

Apple's undo/redo registry.  Operations register themselves with it — "here's the prior state, here's how to restore it" — and the user gets ⌘Z and ⌘⇧Z behaviour automatically.

Each **operation** in `Services/` (Delete, Move, Reverse, Trim, etc.) snapshots the prior session before applying, then registers a closure with `NSUndoManager` that restores that snapshot.

### @Published

A SwiftUI property wrapper that makes a property observable:  when the property changes, any SwiftUI view watching it automatically re-renders.  Used heavily in `SessionViewModel` for state the UI depends on (selection, active tool, trim preview, etc.).

---

## The web side — JavaScript & Leaflet

### Leaflet

A small open-source JavaScript library for displaying tiled web maps.  Handles tile loading, panning, zooming, and provides primitives for drawing on top of the map (lines, markers, circles, popups).  The de-facto choice for embedded web maps when you don't need 3D or vector tiles.

Vendored at `WebResources/leaflet.js` + `WebResources/leaflet.css`.  See **vendored asset**.

### Tile server

A web server that hands out small image tiles (typically 256×256 PNG) for slices of the world at various zoom levels.  The map view requests tiles as the user pans and zooms;  the tile server returns the right tile for each (x, y, zoom) coordinate.

OpenStreetMap, OpenTopoMap, and the other **basemap** providers in this app are all tile servers.

### Basemap

The background map image — what you see under the colored track lines.  The user can switch between several basemaps in the basemap selector (OSM Standard, OpenTopoMap, USGS Topo, Esri Imagery, CyclOSM).

Code:  `Services/BasemapCatalog.swift`, `Components/BasemapSelectorView.swift`.

### Polyline

A line drawn on the map, typically connecting a sequence of (lat, lon) points.  Each track segment is rendered as one polyline (plus a halo polyline behind it for contrast — see D-013).

### CircleMarker

A small filled circle drawn at a (lat, lon) point on the map.  Used for selection markers, trim-preview red dots, and (eventually) always-visible track vertices.

### LayerGroup

A Leaflet container that holds multiple map layers and lets you show/hide or remove them as a unit.  Used for the trim-preview overlay (one layer group containing all the red **CircleMarker**s, removed wholesale when the dialog closes).

---

## GPX domain

### GPX

GPS Exchange Format.  An XML-based file format for GPS tracks, originally specified in 2002 and still the de-facto standard for hiking GPS data.  This app opens, edits, and saves GPX files.

The format has a small core (tracks, segments, points, waypoints) and many vendor extensions;  this app handles the core fully and ignores most extensions per the parser comments.

### Track / Segment / Track Point / Waypoint

The four pieces of GPX data:

- **Track** (`<trk>`):  a single recorded outing — one hike, one ride.  Has a name and zero or more segments.
- **Segment** (`<trkseg>`):  a continuous run of points within a track.  A track has multiple segments when the recording was paused and resumed.
- **Track point** (`<trkpt>`):  one (lat, lon, optional elevation, optional timestamp) reading from the GPS.
- **Waypoint** (`<wpt>`):  a named, placed point with a symbol (campsite, water, summit, etc.).  Independent of any track — waypoints stand on their own.

### Master / Subsidiary

A project-specific concept (D-016).  When working with multiple recordings of the same trail (you walked it three times to clean up GPS noise), one is tagged **master** — the canonical track that gets edited — and the others are tagged **subsidiary** — reference tracks the editing tools can read from but don't change.

The Average **brush** (M9) uses subsidiaries to figure out where the master "should" be:  for each master point, average the nearby subsidiary points and move the master toward that average.

---

## Editing model

### Selection

The set of currently-selected track points.  Window-scoped — per editor window, not saved to the project file (Photoshop equivalent:  the lasso state isn't saved with the .psd).  One Selection holds zero or more `(track_id, segment_id, point_index)` triples.

Code:  `Models/Selection.swift`.

### Operation

A pure function that transforms a session:  input `(session, parameters)`, output `(new_session, touched_tracks)`.  No side effects, no UI dependencies, fully unit-testable from the command line.  Examples:  DeleteOperation, MovePointOperation, ReverseTrackOperation, TrimTrackOperation, MergeTracksOperation.

The **ViewModel** layer wraps each operation with snapshot-and-undo bookkeeping;  the operation itself is platform-agnostic and lives under `Services/`.

### Touched tracks

The list of tracks an **operation** modified.  Returned by the operation so the **bridge** layer knows which tracks to re-broadcast to JavaScript via `update_tracks`.  Empty touched-list means "no-op" — the operation didn't actually change anything, and no undo entry should be registered.

### Brush

A **tool** that operates on multiple points along the user's drag path.  Two specializations (D-015):

- **Region brushes** (Simplify, Smooth, Average) operate on existing points within a circular region around the cursor as it sweeps.
- **Path brushes** (AddDetail) generate new points along the cursor path.

Each brush has its own algorithm for what to do with the points in its region or along its path.  Live preview during the drag;  commit on mouse-up.

### Tool

The currently-active editing mode.  Determines what mouse drags do — Point Tool:  marquee selection;  Lasso Tool:  free-form selection;  Brush tools:  brush strokes.  Single-key keyboard shortcuts to switch (V/L/1/2/3/4);  Escape always returns to Point Tool.

Code:  `Models/EditingTool.swift`.

---

## Elevation lookup (M7)

### DEM

**Digital Elevation Model.**  A grid of ground-elevation samples covering some part of the Earth — typically derived from satellite radar (SRTM, ASTER), aerial lidar (NED), or governmental survey data (EU-DEM, GMTED2010).  At any given lat/lon a DEM gives "what's the ground elevation here?"

This app uses DEM elevations to correct the often-noisy elevation values that GPS devices record.  A barometric or GPS-derived recording can be off by tens of meters;  the DEM is treated as ground truth for "what was the actual elevation at this point on the trail?"

### OpenTopoData

A free public web service (`api.opentopodata.org`) that wraps several DEMs behind a single HTTP API.  You send it a list of `(lat, lon)` points;  it returns elevations.  Used by this app's **Pin to Ground** and **Snap to Ground** features per D-020.

The public server has rate limits:  ≤1 request/second, ≤1000 requests/day.  This app honors both via its `ElevationService` actor.

### `mapzen` dataset

OpenTopoData's hosted blend of multiple underlying DEMs:  SRTM, ASTER, GMTED2010, NED, EU-DEM, and ETOPO1.  At any given location the blend picks the best-resolution source available (NED in the US, EU-DEM in Europe, ASTER at high latitudes, ETOPO1 fallback for ocean).  This is the dataset GPXeditor v1 uses for every elevation lookup, hardcoded per D-020.

### ElevationService

The Swift-side async client for OpenTopoData.  An actor (so the rate-limiter state is safe across concurrent calls) that:  builds and validates request URLs against `NetworkAllowList.swiftSideEndpoints`, throttles requests to honor the 1-req/sec gap, decodes JSON responses, retries once on 429 with the server-supplied Retry-After delay.  Per-batch fetch only — the caller drives batching via the static `makeBatches(of:)` so it can update progress UI between calls.

Code:  `Services/ElevationService.swift`.

### Pin to Ground

The **operation** that replaces multiple points' elevations with their DEM ground values in a single batch.  Selection-aware per CONVENTIONS.md:  if the user has a selection, Pin to Ground operates on it;  otherwise it operates on the master track if one is tagged.  Surfaces a confirmation-and-progress sheet (`Components/PinToGroundSheet.swift`) because the operation is rate-limited and slow — a 500-point pin takes ~5+ seconds.

Code:  `Services/PinToGroundOperation.swift` (the pure operation), `ViewModels/SessionViewModel.swift` (the request / commit plumbing), `Components/PinToGroundSheet.swift` (the sheet).

### Snap to Ground

The single-point version of **Pin to Ground**, available from the Point Tool's right-click context menu on any vertex.  Looks up that one point's DEM elevation and replaces it.  No sheet — one-point lookups are fast enough that a progress UI would be overkill;  errors surface as an NSAlert.

Wired in `ViewModels/SessionViewModel.applySnapToGround` and `Views/MapView.swift`'s vertex right-click menu.

### Properties of This Location

The empty-space right-click menu's informational item — looks up the DEM elevation at the clicked lat/lon and shows it in an NSAlert with the lat / lon / elevation values.  No model mutation;  it's purely a "what is this spot?" readout.

### NetworkAllowList

The single source-of-truth Swift type listing every host this app is permitted to reach.  Two consumers:  `ContentRuleListBuilder` compiles the tile-server list into a `WKContentRuleList` for the WebView;  `ElevationService` validates outbound URLSession requests against the Swift-side list.  Both are kept in sync because the rule list is rebuilt from this file at startup.

Code:  `Services/NetworkAllowList.swift`.

---

## Window panes (M7.5)

### Sidebar / Track list

The **left pane** of the document window — a list of every track in the project, with the track's name, point count, segment count, and a Master/Subsidiary badge if the track has a role.  Hideable via the toolbar's standard sidebar-toggle button (and the View menu's auto-generated Show/Hide Sidebar entry).

Click a row to select that track for the **Inspector**'s track-context mode.  Right-click a row for **Zoom to Fit**, **Select All Points**, or **Delete Track** — the same actions are also reachable from the **Track menu** in the menu bar.

Code:  `Views/Sidebar.swift`.

### Inspector

The **right pane** of the document window — a context-sensitive readout panel.  Hideable via the toolbar's inspector-toggle button.

Four modes, picked by what the user has currently selected:

- **Single point selected** — lat / lon / elevation / timestamp readout.  The primary surface for verifying that **Pin to Ground** / **Snap to Ground** changed elevations correctly.
- **Multi-point selection** — count + segment count.  The **elevation graph** below the map is the rich view for multi-point selections;  the inspector defers to it.
- **Track selected in the sidebar** — track name, point counts, role, recorded date.
- **Nothing selected** — basic project metadata (track count, basemap).

Read-only at M7.5;  edit fields land at M8.

Code:  `Views/Inspector.swift`.

### Elevation graph

A wide-and-short Swift Charts view overlaid at the **bottom of the map view**.  Slides into view when the selection is non-empty, slides out when the selection clears.

For non-contiguous selections (e.g., a marquee that catches both ends of an out-and-back trail), the graph renders each contiguous run as a separate **series** in Swift Charts — which doesn't connect lines between series, so the gaps appear naturally as visual breaks.  X-axis is cumulative haversine distance with fixed inter-run gaps so the runs separate visibly without dominating the chart.  Y-axis is elevation in meters.

Code:  `Components/ElevationGraph.swift`.

### Hover tooltip

A small DOM tooltip that floats near the cursor when it's within ~12 px of a track vertex on the map, showing that vertex's lat / lon and elevation.  Pure JS-side feature — no Swift bridge traffic per hover (would be too chatty);  the per-vertex data is stashed alongside the Leaflet layers when **`load_session`** / **`update_tracks`** lands.

Suppresses itself during any active gesture (vertex drag, marquee, lasso, brush, spacebar-pan) so it doesn't add visual noise during commit operations.

Code:  `WebResources/editor.js` (`createHoverTooltip` / `updateHoverTooltip` / `vertexHitTestForHover`).

### `zoom_to_bounds` (bridge message)

Swift→JS outbound message sent when the user invokes "Zoom to Fit" on a track in the **sidebar** (or — eventually — ⌘2 "Zoom to Selection" from the deferred parking lot).  Payload carries the lat/lon envelope (north / south / east / west);  JS calls Leaflet's `map.fitBounds` with 40 px padding so the requested region renders fully visible without kissing the viewport edges.

Driven from Swift via `SessionViewModel.zoomBoundsTrigger` — a one-shot trigger value that mints a fresh UUID per call, so two zooms to the same bounds re-fit instead of being deduped.

---

## Architecture

### Source of truth

The one place that's authoritative for some piece of state.  The architectural rule (`CONVENTIONS.md`) is that **Swift is the source of truth** for all model state — JavaScript only renders what Swift says.  If JavaScript and Swift disagree, JavaScript is wrong by definition and gets re-synced from Swift.

This is why the bridge is an asymmetric protocol:  edits originate from JS (the user clicks, drags), but the canonical state always lives in Swift, and the round-trip is "JS reports gesture → Swift mutates model → Swift broadcasts new state back to JS for redraw."

### View / Component / ViewModel

The SwiftUI layering:

- **ViewModel**:  the connective tissue between the data model and the UI.  Owns the session, the selection, the active tool.  Lives in `ViewModels/`.  SwiftUI views observe its **@Published** properties.
- **View**:  a top-level screen — `ContentView`, `MapView`, etc.  Lives in `Views/`.
- **Component**:  a reusable UI fragment smaller than a screen — `BasemapSelectorView`, `EditCoordinatesSheet`, `TrimTrackSheet`, `MergeTrackPickerSheet`.  Lives in `Components/`.

### Pure / value type

In Swift, **value types** (`struct`, `enum`) copy on assignment and have no identity;  **reference types** (`class`) share state and have identity.  The data model in this project (`Track`, `Segment`, `TrackPoint`, `Waypoint`, `GPXSession`, `Selection`) is all value types — mutations replace the whole value rather than mutating in place.  This makes operations easier to reason about ("here's the input, here's the output, no hidden state") and integrates cleanly with the snapshot-style undo pattern.

### Type-kind grouping

The folder layout convention this project uses:  top-level folders are organized by *type kind* (`Models/`, `Services/`, `ViewModels/`, `Views/`, `Components/`) rather than by *feature/subsystem*.  So the GPX-parsing code, the bridge code, and the editing operations all live under `Services/` even though they're separate subsystems.

The directive docs in `Docs/` describe each subsystem as a logical whole, naming the files and types involved across folders — that's where the per-subsystem narrative lives.

---

## Distribution & security

### Sandbox / Entitlement

The macOS App Sandbox restricts what an app is allowed to do at the OS level — which files it can read, which network calls it can make, which devices it can access.  **Entitlements** are individual capabilities a sandboxed app has been granted (read user-selected files, make outbound network connections, etc.).

This app's entitlements are documented in `SECURITY.md`.  The list is deliberately minimal:  sandbox + user-selected file read/write + outbound network, nothing else.

### Hardened Runtime

A second OS-level security layer (independent of the **sandbox**) that prevents code injection and dynamic library tampering.  Required for **notarization**.  This app has Hardened Runtime enabled with no exception entitlements in Release builds.

### Code signing

A cryptographic signature on the app bundle that says "this came from this developer, untampered with."  macOS uses signatures to decide whether to let an app run.

This project uses a self-signed certificate ("Lab Code Cert," D-019) for development and will use a Developer ID Application certificate for distribution at M10.  See `SECURITY.md` and `Docs/self-signed-cert-for-development.md`.

### Notarization

Apple's malware-scan service for distributable apps.  After signing with a Developer ID certificate, you submit the app to Apple, they scan it, and they return a "notarization ticket" you staple to the app.  Notarized apps run on any Mac without scary Gatekeeper warnings ("this app is from an unidentified developer").

Required for direct distribution (which is what this project does — see D-005 for why direct, not Mac App Store).

### Vendored asset

Third-party code (libraries, CSS, etc.) that's committed to the repository as files rather than fetched from a CDN at runtime.  **Leaflet** and `simplify.js` are vendored in `WebResources/`.

The opposite would be `<script src="https://unpkg.com/leaflet@1.9.4/...">` in the HTML, which fetches from a CDN every time the app launches.  Vendoring trades the convenience of CDN updates for reproducibility (the build is the same on every machine), security (a CDN compromise can't affect us), and offline capability (the app works without internet).

### Hash-pinning

Recording the SHA-256 hash of every **vendored asset**.  A pre-commit hook (or CI step) recomputes the hashes and compares against the recorded values;  any divergence is either a deliberate update (and the hash file is updated in the same commit, with a clear commit message naming the upstream version) or a tampering signal that the change shouldn't merge.

Recorded in `WEB_RESOURCES_HASHES.txt` at the repo root.  See `SECURITY.md` for the full update protocol.

---

## Update protocol for this document

This glossary is built up over time, not pre-populated.  Entries are added when a term comes up in conversation that would benefit from a clear definition.  Existing entries get sharpened when a session catches one being unclear or out-of-date.

When adding an entry:

- Lead with the plain-English summary — one or two sentences a non-specialist could follow.
- Add technical detail in a second paragraph — Apple-framework specifics, file paths, type names.
- Cross-reference related entries in **bold** so the doc reads as a connected mental model.
- Add to the right section's order, and update the Contents list if a new section appears.

This document changes in place;  git history preserves the change log.
