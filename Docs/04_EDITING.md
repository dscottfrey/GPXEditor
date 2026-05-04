# 04 — Editing Subsystem (STUB)

> **Status: stub.** Section headings outline intended scope; bodies are placeholders. This is the largest of the per-module directives because the editing surface is wide. Full bodies to be drafted before M3 begins; M0, M1, M2 do not require this document complete, but M3 onward depends on it.

## Scope

The Editing subsystem covers all the tools and operations the user invokes to manipulate track geometry, segments, waypoints, and metadata. Spans `Services/` (where tools, brushes, and operation types live; per CONVENTIONS.md type-kind grouping). UI integration with views happens in `Views/` and `Components/`; this document describes the operations themselves and their interfaces.

## Tool architecture

To be expanded. A top-level `Tool` protocol defines the basic infrastructure each editing tool conforms to: cursor changes, gesture forwarding, key handling, the activation/deactivation lifecycle. Concrete tools implement this protocol with their specific behavior. Tool switching is keyboard-cheap (single-key shortcuts; Escape always returns to Point Tool). Active tool state lives in `SessionViewModel`.

## Point Tool

To be expanded. Default tool, keyboard shortcut V. Handles all single-point operations without requiring tool switches: click-to-select, drag-to-move, click-on-line-to-add-point, right-click for context menu (Delete, Edit Coordinates, Snap to Ground, Promote to Waypoint, Set as Segment Boundary, Select Entire Segment), drag-in-empty-space for rectangular marquee selection. Right-click in empty space gives a different context menu (Place Waypoint Here). See D-014 for the rationale and the Adze frustration this fixes.

## Hand Tool

To be expanded. Keyboard shortcut H. Click-and-drag the map to pan, no editing interactions while active. Spacebar held in any other tool temporarily switches to Hand Tool (cursor changes, drag pans, release returns to previous tool). Mid-drag spacebar pan (continuation of in-progress drag at new viewport position) is deferred per D-014.

## Lasso Tool

To be expanded. Keyboard shortcut L. Free-form polygon selection — drag along a path to enclose points. Used for irregularly-shaped clusters where a rectangle won't do (e.g., curving rest-stop blob).

## Waypoint Place Tool

To be expanded. Keyboard shortcut W. Click drops a waypoint at the cursor location with the currently-selected icon from the curated icon set. Icon selector popover lives at the toolbar. The curated icon set: ~15 hiking/outdoor symbols (Campsite, Water, Restroom, Trailhead, Summit, Vista, Parking, Hazard, Information, Bridge, Ford, Gate, Photo, Crossing, Generic). Names align with Garmin `<sym>` vocabulary for export compatibility. Rendered in-app via SF Symbols where they exist or small custom SVGs where they don't.

## BrushTool family

To be expanded. The four brush tools share a unified abstraction (D-015). Top-level `BrushTool` protocol handles shared infrastructure: gesture tracking, live preview during drag, undo grouping, commit-on-release. Two specializations: `RegionBrushTool` (operates on existing points within a circular region around the cursor) and `PathBrushTool` (generates new points along the cursor path). Each individual brush conforms to one specialization and provides only its specific point-operation logic.

### Simplify Brush

To be expanded. Keyboard shortcut 1. Conforms to `RegionBrushTool`. Applies Ramer-Douglas-Peucker simplification to points within the brush region. Tolerance parameter is fixed at v1 default; live preview shows the result during drag.

### Smooth Brush

To be expanded. Keyboard shortcut 2. Conforms to `RegionBrushTool`. Each point in the region is averaged with its neighbors weighted by a smoothing kernel. Kernel and kernel size fixed at v1 defaults.

### Average Brush

To be expanded. Keyboard shortcut 3. Conforms to `RegionBrushTool`. For each master track point in the brush region, finds all subsidiary track points within the same radius around that master point's location, takes the uniform (unweighted) average of their lat/lon, moves the master point fully to that averaged position. Subsidiaries with no nearby points contribute nothing. Live preview during drag, commits as one undo unit. v1 algorithm and parameters per D-016. Iteration paths if v1 doesn't feel right are listed in D-016 consequences.

### Add Detail Brush

To be expanded. Keyboard shortcut 4. Conforms to `PathBrushTool`. Generates new points along the cursor path at a configurable density, inserting them into the current track between the gesture's start and end points. Used for filling in signal-loss gaps where GPS dropped out.

## Operations (in `Services/`)

To be expanded. Operations are not tools; they are commands triggered from menus or toolbar buttons against the current selection (or the whole project / master, depending on the operation, per the selection-aware-operations rule in CONVENTIONS.md). Each operation registers with `NSUndoManager` with a meaningful action name.

- **Trim Track** (D-018) — Edit menu, opens dialog with optional start-time and end-time trim sections, live preview, commits as one undo unit. Time-only in v1; speed-based trim is in the deferred parking lot.
- **Remove GPS Spikes** (D-017) — toolbar button or menu, one-shot detection-and-delete with undo. Two heuristics in v1: instantaneous-speed threshold and lat/lon deviation from neighbor moving average.
- **Reset to Original** — per-track action, replaces current working state with a freshly parsed copy of the immutable original bytes.
- **Snap to Ground** (per-point) — Point Tool right-click context menu, single-point elevation correction via OpenTopoData.
- **Pin to Ground** (selection or whole-master) — toolbar or menu, batched DEM elevation correction. Network call to `api.opentopodata.org` per SECURITY.md allow-list. Confirmation dialog and progress indicator.
- **Split** — splits a track at the selected point into two tracks.
- **Merge** — appends a second track's content to this one, with confirmation dialog.
- **Reverse** — flips the order of points in a track.
- **Promote Point to Waypoint** — Point Tool right-click; converts a track point to a named waypoint at the same location.
- **Set Segment Boundary** — Point Tool right-click; splits a track at the point, creating a new segment.

## Selection-aware operations

To be expanded. Project-wide rule: operations that could apply to selection-or-broader-scope use the selection if one exists, otherwise apply to the natural broader scope (whole track for trim-style operations, master for export-style operations, whole project for project-wide operations). See CONVENTIONS.md "Selection-aware operations."

## Cross-references

- `DECISIONS.md` D-014 (editing tools roster), D-015 (brush family architecture), D-016 (average brush algorithm), D-017 (GPS spike detection), D-018 (track trim)
- `CONVENTIONS.md` Selection-aware operations, Direct manipulation principle, Tool-switching is cheap
- `Docs/02_MAP_AND_BRIDGE.md` Bridge messages used by tools and operations
- `Docs/05_UI.md` Toolbar, Inspector, and view integration of tools
