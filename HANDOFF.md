# GPXeditor — Handoff

This is the rolling state-of-the-project document. Unlike DECISIONS.md (append-only history) and CONVENTIONS.md (current-state code rules), this file changes as work progresses — milestones get checked off, new questions surface, and deferred items either get pulled in or stay parked. Read this at the start of every session to know where the project actually is right now, and update it before ending a session that completed meaningful work.

If you are starting a new session and reading this for the first time, also read in this order: `CLAUDE.md` (project orientation), `SECURITY.md` (sandbox and trust posture), `DECISIONS.md` (architectural choices), `CONVENTIONS.md` (code patterns). The relevant `Docs/0X_*.md` for whatever subsystem you're about to touch comes after that.

## Current status

**Phase:** M1 complete (2026-05-04). Ready to begin M2.

All eight M1 implementation tasks shipped:  Models/ data layer, GPXParser, GPXWriter, 14 synthetic test fixtures, ProjectFile JSON codec, FileDocument + DocumentGroup + UTI registration, Import GPX action, Reset to Original.  58 tests passing.  The full I/O loop is verified end-to-end:  Import GPX → save `.gpxeditor` project → reopen → edit → Reset to Original returns the track to its as-imported state with identity (UUID) and master/subsidiary role preserved.

Two project-wide infrastructure improvements landed alongside M1, each documented as a reusable best-practice procedure under `Docs/`:

- **Build-identifier retrofit** (`Docs/build-identifier-retrofit.md`).  Every build embeds a timestamp + short git SHA + dirty marker, surfaced in the About panel for unambiguous bug-report identification.
- **Self-signed development certificate** (`Docs/self-signed-cert-for-development.md`, D-019).  Replaces Xcode's free Personal Team automatic signing with a 10-year-validity self-signed cert ("Lab Code Cert"), escaping the periodic certificate-revocation churn that silently breaks builds.  Library validation is relaxed in Debug only via a separate `GPXEditor.Debug.entitlements` file; Release retains the strict production posture.

**Next action:** Begin **M2 — Map view and basemap selector** (see roadmap below).  Before implementation, the per-subsystem directive `Docs/02_MAP_AND_BRIDGE.md` (currently a stub) needs its substantive body — the JS↔Swift bridge protocol, message-type catalog, and initialization sequence are specified at the stub level but the schemas need detail before code lands.  M2 also needs the user's input on Open Inputs #3 (NOAA Charts endpoint verification) and #4 (CyclOSM mirror selection) before SECURITY.md's network allow-list can be finalized.

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

### M2 — Map view and basemap selector

Add `WebResources/` populated with vendored Leaflet (`leaflet.js`, `leaflet.css`), `simplify.js`, a minimal `index.html` host page, and a starter `editor.js`. Populate `WEB_RESOURCES_HASHES.txt` with SHA-256 hashes of the vendored files. Implement `MapView` (`NSViewRepresentable` wrapping `WKWebView`) in `Views/`. Implement the Swift side of the bridge as `MapBridge` in `Services/` — the `WKScriptMessageHandler` plus the `evaluateJavaScript` helpers. Compile a `WKContentRuleList` from the curated tile-server allow-list (see SECURITY.md and D-008) and apply it to the WebView. Implement the basemap selector UI as a control in the map view that the user can use to switch between the curated tile sources. Decide and verify the working endpoints for CyclOSM (pick one or two of the published mirrors) and NOAA Charts (verify the current chart-tile-service path is workable; if not, defer NOAA to a future milestone and note it in the deferred list).

When a session loads, Swift sends the master track's geometry to JS via the bridge; JS draws the polyline. Auto-zoom to fit on load.

Verify: Open a session with a real track, see the track on the map, OSM tiles loading, no console errors. Switch basemaps via the selector, verify tile-server allow-list blocks any unexpected request.

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

Implement the Sidebar in `Views/` showing the project structure: tracks (master tagged), each expanding to its segments, each segment expanding to its waypoints. Click on a track or segment in the sidebar to select all its points. Implement the Inspector in `Views/` showing per-point data (lat/lon/elevation/timestamp) for the currently-selected point with editable fields. Implement the Stats panel showing total distance, gain/loss, average and max speed (when timestamps are available), and gradient histogram. Implement the Waypoint Place tool (W keyboard shortcut) and the icon-picker popover with the curated icon set (~15 hiking/outdoor symbols using Garmin `<sym>` names, rendered via SF Symbols where available).

Verify: sidebar shows tracks, expanding shows segments, clicking selects. Inspector shows point data, editing a value propagates to the model and re-renders the map. Stats panel matches a known reference (compare to another GPX viewer for the same file). Place a waypoint, change its icon, save, reopen, verify it's preserved.

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

**3. M2 verification: NOAA Charts tile endpoint.** The current state of NOAA's chart tile service needs to be verified during M2. If a clean XYZ-style tile URL is available, NOAA Charts is included. If the integration is awkward (WMS or ESRI MapServer with extra wiring), NOAA is deferred to a future milestone — note it in the Deferred parking lot below and update SECURITY.md's network allow-list to remove the NOAA domain.

**4. M2 verification: CyclOSM mirror selection.** CyclOSM publishes multiple tile-server mirrors. Pick one or two with appropriate usage policies for personal/non-commercial use, document the chosen domains in SECURITY.md's network allow-list, and update the basemap selector code to use them.

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
