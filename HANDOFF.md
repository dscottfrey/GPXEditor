# GPXeditor — Handoff

This is the rolling state-of-the-project document. Unlike DECISIONS.md (append-only history) and CONVENTIONS.md (current-state code rules), this file changes as work progresses — milestones get checked off, new questions surface, and deferred items either get pulled in or stay parked. Read this at the start of every session to know where the project actually is right now, and update it before ending a session that completed meaningful work.

If you are starting a new session and reading this for the first time, also read in this order: `CLAUDE.md` (project orientation), `SECURITY.md` (sandbox and trust posture), `DECISIONS.md` (architectural choices), `CONVENTIONS.md` (code patterns). The relevant `Docs/0X_*.md` for whatever subsystem you're about to touch comes after that.

## Current status

**Phase:** M2 complete (2026-05-05).  Ready to begin M3.

M2 deliverables shipped and visually verified:  tile rendering works on every catalog basemap, the basemap selector switches cleanly between them, the WKContentRuleList enforces the allow-list, tracks render as polylines on top of tiles, Web Inspector is reachable in Debug builds.  `xcodebuild test` passes (58 tests, no regressions) and `xcodebuild build` produces a signed .app with the vendored web assets in `Contents/Resources/`:

- **Vendored web assets** in `GPXEditor/WebResources/`:  Leaflet 1.9.4 (`leaflet.js` + `leaflet.css` from unpkg), simplify-js v1.2.4 (from GitHub), plus project-authored `index.html`, `editor.js`, `editor.css`.
- **Hash-pinning** at the repository root in `WEB_RESOURCES_HASHES.txt`.  Verifiable from a clean checkout via `shasum -a 256 -c WEB_RESOURCES_HASHES.txt`.
- **`BasemapCatalog`** (`Services/BasemapCatalog.swift`) — five entries:  OpenStreetMap (default), OpenTopoMap, USGS Topo, Esri Imagery, CyclOSM.  Wire IDs (`osm`, `opentopo`, `usgs`, `esri-imagery`, `cyclosm`) match `GPXSession.selectedBasemapId`'s persistence contract.
- **`NetworkAllowList`** (`Services/NetworkAllowList.swift`) — single-source-of-truth domain list for `WKContentRuleList` and the M7 elevation service.
- **`ContentRuleListBuilder`** (`Services/ContentRuleListBuilder.swift`) — compiles a `WKContentRuleList` from `BasemapCatalog`'s aggregated host list at app startup, applied to the WebView before `index.html` loads.
- **JS↔Swift bridge** (`Services/MapBridge.swift`, `Services/MessageDispatcher.swift`, `Services/BridgeMessage.swift`, `Services/BridgePayloads.swift`):  envelope parser, dispatcher, typed payloads.  M2 active types — Swift→JS `load_session` and `set_basemap`;  JS→Swift `ready` and `log`.  Future-milestone types stubbed in the dispatcher with warning logs so stray early messages surface visibly.
- **`MapView`** (`Views/MapView.swift`) — `NSViewRepresentable` wrapping `WKWebView` with the full Docs/02 configuration (no back-forward, no link preview, identifying User-Agent, navigation guard, Debug-only developer extras).  Coordinator owns the bridge, defers outbound messages until JS reports `ready`, then sends `set_basemap` and `load_session`.
- **`BasemapSelectorView`** (`Components/BasemapSelectorView.swift`) — popover-style picker, live attribution preview per row, persists selection through the document binding.
- **`ContentView`** updated — MapView is now the entire window contents with the basemap selector overlaid top-right.
- **No regressions** in M1 tests.  The 58 existing tests pass unchanged.

Two project-wide infrastructure improvements landed alongside M1, each documented as a reusable best-practice procedure under `Docs/`:

- **Build-identifier retrofit** (`Docs/build-identifier-retrofit.md`).  Every build embeds a timestamp + short git SHA + dirty marker, surfaced in the About panel for unambiguous bug-report identification.
- **Self-signed development certificate** (`Docs/self-signed-cert-for-development.md`, D-019).  Replaces Xcode's free Personal Team automatic signing with a 10-year-validity self-signed cert ("Lab Code Cert"), escaping the periodic certificate-revocation churn that silently breaks builds.  Library validation is relaxed in Debug only via a separate `GPXEditor.Debug.entitlements` file; Release retains the strict production posture.

**Next action:** Begin **M3 — Selection and delete**.  Bridge messages to land:  Swift→JS `update_tracks` (so a Swift-originated edit shows up immediately, fixing the M2 limitation that imports require document close/reopen) and `highlight_selection`;  JS→Swift `points_selected` and `delete_points`.  The directive doc `Docs/02_MAP_AND_BRIDGE.md` already specifies the schemas;  M3 wires the handlers and the Point Tool's marquee + dedicated Lasso Tool gestures in `editor.js`, plus the Swift-side selection model and the `DeleteOperation` registered with NSUndoManager.

**M2 deviations and follow-ups (none blocking M3):**
- **WKContentRuleList `if-domain` vs `url-filter` gotcha** — the first cut of `ContentRuleListBuilder` used `if-domain` for allow rules, which filters by the **page's** domain (file://) rather than the **resource's** domain (https://tile.openstreetmap.org).  Result:  every tile fetch was silently blocked, tiles rendered grey.  Fixed mid-M2 by switching the allow rules to `url-filter` regex on the resource URL.  The lesson is documented in `ContentRuleListBuilder.swift`'s comments — content-blocker format's domain-filter fields are page-scoped, not resource-scoped.
- **Warnings in build output:**  three main-actor-isolation warnings in `MapBridge.swift` and `MapView.swift` (the `MessageDispatcher.init()` default argument and a `WKNavigationAction.request` access from a nonisolated delegate).  Functional and harmless under macOS 14's WebKit, but worth cleaning up when the bridge gets touched again at M3 — either explicitly `@MainActor`-annotate the dispatcher or supply the dispatcher non-defaulted from the call site.
- **Build phase warning:**  Xcode flags `Info.plist` in Copy Bundle Resources;  pre-existing from M0, not introduced at M2.  Cosmetic noise, no behavior impact.

**Blockers, if any:** None for M2–M9. M10 is gated on the Apple Developer Program membership becoming active and the Developer ID Application certificate being installed in the developer's keychain. See "Open inputs" below for the current state of the cert progress.

## Milestone roadmap

Each milestone produces a working, runnable, testable state. Build them in order. Within a milestone, the implementation work is described at a high level here; the per-subsystem `Docs/0X_*.md` directives carry the detailed specifications for code shape, types, and behavior.

### M0 — Project skeleton — **Completed 2026-05-03**

Create the Xcode project as a SwiftUI macOS app, minimum deployment macOS 14, bundle identifier `com.gpxeditor.app`, display name "GPXeditor". Set up the type-kind folder layout (`Models/`, `Services/`, `ViewModels/`, `Views/`, `Components/`, `WebResources/`, `Resources/`) and create the parallel test folders. Enable App Sandbox and Hardened Runtime in the entitlements file with the minimum capability set documented in SECURITY.md (sandbox + user-selected files read/read-write + network client, nothing else). Sign with the Personal Team identity (free Apple ID provisioning) — see SECURITY.md "Development-time signing" for context. Add a placeholder app icon and a placeholder ContentView showing the project name. Verify: app launches, appears in the dock, runs sandboxed (visible in Activity Monitor's process inspector), no console errors.

This milestone produces the empty shell everything else builds onto. A working `git commit` at this point should produce a buildable, runnable, sandboxed app with no functionality.

**M0 outcome notes (deviations and follow-ups):**

- **`com.apple.security.get-task-allow` is auto-injected by Xcode for Debug-signed builds** so the debugger can attach. It is stripped automatically from Release / notarization-bound builds. Universal across macOS dev projects. Not in `SECURITY.md`'s entitlement list because that doc lists what we *grant* (feature capabilities); `get-task-allow` is a tooling artifact at signing time. A reader running `codesign -d --entitlements -` on a Debug build will see five entitlements where SECURITY.md lists four. If a clarifying paragraph in SECURITY.md becomes desirable, add it under "Sandbox entitlements".
- **Empty type-kind folders are not preserved across a fresh clone.** Xcode 16's `PBXFileSystemSynchronizedRootGroup` treats `.gitkeep`-style placeholder files as bundle resources and tries to copy each into `Contents/Resources/` — they collide on filename and break the build. Rather than add `PBXFileSystemSynchronizedBuildFileExceptionSet` membership exceptions to filter them out, the `.gitkeep` files were dropped. Empty folders (`Models/`, `Services/`, `ViewModels/`, `Components/`, `WebResources/`) therefore won't survive a fresh clone — they get recreated when their first real file is added (M1 populates `Models/` and `Services/` immediately, M2 populates `WebResources/`, M5 `Components/`, M8 `ViewModels/`). Folder structure is canonical-documented in CLAUDE.md so the loss is purely cosmetic.

### M1 — GPX I/O and project file format — **Completed 2026-05-04**

Implement the data model in `Models/`: `GPXSession`, `Track`, `Segment`, `TrackPoint`, `Waypoint`, project metadata types, master/subsidiary role enum, hex color storage. Implement `GPXParser` and `GPXWriter` in `Services/` using stdlib `XMLParser` (no third-party GPX library — see D-007). Implement the `.gpxeditor` JSON project file format encode/decode in `Services/`. Wire up SwiftUI's `FileDocument` for the `.gpxeditor` content type so File→Open, File→Save, File→Save As work via standard menus and dialogs. Implement an Import GPX action that reads a `.gpx` file via `NSOpenPanel`, parses it, and adds it to the current session as a new track with its original bytes preserved (D-008). Implement Reset to Original per track.

Tests in `GPXEditorTests/Services/`: round-trip a half-dozen real-world GPX files (Garmin, Strava, hand-edited) through parser and writer; assert that re-parsing the output produces an equivalent model.

Verify: New empty project, Import a real GPX, Save, Close, Reopen, see the same state. Export the original GPX (round-trip preservation check).

**M1 outcome notes (deviations and follow-ups):**

- **Real-world fixtures deferred.** M1 ships with 14 synthetic Null-Island-anchored fixtures only (covering GPX 1.0 / 1.1, multi-segment, missing fields, degenerate counts, waypoints, vendor extensions, fractional timestamps, plus six failure-case fixtures — one per `GPXParseError` case).  Real Garmin / Strava / hand-edited recordings remain on Open Inputs #2 and would add coverage for genuinely-encountered-in-the-wild quirks (vendor-prefixed namespaces in unusual positions, encoding edge cases, extension-block variations beyond the canonical Garmin TrackPointExtension shape) — but the synthetic set covers all the parser failure modes and structural variants explicitly tested.  Add real fixtures opportunistically as Scott captures them; nothing in subsequent milestones is blocked.
- **Reset to Original UI not wired in.** The model-level `TrackImporter.resetTrackToOriginal(_:paletteOffset:)` operation is implemented and tested, but Reset is per-track and the proper UI affordance is the sidebar's per-track right-click menu (D-014, `Docs/04_EDITING.md`).  The sidebar lands at M8.  M8 wires the menu / contextual-menu to call into the M1 operation; nothing more is needed at the model layer.
- **GPX 1.0 metadata extended from M1's design pass.** The parser's `<name>` and `<time>` switch arms accept parent `<gpx>` (the GPX 1.0 placement of file-level metadata) in addition to parent `<metadata>` (the GPX 1.1 placement).  Originally the design assumed 1.1-only metadata routing; the gap was closed during fixture-#2 work after a domain-knowledge consult with the user.
- **`ContentView` is still the M0 placeholder** showing only the project name + track count.  This is deliberate:  the real editing UI is M5 (Point Tool single-point operations) and M8 (sidebar / inspector / stats).  At M1 the track count display is the simplest correctness signal that opening / creating / saving documents works end-to-end.
- **Document-Open vs. Import GPX UX is confusing — needs rework before public release.**  Observed during M1 verification:  SwiftUI's launch-time document Open dialog filters to `.gpxeditor` only (correct per `FileDocument.readableContentTypes`), so `.gpx` files appear greyed-out in that dialog.  A user landing there naturally tries to open a `.gpx` file and gets stuck.  The actual workflow is two-step:  click **New Document** → use **File → Import GPX…** (Cmd-Shift-I).  This is architecturally right per D-008 (`.gpx` is a source format, `.gpxeditor` is the document) but the UX undersells it badly — there's no on-screen indication that Import is the path forward.  Options for fixing (defer the design choice until the editing UI is in place):  extend the launch dialog to accept `.gpx` files and auto-create a new project containing them; add a drag-onto-dock handler for `.gpx`; show first-launch inline guidance in an empty document window; supply an empty-state hint in `ContentView` itself ("Import a GPX file to get started").  Pick one before the public flip (M10) — the current behavior is too rough for first-time users.

### M2 — Map view and basemap selector — **Completed 2026-05-05**

Vendored Leaflet 1.9.4 (`leaflet.js` + `leaflet.css` from unpkg) and simplify-js v1.2.4 (from GitHub) into `WebResources/`, with `WEB_RESOURCES_HASHES.txt` at the repository root pinning all three.  Project-authored `index.html` (CSP-locked, declared `default-src 'self'` plus an explicit tile-server `img-src` allow-list), `editor.js` (bridge dispatcher, Leaflet glue, M2-active handlers for `load_session`/`set_basemap`/`ready`/`log` plus stubs that warn for the M3-M9 future types), and `editor.css` (track-halo styling for the D-013 contrast requirement).  Five-entry curated `BasemapCatalog` (OSM Standard / OpenTopoMap / USGS Topo / Esri Imagery / CyclOSM);  NOAA Charts evaluated and deferred to v2 because no XYZ endpoint is published.  `NetworkAllowList` as the single domain source-of-truth feeding `ContentRuleListBuilder` (which compiles a `WKContentRuleList` of url-filter regexes — `if-domain` was tried first and produced grey-tile-only output because that field filters by page domain, not resource domain).  `MapBridge` + `MessageDispatcher` + `BridgeMessage` + `BridgePayloads` form the bridge layer;  `MapView` is the `NSViewRepresentable` with the full Docs/02 configuration including identifying User-Agent, Debug-only developer extras, and the navigation guard.  `BasemapSelectorView` is a SwiftUI overlay with a popover-style picker that persists selection through the document binding.

Visually verified end-to-end:  tiles render on every basemap, basemap switching works, tracks render as polylines, Web Inspector is reachable in Debug, no console errors after the rule-list fix.  58 M1 tests still pass.

**M2 outcome notes (deviations and follow-ups):**

- **`update_tracks` not yet wired** — a Swift-originated track edit (Import GPX during a session) doesn't render until the document is closed and reopened.  Architecturally trivial to fix at M3 alongside the selection-and-delete work;  not blocking.
- **Two main-actor-isolation warnings** in `MapBridge.swift:53` and `MapView.swift:314` — the dispatcher's `init()` default-argument and `WKNavigationAction.request` access from a nonisolated delegate.  Functional but worth clean-up when the bridge gets touched again.
- **Pre-existing Info.plist build-phase warning** carried forward from M0;  cosmetic, no behavior impact.
- **No track-list UI surface until M8 — feels rougher than expected during use** (Scott's feedback during M2 verification, 2026-05-05).  Two compounding gaps:  (a) imports during a session don't render until close/reopen (M2 limitation above), and (b) once they do render, the auto-fit-to-all-tracks behavior zooms the viewport to cover whatever extreme-coordinate spread the project contains, making each individual track a barely-visible dot;  with no sidebar there's no surface to navigate to a specific track.  Workaround for now:  `⌘S` after each import to make sure the project file is saved, close the document, reopen — the fresh `load_session` includes every imported track.  Real fixes both come into the roadmap at named milestones — `update_tracks` at M3, sidebar with double-click-to-center at M8 — but the combination is unfriendly enough that pulling a minimal track-list-only sidebar forward (as a small M3 add-on) is worth weighing if M3-M7 work feels blocked by track navigation in practice.  Not a roadmap change yet;  flagging the option so the tradeoff is visible.

### M3 — Selection and delete

Implement the Point Tool's marquee selection (drag in empty space) and the dedicated Lasso Tool. Selection state lives in JavaScript during the gesture; on commit, JS posts a `points_selected` message with the affected track and point indices to Swift. Swift maintains the canonical selection state. Implement Delete operating on the current selection (a single operation in `Services/`, registered with `NSUndoManager`). Implement keyboard shortcuts: ⌘A select all, ⇧⌘A deselect all, Delete deletes selection, ⌘E selects entire segment, ⌘2 zooms to selection.

Verify: Open a noisy track, marquee a rest-stop cluster, hit Delete, ⌘Z restores it, lasso an irregularly-shaped cluster, Delete again. Click a segment in the sidebar (next milestone provides the sidebar; for now select-segment lives in the right-click menu) and confirm all its points highlight on the map.

### M4 — Simplify brush

Implement the `BrushTool` protocol and `RegionBrushTool` specialization in `Services/`. Implement `SimplifyBrush` as the first concrete brush — RDP simplification applied to the points in the brush region. Brush gesture handling in JS posts brush-stroke messages to Swift; Swift applies the operation and pushes the result back. Live preview during the drag shows the simplified path; release commits as one undo unit. Brush radius is fixed at the v1 default — no slider yet (D-016).

Verify: brush over a noisy section, see the simplified result, undo restores the original. Aggressive brushing reduces a 5,000-point track substantially while preserving its shape.

### M5 — Point Tool single-point operations

Implement the full Point Tool behavior set: vertex draggability (drag a point to move it), click-on-line to insert a new point at the click location, right-click context menu on a point (Delete, Edit Coordinates, Snap to Ground, Promote to Waypoint, Set as Segment Boundary, Select Entire Segment), right-click context menu in empty space (Place Waypoint Here, Properties of This Location). Implement the bridge messages and Swift-side operations for each. NSUndoManager registers each operation with a meaningful action name.

This is the milestone where the Adze tedium is concretely fixed — single-point operations all work without leaving the Point Tool.

Verify: Drag a point to a new location, save, reopen, point is in the new location. Click on a line between two points to add a new point, drag it where you want. Right-click a point and use each context-menu item.

### M6 — Track operations: split, merge, reverse, time-trim

Implement track-level operations in `Services/`: split-at-selected-point, merge-second-track-into-this-one (with confirmation dialog), reverse-direction. Implement the Trim Track dialog (D-018) with two optional time-based trim sections, live preview overlay, OK commits as one undo unit. All operations honor the selection-aware-operations rule.

Verify: each operation produces correct results that round-trip through Save/Reopen and Export.

### M7 — Pin to Ground (DEM elevation correction)

Implement `ElevationService` in `Services/` — a client for the OpenTopoData API. Batch coordinates into chunks (OpenTopoData's API has a 100-point-per-request limit), parallelize gently, handle rate-limiting and errors gracefully. Add `api.opentopodata.org` to the network allow-list (it's already in SECURITY.md as the elevation API; verify the URLSession-wrapper enforcement works). Implement Pin to Ground as an operation that runs on the current selection or, if no selection, on the entire master track, with a confirmation dialog and a progress indicator. Per-point Snap to Ground (D-014, available from the Point Tool's right-click menu) uses the same service for one-point requests.

Verify: a track with bogus barometric elevations gets corrected to DEM ground values. Offline behavior fails gracefully with a clear error.

### M8 — Sidebar, inspector, stats panel, waypoints

Implement the Sidebar in `Views/` showing the project structure: tracks (master tagged), each expanding to its segments, each segment expanding to its waypoints. **Single-click** on a track or segment in the sidebar selects all its points. **Double-click** on a track centers the map on that track and zooms to fit its bounds (the natural answer to "I imported a track and can't tell where it is" — without this, far-apart imports auto-fit to a viewport so wide that each individual track becomes a tiny dot).  Implement the Inspector in `Views/` showing per-point data (lat/lon/elevation/timestamp) for the currently-selected point with editable fields. Implement the Stats panel showing total distance, gain/loss, average and max speed (when timestamps are available), and gradient histogram. Implement the Waypoint Place tool (W keyboard shortcut) and the icon-picker popover with the curated icon set (~15 hiking/outdoor symbols using Garmin `<sym>` names, rendered via SF Symbols where available).

Verify: sidebar shows tracks, expanding shows segments, single-click selects all points, double-click centers and zooms to fit. Inspector shows point data, editing a value propagates to the model and re-renders the map. Stats panel matches a known reference (compare to another GPX viewer for the same file). Place a waypoint, change its icon, save, reopen, verify it's preserved.

### M9 — Smooth, Average, Add Detail brushes

Implement the remaining brushes. `SmoothBrush` (RegionBrushTool variant): for each point in the brush region, average it with its neighbors using a smoothing kernel. `AverageBrush` (RegionBrushTool variant): for each master point in the brush region, find subsidiary points within radius and move the master toward their uniform average (D-016). `AddDetailBrush` (PathBrushTool variant): generate new points along the cursor path at a configurable density, inserting them into the current track between the gesture's start and end points.

Implement master/subsidiary tagging in the sidebar — mark a track as master (only one at a time), mark or unmark a track as subsidiary. The Average brush requires at least one subsidiary tagged before it can produce meaningful results; if no subsidiaries are present, the brush surfaces a clear message ("No subsidiary tracks tagged").

Verify: load a track with multiple passes of the same trail, tag one as master and the others as subsidiary, brush across an overlap section with the Average brush, see the master converge toward the geometric center. Smooth brush over a jittery section produces a cleaner path. Add Detail brush fills in a gap with new points along the cursor path.

### M10 — KML export, polish, sign, notarize, ship

Implement the KML writer in `Services/` (smaller scope than GPX — track lines and waypoints only). Final app icon. Bundle version 1.0. Switch the signing identity in Xcode from Personal Team to Developer ID Application (requires the paid certificate to be installed). Create the build pipeline for a notarized DMG: `xcodebuild archive` → `codesign` verification → `xcrun notarytool submit --wait` → `xcrun stapler staple` → DMG creation. Write the public-facing `README.md`, `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, and GitHub issue templates. Run the pre-public-release fixture audit (see checklist below). Tag a `v1.0` release on GitHub, attach the notarized DMG to a GitHub Releases entry, flip the repository to public.

Verify: clean checkout produces a notarized DMG. The DMG opens on a fresh Mac, the .app installs, runs without Gatekeeper warnings, performs all features end-to-end.

## Open inputs

Things still pending from the user, in roughly priority order:

**1. Apple Developer Program membership.** In progress; weeks away per the user. Blocks only M10 (signing/notarization/distribution). All earlier milestones use the free Personal Team for local development. Update this entry with the date the certificate becomes active and is installed in the keychain.

**2. Real GPX samples for `GPXEditorTests/Fixtures/`.** M1 shipped with 14 synthetic Null-Island fixtures only.  Real-world recordings would add coverage for in-the-wild quirks (Garmin extension variations, Strava-specific behaviors, namespace declarations in unusual positions, encoding edge cases) and are useful for the editing features starting at M3 — at least one "messy" example with rest-stop clusters and elevation noise is the canonical test input for spike detection (M-future).  Public-trail recordings are fine during the private-repo phase (D-005); naming convention is `garmin-<descriptor>.gpx`, `strava-<descriptor>.gpx`, etc., per `Docs/06_FIXTURES.md`.  Update this entry with the file paths added and a one-line description of each.  Not blocking any milestone — add opportunistically.

**3. M2 verification: NOAA Charts tile endpoint.** **Resolved 2026-05-05 — deferred to v2.** Researched NOAA's published chart services (`tileservice.charts.noaa.gov`, `nauticalcharts.noaa.gov/data/gis-data-and-services.html`); NOAA publishes ESRI REST MapServer, WMS, WMTS, and MBTiles formats only — no XYZ/TMS endpoint. WMTS could in principle be coerced into a fixed XYZ-shaped template with hard-coded matrix-set parameters, but the integration would add either a Leaflet plugin dependency or a custom `L.TileLayer` subclass, which fails the original "include if clean, defer if awkward" criterion. NOAA Charts is moved to the deferred parking lot below; SECURITY.md's allow-list no longer references the NOAA domain.

**4. M2 verification: CyclOSM mirror selection.** **Resolved 2026-05-05 — single OSM-France mirror selected.** Published URL template is `https://{s}.tile-cyclosm.openstreetmap.fr/cyclosm/{z}/{x}/{y}.png` with the standard Leaflet `{s}` rotation across `a` / `b` / `c`. Hosted by OSM-France, governed by the OpenStreetMap Foundation tile usage policy. Attribution string baked into `BasemapCatalog`: `© OpenStreetMap contributors, CyclOSM & OSM-FR`. The OSM-France subdomain rotation provides load distribution, so a second independently-hosted mirror was considered (Champs-Libres' Belgium DEM-quality server) and rejected as regional-scope and unnecessary for a generally-useful basemap. The research surfaced a project-wide `User-Agent` requirement now documented in SECURITY.md.

**5. App icon design.** Placeholder is fine through M9. Before M10 ships a public release, a real app icon is needed. The icon doesn't need to be elaborate — a simple stylized track-on-map glyph in colorblind-safe colors (matching the project's accessibility principle in CONVENTIONS.md) is sufficient. Update this entry with the icon source files and the date they were imported.

## Pre-public-release checklist

Per D-005, the repository stays private until *all* of the following are checked off. The flip to public happens after the last item is verified, not gradually as items complete.

- [ ] **Developer ID Application certificate active** and installed in the developer's keychain.
- [ ] **Signed and notarized DMG buildable from a clean checkout** of the repository on a development machine, end-to-end without manual intervention beyond starting the build.
- [ ] **Test fixture audit complete.** Every track committed under `GPXEditorTests/Fixtures/` is verified to be either synthetic or from a clearly public location. Tracks revealing home, work, or routine personal routes have been removed.
- [ ] **`README.md` written.** Audience: human GitHub visitors. Contents: what the app does, screenshot or two, installation instructions (download notarized DMG from Releases), build-from-source instructions (clone, open in Xcode, build), license, credits to upstream projects (Leaflet, OpenStreetMap, OpenTopoData, simplify.js, plus any others added by then).
- [ ] **`LICENSE` file at repository root** with the standard MIT text and Scott Frey's copyright (D-002).
- [ ] **`CONTRIBUTING.md` written.** Brief — how to file issues, how to propose changes, what's in scope and what's not, the SPM dependency-discipline policy from D-007.
- [ ] **`CODE_OF_CONDUCT.md` written.** Standard short policy is sufficient (Contributor Covenant or similar).
- [ ] **GitHub issue templates created** for bug reports and feature requests.
- [ ] **`.gitignore` correct** — covers `*.gpx` at the root by default with explicit allow-listing for `GPXEditorTests/Fixtures/`, blocks credentials and signing artifacts (`*.p12`, `*.cer`, `*.mobileprovision`, `notarization-credentials.json`, etc.).
- [ ] **`WEB_RESOURCES_HASHES.txt` populated** and a verification step (pre-commit hook or CI) is in place that catches divergence.
- [ ] **In-app About panel** lists the upstream credits with their licenses.
- [ ] **One round of clean-checkout testing** on a second machine if available — verifies that the repository contains everything needed to build, with no dependencies on local-machine state.

## Deferred improvements parking lot

Items discussed during planning, deliberately not built in v1, captured here so they're not lost or accidentally re-implemented. Pull from this list when real use surfaces a need; promote to a `D-XXX` decision in DECISIONS.md and a milestone here when accepted.

**Editing features:**
- Speed-based trim (start-while-below / end-while-above thresholds; D-018 deferred speed component).
- Brush radius slider with `[` / `]` keyboard adjustment (D-016 iteration path).
- Brush hardness slider (D-016 iteration path).
- Inverse-distance weighted average for the Average brush (D-016 iteration path).
- Flag-for-review GPS spike detection (Shape B from D-017).
- Sophisticated spike detection (Hampel filter, Kalman smoothing — D-017 iteration path).
- Mid-drag spacebar pan (Photoshop-style continuation of in-progress drags at new viewport position; D-014 deferred).
- Promotion/demotion of master track mid-session (D-011 deferred — revisit if a real use case emerges).
- Per-point timestamp synthesis option for export (D-012 deferred — option for fictional but plausible monotonic timestamps).

**Distribution and platform:**
- Sparkle auto-update (D-004 deferred).
- iOS/iPadOS sibling app (D-007 noted; the data and editing layers are written portably to support this).
- Mac App Store distribution (D-004 explicitly excluded; would require a separate signing identity and review compliance).
- Configurable undo depth via Settings (D-009 deferred; default 10 is hardcoded).
- Document package format vs single-JSON for the project file (D-010 deferred — revisit if file sizes grow unwieldy).

**Tile sources and basemaps:**
- Custom user-added tile URLs (D-008 deferred; v1 ships a curated build-time list).
- Offline tiles via MBTiles or pre-cached tile bundles.
- Additional basemap providers as use surfaces them.
- **NOAA Charts** (deferred from M2 on 2026-05-05). NOAA's nautical chart services are published only as ESRI REST MapServer, WMS, WMTS, and MBTiles — no XYZ tile endpoint that would drop into Leaflet's `L.tileLayer` cleanly. Re-evaluate at v2 if (a) NOAA adds an XYZ endpoint, (b) a sufficiently mature Leaflet ESRI/WMTS adapter justifies the integration overhead, or (c) a real user demand for nautical or coastal route work surfaces. Useful primarily for coastal hiking and nautical use cases.

**File format and compatibility:**
- Garmin-style `<gpxx:DisplayColor>` color extensions on export (D-013 considered, rejected for portability; revisit if Garmin BaseCamp roundtripping becomes important).
- KML import (only export is planned for v1).
- TCX or FIT format support (out of scope for a GPX editor; revisit only if a clear use case emerges).

**Quality and tooling:**
- Swift formatter integration (CONVENTIONS.md notes "no formatter in v1"; add `swift-format` if style drift becomes a problem).
- GitHub Actions CI for build verification on PRs.
- Dependabot for security alerts on any added SPM dependencies.

## Update protocol for this document

This document is updated continuously as the project evolves. When updating:

- **A milestone completes:** mark its status in the roadmap section as completed with the date. Move to the next milestone for the "Next action" line at the top.
- **A new question or input requirement surfaces:** add it to "Open inputs" with the context.
- **A deferred item gets pulled in:** remove it from the parking lot, add a corresponding milestone (or extend an existing one), and add a `D-XXX` decision in DECISIONS.md if the change involves architectural choices.
- **A pre-public-release item completes:** check it off the checklist.
- **The current status changes** for any reason (a blocker arose, a phase boundary crossed): update the top-of-document status section.

This document changes in place. Git history preserves the change log; no need to keep historical text in the document itself. Significant changes (new milestones, scope changes, new pre-release items) should be discussed in conversation before being committed.
