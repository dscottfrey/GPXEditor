# 01 — Document Subsystem (STUB)

> **Status: stub.** Section headings outline intended scope; bodies are placeholders that summarize what is already decided in `DECISIONS.md` and `CONVENTIONS.md`. Full bodies to be drafted in a future Cowork session before M2 begins (M0 and M1 do not require this document to be complete).

## Scope

The Document subsystem covers GPX I/O, the in-memory data model, parsing GPX files into the model, writing the model back out as GPX or KML, and the `.gpxeditor` JSON project file format including its load/save logic. The subsystem spans `Models/` (data types) and `Services/` (parsers, writers, codecs). See D-001 through D-003 for naming and architectural posture; D-008 for the non-destructive document model; D-010 for the project file format; D-012 for the export model.

## Data model (in `Models/`)

To be expanded. Types: `GPXSession` (the top-level project state), `Track` (an ingested GPX track with its immutable original bytes plus current working state), `Segment` (a contiguous run of points with its own color), `TrackPoint` (lat/lon plus optional elevation, no per-point timestamps in working state), `Waypoint` (named point with icon), `MasterRole` (enum: master/subsidiary/unaffiliated), project metadata (name, creation/modified dates). Types are value types where feasible (per CONVENTIONS.md immutability discipline). No AppKit imports (per CONVENTIONS.md platform-agnostic-data-layer rule).

## GPX parser (in `Services/`)

To be expanded. Uses stdlib `XMLParser`. Handles GPX 1.0 and 1.1, XML namespaces, common Garmin/Strava extensions (preserving unknown extensions through round-trip rather than parsing them). Error handling per the nothing-fails-silently rule in CONVENTIONS.md. Returns either a parsed `GPXFile` or a structured parse error.

## GPX writer (in `Services/`)

To be expanded. Produces valid GPX 1.1 output. File-level `<metadata><time>` from the master's recorded date/time. `<trkpt>` elements include `<lat>`, `<lon>`, and optionally `<ele>`; per-point `<time>` is omitted (D-012). Segments preserved as multiple `<trkseg>` elements within a single `<trk>`. No vendor color extensions (D-013). Optional KML writer follows the same model with KML's structural mapping.

## Project file format (`.gpxeditor`)

To be expanded. Single JSON document containing format version, project metadata, per-track records (each with immutable original bytes as a string, current working state, master/subsidiary role, segment list with per-segment colors and waypoints, display metadata), the active basemap selection, view-port state. No external file references, no source-file hashes, no operation log (D-010). Schema versioning: forward compatibility by never removing fields and adding new fields with sensible defaults; backward compatibility is best-effort with clean rejection on encountering newer formats.

## Reset to Original

To be expanded. Per-track action that discards the current working state and replaces it with a freshly parsed copy of the immutable original bytes. The track's identity, color, position in the master/subsidiary hierarchy, and other display metadata are preserved; only the point geometry resets. Registered as a single undo unit.

## Crash autosave

To be expanded. Periodic snapshot of the current `GPXSession` to a scratch location (Apple's standard autosave directory). On app relaunch, if a newer scratch file exists than the user's last-saved project, the user is prompted to recover. Frequency: 30 seconds when changes are pending (Apple default). Format identical to the saved project file.

## Testing

To be expanded. Round-trip tests in `GPXEditorTests/Services/` against real-world GPX files (Garmin, Strava, hand-edited; see `Docs/06_FIXTURES.md`). Parse-then-write should produce structurally equivalent files. Edge cases: GPX 1.0 vs 1.1, missing elevation, missing timestamps, single-segment vs multi-segment, namespace declarations, empty tracks, single-point tracks.

## Cross-references

- `DECISIONS.md` D-001 (display name), D-002 (license), D-008 (document model), D-010 (project file format), D-012 (export model)
- `CONVENTIONS.md` File organization, Small files, Platform-agnostic data layer, Nothing fails silently
- `SECURITY.md` Sandbox entitlements (user-selected files read-only and read-write)
- `Docs/06_FIXTURES.md` Sample GPX file rules
