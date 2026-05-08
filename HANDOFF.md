# GPXeditor — Handoff

This is the rolling state-of-the-project document. Unlike DECISIONS.md (append-only history) and CONVENTIONS.md (current-state code rules), this file changes as work progresses — milestones get checked off, new questions surface, and deferred items either get pulled in or stay parked. Read this at the start of every session to know where the project actually is right now, and update it before ending a session that completed meaningful work.

If you are starting a new session and reading this for the first time, also read in this order: `CLAUDE.md` (project orientation), `SECURITY.md` (sandbox and trust posture), `DECISIONS.md` (architectural choices), `CONVENTIONS.md` (code patterns). The relevant `Docs/0X_*.md` for whatever subsystem you're about to touch comes after that.

## Current status

**Phase:** M6 complete (2026-05-07).  Reverse / Split / Merge shipped and verified 2026-05-06;  Trim Track shipped and verified 2026-05-07.  Several incidental usability wins landed alongside:  track-count overlay (stopgap until M8 sidebar), `remove_tracks` bridge message, spacebar-pan input override, per-tool cursors, zoom-aware brush-cursor circle.  184 tests pass (13 new TrimTrackOperation tests, 38 from Reverse / Split / Merge, 133 prior, no regressions).

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

**Next action:** **M7 — Pin to Ground** (DEM elevation correction via OpenTopoData).  Implement `Services/ElevationService.swift` as an async client batching coordinates into ≤100-point requests, gentle parallelism, graceful rate-limit / offline error handling.  Add `api.opentopodata.org` enforcement to the Swift-side URLSession allow-list (`NetworkAllowList` already names the domain — verify the wrapper trips on out-of-list hosts).  Operation honors selection-aware-operations rule (selection or whole master) with confirmation + progress indicator.  Per-point Snap to Ground (Point Tool right-click) uses the same service for one-point requests;  also unblocks "Properties of This Location" (empty-space right-click) deferred from M5.

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

### M3 — Selection and delete — **Completed 2026-05-05**

Lands the Point Tool's marquee gesture (drag in empty space) and the dedicated Lasso Tool (free-form polygon).  Selection state during the gesture lives in JS;  on commit JS posts `points_selected` with `(track_id, segment_id, point_indices)` triples and a `replace`/`add`/`subtract` modifier (Photoshop-style: shift = add, alt/option = subtract).  Swift owns the canonical selection in `SessionViewModel.selection` (per-window, transient — not saved to disk).  `highlight_selection` round-trips back to JS so the visible highlight is what Swift says, not what the gesture left behind — Swift-as-source-of-truth.

Delete operates on the canonical selection.  `Services/DeleteOperation.swift` is a pure (session, selection) → (session, touched) function;  `SessionViewModel.deleteSelected()` snapshots the prior session and selection, applies the operation, and registers an undo with NSUndoManager.  Empty segments and tracks are preserved (not pruned) so identity survives undo correctly.  Stale indices in a selection (e.g. after partial undo replays) are silently ignored rather than fatal.

Tool switching:  V / L menu items with single-key keyboard shortcuts and Escape returning to Point Tool.  Tool changes round-trip through the bridge as a new `set_tool` outbound message (added to `Docs/02_MAP_AND_BRIDGE.md` at M3 — the original directive assumed JS would infer the tool from gesture context, which is brittle).

M2 follow-up:  Swift→JS `update_tracks` is now wired so a Swift-originated edit (Import GPX, Delete, future operations) renders immediately.  The previous "imports don't show until close/reopen" limitation is closed.

Tests:  19 new — `SelectionTests` (modifier merges, wire-format round-trip) and `DeleteOperationTests` (descending-index correctness, empty-segment preservation, stale-index tolerance, multi-track touched list).  Total now 77;  no regressions.

**M3 outcome notes (deviations and follow-ups):**

- **UUID-case round-trip bug caught during M3 verification.**  First cut had `WireSelectionGroup` carry `trackId: UUID` / `segmentId: UUID` directly through Codable.  Decode (JS lowercase → Swift UUID) was case-insensitive and worked, but encode (Swift UUID → JS) used `UUID.uuidString` which produces UPPERCASE.  JS's `state.tracksById` is keyed by lowercase strings (matching the Swift→JS load_session convention WireTrack established).  Result:  `points_selected` round-tripped to `highlight_selection` with uppercase track ids that didn't match any key in JS, so 0 markers rendered with `skipped_no_track > 0` while everything Swift-side reported success.  Fixed by switching `WireSelectionGroup.trackId` / `segmentId` to `String` with explicit `.lowercased()` at construction, matching the WireTrack/WireSegment/WireWaypoint pattern.  The WireSelectionGroup type doc captures the gotcha explicitly so the next person who adds a UUID-bearing wire type doesn't repeat it.
- **Track halo doesn't scale with zoom (D-013 contrast rule polish item).**  `editor.css` declares `.track-halo` with `stroke-width: 6px` — fixed pixel value chosen at M2 to be visible against any basemap.  At high zoom the 6px halo is wider than typical map features and visually dominates the 3px colored line under it (Esri satellite imagery especially makes this look like a white blob).  Make the halo stroke-width zoom-aware (Leaflet's `map.on('zoomend')` can drive a CSS variable) or scale relative to the map's pixel-per-degree.  Polish, not blocking — the contrast goal of D-013 is met;  the visual could just be more refined.
- **Selection markers stack at high zoom.**  With 1300+ points selected in a tight section, the 5px-radius CircleMarkers overlap each other into a dense row.  Same fix family as the halo:  scale marker radius with zoom, or render selection as a stroke overlay instead of per-point markers when the selection is dense.  Polish for M8 (the sidebar / inspector pass touches selection-rendering ergonomics anyway).
- **No zoom-to-selection (⌘2) yet.**  M3's keyboard-shortcut list in the original spec named ⌘2 "zooms to selection" but the work landed without it.  Trivial to add (compute LatLngBounds over the selection's points, call `map.fitBounds`, send via a new `zoom_to_bounds` outbound message).  Adding to deferred parking lot rather than reopening M3.

### M4 — Simplify brush — **Completed 2026-05-05** (with Smooth Brush pulled forward)

Lands the first concrete brush (D-014, D-015, D-016) plus the `apply_brush` bridge message and live preview.  Architecture per Occam's Razor:  the `BrushTool` protocol family from D-015 is **deferred to M9** when the second and third brushes (Smooth, Average, AddDetail) earn the abstraction.  At M4 we ship `SimplifyBrush` as a concrete `enum` namespace with a single `apply(...)` static function — same shape DeleteOperation has — and factor out the protocol later when there are real consumers.

Pieces:

- `Services/RDPSimplifier.swift` — pure Ramer-Douglas-Peucker function operating in 2D Euclidean space.  Coordinate-system-agnostic (degrees, metres, projected pixels — caller chooses).  Returns the input array's surviving indices so callers can preserve per-point metadata (elevation, timestamp) that's outside the 2D simplification space.
- `Services/SimplifyBrush.swift` — applies RDPSimplifier to the contiguous index ranges of a track segment that fall within the brush stroke's swept region.  Uses immediate-neighbor anchors so the simplified subrange reconnects cleanly to the untouched parts of the segment.  Brush radius (per-sample on the wire) lets a future variable-radius brush vary radius mid-stroke;  v1 ships fixed 30m radius and 5m RDP tolerance with metres→degrees conversion at the boundary.
- `Services/BridgePayloads.swift` — `ApplyBrushPayload` (inbound) plus `WireBrushStroke` and `WireStrokeSample` for the nested wire shape.  The schema is the one drafted at M2 in `Docs/02_MAP_AND_BRIDGE.md`'s catalog;  M4 just wires it.
- `Services/MessageDispatcher.swift` — adds `apply_brush` case routing through a new `onApplyBrush` callback.
- `Models/EditingTool.swift` — adds `.brushSimplify` case;  wire string is `"brush_simplify"`.
- `ViewModels/SessionViewModel.swift` — `applySimplifyBrush(trackId:stroke:)` snapshots prior session, applies via SimplifyBrush, registers undo.  Selection is cleared after a brush apply since indices may no longer be valid.  Each touched track is a separate undo unit at M4;  multi-track undo grouping is iteration material.
- `Views/MapView.swift` — wires `dispatcher.onApplyBrush` to dispatch by `brushType` ("simplify" → SessionViewModel.applySimplifyBrush;  unknown → bridge violation).
- `Views/AppCommands.swift` — Tools menu entry "Simplify Brush" with `1` keyboard shortcut.
- `WebResources/editor.js` — brush gesture state, L.circle cursor visualisation following the cursor, live preview using the vendored simplify.js, one `apply_brush` per touched track on commit.  Document-level mouseup safety net catches off-window releases (same pattern marquee / lasso use).

Tests:  17 new — `RDPSimplifierTests` (endpoints always preserved, tolerance behavior, degenerate zero-length-line case, mixed-deviation reduction with index-pinning avoided in favor of invariant assertions) and `SimplifyBrushTests` (no-op cases, real reduction, untouched portions byte-identical, touched-list correctness).  Total now 94;  no regressions.

**M4 outcome notes (deviations and follow-ups):**

- **Smooth Brush pulled forward from M9 to M4** (Scott's feedback during M4 verification:  Simplify alone doesn't match user expectation of "what a brush does" — most users want jitter cleanup, which is Smooth's job).  M4 ships both brushes side-by-side;  M9's roster is now reduced to Average and AddDetail.  Architecture per D-015 (RegionBrushTool family) is still deferred — both brushes are concrete `enum` namespaces with `apply(...)` static functions.  Factor out the protocol when M9's third+fourth brushes earn it.
- **RDP tolerance bumped 5m → 10m mid-milestone.**  Scott's first verification produced "applySimplifyBrush: prior=1135 new=1131" (4 points dropped) — visually imperceptible.  Bumped to 10m for visibly meaningful results on real GPS tracks.  Still tunable via the deferred "brush hardness slider" (D-016 iteration path).
- **Smooth Brush kernel half-width tuned 3 → 1 mid-milestone.**  Scott's feedback:  3 (7-point average) was "much too aggressive" — smoothed legitimate trail curves toward straight lines.  1 (3-point average — point + immediate neighbors) is gentler;  Scott's followup:  "might be too subtle, but multiple passes works."  Multiple-pass-as-workaround is acceptable for v1;  the "right" answer is the brush hardness slider in the deferred parking lot.
- **`apply_brush` preview design split between brushes.**  Initially used a magenta dashed simplified-line overlay for both — Scott found it unclear ("when I brush over a line it turns a color … no points changed").  Replaced for Simplify with red `×` glyphs at to-be-removed points (per-point, shape-primary cue).  Smooth keeps the line-overlay style because the result IS a different shape, not a per-point removal.  Each preview now uses 3+ cues (shape, color, outline/dash) per CONVENTIONS.md "Color is never the only signal."
- **UUID-case bridge round-trip lesson** that bit M3 didn't bite again at M4 because `apply_brush` only carries `track_id` inbound;  the canonical commit broadcasts `update_tracks` whose lowercase-string-from-WireTrack pattern is already correct.

Tests:  24 new (17 RDP + Simplify, 7 Smooth).  Total now 101;  no regressions.

### M5 — Point Tool single-point operations — **Baseline + follow-up complete 2026-05-05**

Lands the headline "Adze tedium fix" features:  vertex draggability and click-on-line insertion.  Right-click context menu and Edit Coordinates dialog deferred to a follow-up pass — the user-feedback loop benefits from getting drag-and-insert into the user's hands as the next iteration cue, and the context-menu items split cleanly into "wired now" (Delete already exists at M3, Promote to Waypoint, Set as Segment Boundary), "needs M7" (Snap to Ground → ElevationService), and "needs Edit Coordinates UI" (a small SwiftUI sheet, separate piece of work).

Pieces shipped:

- `Services/MovePointOperation.swift` — pure function:  resolve (track, segment, index), update lat/lon, preserve elevation and timestamp.  Same-coordinates input is a no-op (no spurious undo entry).
- `Services/AddPointOnLineOperation.swift` — pure function:  insert a new TrackPoint at `afterIndex + 1`.  Elevation and timestamp are linearly interpolated from surrounding anchors when both have those values;  fall back to the single available anchor;  nil otherwise (the "don't fabricate data" rule from CONVENTIONS.md applied at the model layer).  Edge cases:  `afterIndex == -1` inserts at front;  `afterIndex == count - 1` inserts at end.
- `Services/BridgePayloads.swift` — `MovePointPayload`, `AddPointOnLinePayload` (inbound).  Schemas match the M2 catalog draft in `Docs/02`.
- `Services/MessageDispatcher.swift` — adds `move_point` and `add_point_on_line` cases routing through new `onMovePoint` / `onAddPointOnLine` callbacks.
- `Views/MapView.swift` — wires both callbacks to SessionViewModel methods.
- `ViewModels/SessionViewModel.swift` — `applyMovePoint` and `applyAddPointOnLine` snapshot prior session, apply via the corresponding operation, register undo with action names "Move Point" / "Add Point."  Move preserves selection (indices unchanged);  Insert clears selection (indices > afterIndex shifted, simplest valid response).
- `WebResources/editor.js`:
  - **Vertex hit-test** at mousedown — within VERTEX_GRAB_TOLERANCE_PX (10) of any rendered vertex starts a vertex drag rather than a marquee.  During the drag the polyline's lat/lng array is updated in place so the user sees the new shape live.  Commit on mouseup posts `move_point`;  Swift broadcasts `update_tracks` and the polyline re-renders authoritatively.
  - **Polyline click handler** bound per segment at render time.  Gates on Point Tool + no in-flight drag + click is on a non-vertex part of the polyline.  Computes the nearest sub-segment via clamped projection and posts `add_point_on_line` with the projected lat/lng.
  - Document-level mouseup safety net extended to handle the new vertex-drag case alongside the existing marquee/lasso/brush handlers.
  - Tool-switch teardown also clears any in-flight vertex drag.

Tests:  16 new — `MovePointOperationTests` (basic move, metadata preservation, no-op cases) and `AddPointOnLineOperationTests` (insert, interpolation, fallback rules, edge-of-segment positions).  Total now 117;  no regressions.

**M5 follow-up shipped same day:**

- `Services/PromoteToWaypointOperation.swift` — converts a track point to a Waypoint at the same lat/lon, removing the track point.  Carries elevation and timestamp over.
- `Services/SetSegmentBoundaryOperation.swift` — splits a segment into two at the named point.  Point becomes the first point of the new segment;  original segment shrinks.  Color carries over.
- `Services/PlaceWaypointOperation.swift` — places a new Waypoint at a click location.  Attaches to master track if designated, else first track, else no-op.
- `Components/EditCoordinatesSheet.swift` — modal SwiftUI sheet with lat/lon text fields.  Range-validated (WGS84 bounds).  OK button gates on parse + range;  inline error message for invalid input (per "describe, don't accuse" rule).  Drives applyMovePoint on commit.
- `Services/BridgePayloads.swift` — `RequestContextMenuPayload` (inbound) with discriminated `ContextMenuTarget` (point vs empty).
- `Services/MessageDispatcher.swift` — adds `request_context_menu` case routing through `onRequestContextMenu`.
- `ViewModels/SessionViewModel.swift` — `applyPromoteToWaypoint`, `applySetSegmentBoundary`, `applyPlaceWaypoint`, `selectEntireSegment`, `deleteSinglePoint`, `requestEditCoordinates` plus the `editCoordinatesRequest: EditCoordinatesRequest?` published trigger.
- `Views/MapView.swift` — `handleRequestContextMenu` builds an NSMenu with per-target items and shows it via `popUp(at:in:webView)`.  ClosureMenuItem subclass bridges between AppKit's selector-based action API and Swift closures.
- `Views/ContentView.swift` — `.sheet(item: $sessionVM.editCoordinatesRequest)` presents EditCoordinatesSheet on demand;  the sheet's onCommit calls applyMovePoint.
- `WebResources/editor.js` — `handleContextMenu` listens for native `contextmenu` events on the map container, classifies into point (within VERTEX_GRAB_TOLERANCE_PX of a vertex) or empty space, posts `request_context_menu`.

Snap to Ground (D-014's vertex-menu spec) and "Properties of This Location" (empty-space-menu spec) are deferred to M7 because they need the ElevationService.

Tests:  16 new — PromoteToWaypoint (5), SetSegmentBoundary (6), PlaceWaypoint (5).  Total now 133;  no regressions.

**Visual-feedback observations surfaced during M5 baseline verification (Scott, 2026-05-05).**  Two related but separately-addressed pieces:

- **Always-visible points.**  Track vertices currently have no per-point visualization unless selected — Scott observed "I can select invisible points," meaning the marquee catches things the user can't see.  Proposed fix:  every track point renders as a small marker (default grey or black, system-blue or accent when selected).  Selection becomes a visible state CHANGE on already-visible markers, not a marker-from-nothing.  Performance caveat:  thousands of CircleMarkers can overwhelm Leaflet at low zoom — implementation needs zoom-gating or a canvas-renderer fallback.

- **Selection ghosts as a feature, with fade-out.**  Currently, after a vertex drag (`move_point`), the polyline updates via `update_tracks` but the selection-highlight markers stay at the OLD positions because Swift doesn't re-emit `highlight_selection` on Move (selection indices are still valid, just at moved positions).  Scott's preference (verbatim):  "I actually like the points getting left behind, but they should fade out over, so 30 seconds."  Implementation sketch:  on `update_tracks`, take the current `state.selectionLayer`, detach it from "active" status, start a 30s opacity fade animation, then remove.  Fresh `highlight_selection` messages produce a new active layer.  Multiple ghosts can coexist if the user does several edits in quick succession.  Open question:  does the ghost represent the still-selected-in-Swift points (so the user might still hit Delete and remove them) or is it purely a visual trail?  Probably the latter for cleanliness — Move could trigger a Swift-side selection re-broadcast at the new positions while the OLD positions fade as visual history.  Settle when the feature is built.

Both captured in the "Visual rendering" deferred parking lot for a dedicated pass.

### M6 — Track operations: split, merge, reverse, time-trim — **Completed 2026-05-07** (Reverse / Split / Merge landed 2026-05-06; Trim Track landed 2026-05-07)

Implement track-level operations in `Services/`: split-at-selected-point, merge-second-track-into-this-one (with confirmation dialog), reverse-direction. Implement the Trim Track dialog (D-018) with two optional time-based trim sections, live preview overlay, OK commits as one undo unit. All operations honor the selection-aware-operations rule.

**Reverse Track shipped 2026-05-06:**

- `Services/ReverseTrackOperation.swift` — pure function flipping segment order within a track AND per-segment point order.  Per-point metadata (elevation, timestamp) stays attached to its point;  segment ids and the track id are preserved;  waypoints are untouched (they have their own lat/lon).  Edge cases:  empty track is a no-op (empty touched-list, no undo entry);  single-point segment goes through the operation (touched-list reports the track) but is geometrically a no-op;  stale trackId is a no-op.
- `Models/Selection.swift` — added `uniqueTrackId` computed.  Returns the single trackId all selected points belong to, or nil if the selection spans multiple tracks (or is empty).  Drives the menu-disabled gate for track-scoped operations.
- `ViewModels/SessionViewModel.swift` — `applyReverseTrack(trackId:)` snapshots prior session, applies the operation, registers undo with action name "Reverse Track."  Selection is cleared because every point's index has shifted (preserving selection across reverse would require translating each (segment, index) reference into its mirrored form;  a no-selection result is simpler and less error-prone).
- `Views/AppCommands.swift` — Edit menu "Reverse Track" item.  Selection-aware:  enabled only when `selection.uniqueTrackId != nil`.  No keyboard shortcut for v1.
- `Views/MapView.swift` — vertex right-click context menu gets a "Reverse Track" item in its own section (after Select Entire Segment).  Right-clicking a point unambiguously names the containing track, so track-scoped operations belong here in addition to the Edit menu.

Tests:  10 new — `ReverseTrackOperationTests` covering single/multi-segment reverses, per-point metadata preservation, segment identity preservation, waypoints untouched, track id preserved, empty/single-point edge cases, stale-trackId no-op, and reverse-is-its-own-inverse.

**Split Track shipped 2026-05-06:**

- `Services/SplitTrackOperation.swift` — pure function:  original track keeps everything BEFORE the split point;  new track gets the point onward.  Convention:  no point duplication (point becomes first of new track), consistent with SetSegmentBoundary.  Mid-segment splits cut the segment;  segment-boundary splits (pointIndex==0 of non-first segment) move the segment whole-cloth.  New track:  fresh UUID, name "<original> (continued)", empty `immutableOriginalBytes` (born from edit, not import — Reset to Original on it has no source), nil role, inherited recordedDate, no waypoints.  Inserted at trackIndex+1 so it sits next to its parent in any future track-listing UI.  Edge cases:  pointIndex==0 of segment 0 / pointIndex == last point of last segment / stale ids → no-op.
- `Models/Selection.swift` — added `singlePointReference` computed.  Returns the single PointReference if exactly one point is selected, otherwise nil.
- `ViewModels/SessionViewModel.swift` — `applySplitTrack(trackId:segmentId:pointIndex:)` snapshots prior session, applies the operation, registers undo as "Split Track."  Selection cleared.
- `Views/AppCommands.swift` — Edit menu "Split Track at Point", enabled when exactly one point is selected.
- `Views/MapView.swift` — vertex right-click "Split Track Here" alongside Reverse Track.

Tests:  18 new — `SplitTrackOperationTests` covering mid-segment / boundary splits, multi-segment, color/id preservation, name suffix, empty-bytes, role-not-inherited, recordedDate inheritance, waypoints stay on original, touched-list reports both, insertion ordering, plus all no-op edge cases.

**Merge Tracks shipped 2026-05-06:**

- `Services/MergeTracksOperation.swift` — pure function:  source segments + waypoints append to destination;  source removed.  Destination wins on every identity property (id, name, role, immutableOriginalBytes, recordedDate).  Self-merge / stale ids → no-op.  Re-finds source-by-id after destination mutation to handle source-before-destination ordering correctly.
- `Components/MergeTrackPickerSheet.swift` — modal SwiftUI sheet listing candidate sources (every track except destination).  Single-select List, Cancel/Merge buttons.  Merge runs an NSAlert confirmation with explicit direction ("Merge X into Y? X will be removed.") before committing.
- `ViewModels/SessionViewModel.swift` — `requestMergeTracks(destinationId:)` opens the sheet via the published `mergeTracksRequest`;  `applyMergeTracks(sourceId:destinationId:)` runs the operation with snapshot/undo.  `MergeTracksRequest` Identifiable wrapper alongside `EditCoordinatesRequest`.
- `Views/ContentView.swift` — `.sheet(item: $sessionVM.mergeTracksRequest)` presents the picker.
- `Views/AppCommands.swift` — Edit menu "Merge Track Into…", enabled when `selection.uniqueTrackId != nil` AND `tracks.count >= 2`.
- `Views/MapView.swift` — vertex right-click "Merge Track Into…" with the trackCount gate baked into `mergeItem.isEnabled`.

Tests:  10 new — `MergeTracksOperationTests` covering segment append order, waypoint append, source removal, destination identity preservation, source segment data preservation, touched list, self-merge / stale-id no-ops, and the source-before-destination ordering case.

**Trim Track shipped 2026-05-07:**

- `Services/TrimTrackOperation.swift` — pure function dropping every TrackPoint whose timestamp falls outside the kept window.  Strict-inequality bounds (`<` / `>`) so the user-named cutoff times themselves stay (a "trim start at 09:00:00" keeps the 09:00:00 sample).  Untimestamped points are always kept — they have no time to compare against and dropping them would conflate "outside the window" with "no time recorded" (cases:  Add Detail Brush synthesis at M9, imports where source GPX omitted `<time>`).  Empty segments preserved for undo identity (same rule the other M6 operations follow).  Operation takes `trackId` only;  the D-018 mention of "trim within a selected range" is deferred — adds two design choices (does selection narrow scope or override bounds?) not worth pinning down before a real use case.  Plus two helpers:  `pointsToRemove(...)` returns the (track, segment, indices) groups for the live preview, and `timestampRange(of:in:)` returns the track's earliest…latest timestamp so the dialog can pre-seed the date pickers and the menu can gate on "track has timestamps."
- `Services/BridgePayloads.swift` — `PreviewTrimPayload` (outbound) carries the to-be-removed groups using the `WireSelectionGroup` wire shape (different semantic, same envelope — JS dispatches by message type);  `ClearTrimPreviewPayload` (outbound) is empty — the type itself is the signal.
- `Services/BridgeMessage.swift` — adds `previewTrim` and `clearTrimPreview` cases to `OutboundMessage` plus their `"preview_trim"` / `"clear_trim_preview"` wire discriminators.
- `ViewModels/SessionViewModel.swift` — `requestTrimTrack(trackId:)` opens the sheet via `trimTrackRequest` (Identifiable wrapper alongside EditCoordinatesRequest / MergeTracksRequest);  gates on `TrimTrackOperation.timestampRange != nil` and surfaces an NSAlert for tracks with no timestamps before the sheet appears.  `updateTrimPreview(trackId:startBefore:endAfter:)` recomputes preview groups and publishes via `trimPreviewGroups` (`@Published [PreviewGroup]?`, nil = no active preview).  `clearTrimPreview()` nils it on dismissal.  `applyTrimTrack(trackId:startBefore:endAfter:)` snapshots prior session, applies the operation, registers undo with action name "Trim Track."  Selection cleared on commit (point indices have shifted).
- `Components/TrimTrackSheet.swift` — modal SwiftUI sheet with two GroupBox sections, each a Toggle + DatePicker.  Date pickers seeded with the track's actual first/last point times and bounded `.in: timestampRange` so the user can't pick a value that wouldn't trim anything.  Live-preview wired via `.onAppear` + four `.onChange` handlers (one per control).  `.onDisappear` clears the preview regardless of dismissal path (OK, Cancel, Escape).  OK is disabled when both checkboxes are off (no-op courtesy);  start > end with both enabled surfaces an inline orange caption ("every point will be removed") but doesn't block — "trim everything" is a valid intent and undo recovers if it was a mistake.
- `Views/MapView.swift` — `applyTrimPreviewIfChanged(_:)` diffs `sessionVM.trimPreviewGroups` against the last broadcast and sends exactly one `preview_trim` or `clear_trim_preview` per state change (Equatable comparison on `[PreviewGroup]?` suppresses redundant updates).  Vertex right-click context menu gets a "Trim Track…" item alongside Reverse / Split / Merge.
- `Views/AppCommands.swift` — Edit menu "Trim Track…" item, gated on `selection.uniqueTrackId != nil` (the track-scoped-operation pattern Reverse and Merge already use).
- `Views/ContentView.swift` — `.sheet(item: $sessionVM.trimTrackRequest)` presents `TrimTrackSheet`;  the sheet's onPreview / onCommit / onDismiss bind to the SessionViewModel methods above.
- `WebResources/editor.js` — `handlePreviewTrim` renders red `CircleMarker`s (radius 4, `#dc2626`, fillOpacity 0.85) for each named point at the polyline's current lat/lng;  `handleClearTrimPreview` tears down the layer.  Each preview replaces the prior one — there's only ever zero or one trim preview live.  `state.trimPreviewLayer` holds the L.layerGroup.

Tests:  13 new — `TrimTrackOperationTests` covering both bounds (start, end, both, both-nil no-op), inclusive-cutoff semantics, untimestamped-points-always-kept, empty-segment preservation, stale-trackId / nothing-falls-outside no-ops, and the two helpers (`timestampRange` basic / mixed / no-timestamps;  `pointsToRemove` matches what `apply` would drop, and is empty when both bounds are nil).  Total now 184;  no regressions.

**Trim design notes:**

- **Strict-inequality bounds, not inclusive.**  The user names a time and the points at that exact second stay.  This reads as "trim until 09:00:00 — at 09:00 you're keeping" rather than "trim through 09:00:00 — at 09:00 you've already trimmed."  Both readings are defensible;  the strict-less / strict-greater choice was made because the dialog's two sections are framed as "Trim start at <X>" and "Trim end at <Y>" — the prepositions imply X and Y are the new boundaries, not the last dropped points.
- **Untimestamped points are always kept, never dropped.**  An untimestamped point has no time to compare against the bounds.  Dropping it on either bound conflates "outside the window" with "no time recorded" — different concerns.  The two real producers of untimestamped points (Add Detail Brush at M9, GPX imports without `<time>`) shouldn't be disturbed by a time-based trim.  If a future use case earns a "drop untimestamped points too" mode, it's a separate option flag.
- **Track with no timestamps gets an early NSAlert.**  Detected in `requestTrimTrack` before the sheet opens — `TrimTrackOperation.timestampRange` returns nil and the user sees "Trim Track is unavailable for this track. Trim Track filters by per-point timestamps;  this track has no points with recorded times."  The operation itself tolerates the case (everyone is untimestamped → everyone is kept → no-op) but bouncing at the menu surface gives the user a clear reason instead of a dialog that does nothing on OK.
- **Selection-aware variant deferred.**  D-018 mentions "trim within a selected range" as a possibility;  v1 implements only the simpler "trim the whole track" form.  Adds two design choices (does selection narrow scope, or override bounds?) that aren't worth pinning down before a real use case surfaces.  In the parking lot.
- **Live-preview wire-shape reuse.**  `PreviewTrimPayload` reuses `WireSelectionGroup` rather than minting a parallel "preview group" wire type.  Same `(track_id, segment_id, point_indices)` triple in the right snake_case + lowercase-id format;  the JS handler dispatches by message type so semantic distinction is carried by the dispatch table, not the envelope.

**Reverse design notes:**

- **Both axes flipped, not just one.**  A user reversing a track wants the geometry reversed end-to-end:  segment-2 (which came after segment-1) should now come BEFORE segment-1 in the reversed track, and points within each segment also reverse.  The "only-points-within-segment" alternative was rejected:  it produces "morning recording but in reverse, then afternoon recording but in reverse," which doesn't match user intent.
- **Timestamps stay attached, even though they go non-monotonic.**  The cleanest answer for "what happens to per-point metadata when you reverse a track" is "nothing — each point keeps its own data."  Timestamps record when the recording happened;  reversing the track doesn't change that history.  Consequence:  a reversed track has monotonically-decreasing timestamps.  The Stats panel (M8) computing speed should take abs() on time deltas or compare adjacent timestamps without assuming order.  Strip-timestamps-on-reverse was considered and rejected as destructive (and undo recovers anyway);  a future "Strip Timestamps" operation can be added if a use case earns it.

**Merge design notes — destination-wins identity:**

- The merged track keeps the destination's id, name, role, immutableOriginalBytes, and recordedDate.  Source's role / bytes / date are dropped.  Rationale:  the user invoked the operation while operating on the destination (its point was selected), establishing it as the "subject" of the edit.  Auto-elevating the merged result to master based on either side's role would be surprising;  user re-tags via M9's master/subsidiary UI if needed.  Reset to Original on the merged track restores the destination's pre-merge state — undoes the merge as part of restoring the destination's full original recording.  Source's bytes are not preserved separately;  ⌘Z is the path to undo the merge specifically.
- "Merge Track INTO this one" reads selection-as-destination.  The picker presents the SOURCE — the track that will dissolve.  An NSAlert confirmation with explicit direction ("Merge X into Y? X will be removed.") gates the commit so a wrong-direction pick is catchable before it becomes an undo.

**Incidental usability landings during M6 (2026-05-06):**

These weren't on the M6 spec but surfaced as testing pain and got handled inline:

- **Track-count overlay** (`Views/ContentView.swift`).  Stopgap "Tracks: N" pill in the top-left corner so the user can see whether the project has ≥ 2 tracks (the gate for Merge).  Pure SwiftUI overlay, deletable when the M8 sidebar lands — the sidebar is the proper home for project-structure visibility.
- **`remove_tracks` bridge message** (`Services/BridgePayloads.swift`, `Services/BridgeMessage.swift`, `Views/MapView.swift`, `WebResources/editor.js`).  Merge is the first operation that removes a track from the session;  prior to this, `update_tracks` only handled add/modify and stale Leaflet polylines lingered for the merge's source track until the next load_session.  Now `applyTracksIfChanged` diffs both directions and emits `remove_tracks` for departed track ids;  `handleRemoveTracks` in editor.js tears down the named tracks' halo + line layers and drops them from `state.tracksById`.
- **Spacebar-pan** (`WebResources/editor.js`).  Pure JS-local input override:  `state.spacebarHeld` flag, document keydown/keyup on `Space` toggles it (with text-input-focused guard), mousedown returns early when held so Leaflet's default drag-to-pan kicks in.  Cursor switches to grab while held;  no Swift state change, no `set_tool` round-trip.  D-014's deferred mid-drag-spacebar-continuation case stays deferred.
- **Per-tool cursors** (`WebResources/editor.js`).  Point Tool → `default` (arrow);  Lasso Tool → `crosshair`;  Brush tools → `none` (system cursor hidden, Leaflet circle is the cursor — see next item).  Spacebar-held → cleared inline cursor so Leaflet's `.leaflet-grab` class shows grab → grabbing through the drag.  `applyCursor()` is called whenever the tool changes or spacebar state changes.
- **Zoom-aware brush-cursor circle** (`WebResources/editor.js`).  When a brush tool is active, an L.circle follows the mouse at the actual brush radius in METERS (`BRUSH_RADIUS_METERS = 30`).  Sized in meters means it grows / shrinks with zoom for free — Leaflet handles the pixel conversion.  Hidden during an active stroke (the in-stroke `state.brush.cursorCircle` takes over) and on map mouseout.  Browser cursor URLs were considered and rejected:  CSS cursors cap at ~128 px, don't redraw on zoom, and would require vendoring image assets.

Tests after all M6 work above:  184 (13 TrimTrackOperation, 38 across Reverse / Split / Merge, 133 prior, no regressions).

Verify: each operation produces correct results that round-trip through Save/Reopen and Export.

**M6 outcome notes (deviations and follow-ups):**

- **Black palette slot is confusing as the first-import default** (Scott's feedback during Merge verification, 2026-05-06).  `DefaultPalette.colors[0]` is `#000000`, the first slot of the Okabe-Ito colorblind-safe palette.  Imports starting from a fresh project get black for their first track, which reads as an error state against light basemaps and obscures the line over many tile features.  Worse:  Scott reported orange (slot 1) and bluish-green (slot 3) reading as similar in his vision, suggesting the formal Okabe-Ito guarantee doesn't fully hold for him.  Three options on the table — reorder so black isn't slot 0, swap to a different palette entirely (would need a D-013 amendment), or add a non-color cue (dashed/dotted patterns rotating per segment, or text labels near each track).  Parked for later;  the palette is editable in Settings at M8/M10 anyway.

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

**5. App icon design.** **Resolved 2026-05-05 (development placeholder satisfied).** A 1024×1024 master (topographic map background with a diagonal pencil/stylus overlay) is committed at the repo root as `icon-source.png`;  Xcode's `AppIcon.appiconset` is generated from it via `sips` (downsample) + `optipng` (recompress).  Total icon set ~2.3 MB, committed in `718e54e`.  Re-evaluate before the M10 public flip:  a vector master (SVG) would let us regenerate at arbitrary sizes and tune the post-Big-Sur squircle masking conventions Apple introduced;  the current PNG master is fine for development but isn't ideal for a public-release artifact.  Iteration items:  (a) consider whether the icon's edge-to-edge full-bleed terrain fits the macOS Big-Sur+ icon shape (a centered scene with a clear focal point usually masks better than a textured field), (b) evaluate alternate basemaps / focal compositions if Scott wants something more distinctive than "map + pencil."

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
- **Fuse segment boundary / connect two points** (M5 follow-up observation, 2026-05-05).  Inverse of M5's "Set as Segment Boundary":  given two adjacent segments in a track, merge them into one.  Variations to consider at implementation time:  (a) "Fuse with next" right-click item on any segment's last point or any segment's first point — joins it with its neighbour;  (b) "Connect to point" gesture that picks two arbitrary points and joins their containing segments (more powerful, more design questions about which point becomes which neighbour);  (c) selection-aware "merge selected" that operates on multiple selected segments via the sidebar at M8.  All variations are pure operations on the model layer following the SetSegmentBoundary pattern.
- M5 follow-up:  Snap to Ground (per-point elevation lookup) and Properties of This Location (empty-space lat/lon/elevation readout) — deferred from the right-click context menus until ElevationService lands at M7.
- Speed-based trim (start-while-below / end-while-above thresholds; D-018 deferred speed component).
- Brush radius slider with `[` / `]` keyboard adjustment (D-016 iteration path).
- Brush hardness slider (D-016 iteration path).  Concretely requested during M4 verification (2026-05-05):  Smooth Brush at kernel half-width 1 felt "too subtle but multiple passes works"; bumping back to 3 felt "much too aggressive."  A user-controlled strength dial (per-stroke or persistent) lets the user pick the right level for the track at hand.  Same applies to Simplify Brush's RDP tolerance.  Implementation:  one Slider per brush in a brushes panel (M8-ish);  alternative — modifier-key-held aggressiveness (Shift = stronger, Option = weaker).
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

**Visual rendering:**
- Zoom-aware track-halo stroke width (M3 deferred 2026-05-05).  `editor.css` `.track-halo` uses a fixed 6px stroke that visually dominates the 3px colored line at high zoom.  Make it scale via a Leaflet `zoomend` listener that updates a CSS custom property (or computes per-zoom values), or render the halo as a lower-opacity sibling polyline whose weight tracks zoom level.
- Zoom-aware selection-marker radius / dense-selection alternate rendering (M3 deferred 2026-05-05).  CircleMarkers stack at high zoom when the selection is dense (1000+ points in a tight section);  consider switching to a stroke overlay along the selected polyline range when the marker count exceeds a threshold.
- ⌘2 "Zoom to Selection" command (M3 deferred 2026-05-05).  Compute LatLngBounds over the selection, call `map.fitBounds`, drive via a new `zoom_to_bounds` Swift→JS bridge message.  Originally listed in M3's keyboard-shortcut spec but landed without it.
- **Always-visible track points** (M5 deferred 2026-05-05).  Render every track vertex as a small grey/black CircleMarker by default, system-blue / accent when selected.  Resolves the "I can select invisible points" surprise and unifies the selection-marker / unselected-vertex visual language.  Implementation:  zoom-gated rendering or canvas renderer for the multi-thousand-points case.  See M5 outcome notes for full context.
- **Selection-ghost fade-out** (M5 deferred 2026-05-05).  Scott's preferred behaviour for the post-drag stale-marker case:  leave the old-position selection markers in place after a Move, fade them out smoothly over ~30 seconds.  Multiple ghosts can stack if the user makes several edits quickly.  Open design question (settle at implementation time):  does the ghost represent still-selected-in-Swift points or is it purely a visual trail with Swift's selection state re-syncing to the new positions immediately?  See M5 outcome notes for full context.

## Update protocol for this document

This document is updated continuously as the project evolves. When updating:

- **A milestone completes:** mark its status in the roadmap section as completed with the date. Move to the next milestone for the "Next action" line at the top.
- **A new question or input requirement surfaces:** add it to "Open inputs" with the context.
- **A deferred item gets pulled in:** remove it from the parking lot, add a corresponding milestone (or extend an existing one), and add a `D-XXX` decision in DECISIONS.md if the change involves architectural choices.
- **A pre-public-release item completes:** check it off the checklist.
- **The current status changes** for any reason (a blocker arose, a phase boundary crossed): update the top-of-document status section.

This document changes in place. Git history preserves the change log; no need to keep historical text in the document itself. Significant changes (new milestones, scope changes, new pre-release items) should be discussed in conversation before being committed.
