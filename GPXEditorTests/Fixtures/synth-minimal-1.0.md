# synth-minimal-1.0.gpx

**Classification:** synthetic.  Audit policy (per `Docs/06_FIXTURES.md`):  fictional
coordinates anchored at Null Island, zero personal data, safe for the post-
public-flip era.

## What this fixture is

A minimal GPX 1.0 document.  Same content shape as `synth-minimal-1.1.gpx`
but in the older 1.0 schema:  file-level metadata (`<name>`, `<time>`) appears
as direct children of `<gpx>` rather than wrapped in a `<metadata>` element.
Track data (`<trk>`, `<trkseg>`, `<trkpt>`) is identical between 1.0 and 1.1.

Two `<trkpt>` elements (rather than three as in the 1.1 fixture) — just
enough to confirm version-independent track parsing without making the
fixture larger than it needs to be.

## Why this fixture exists

GPX 1.0 was released in 2002 and remains in the wild despite GPX 1.1 (2007)
being the dominant version for ~18 years.  Older converted files, GPSBabel
exports of legacy data, and geocaching tracks from the 2005-2010 era still
arrive as 1.0.  A robust GPX editor should handle both forms transparently —
the user shouldn't have to know what version their file is to load it.

The parser's `<name>` and `<time>` switch arms accept parent `"metadata"`
(1.1 placement) or `"gpx"` (1.0 placement) for the file-level metadata
fields, so this fixture confirms the 1.0 path produces the same `RawGPX`
fields as the 1.1 fixture would.

## Tests that consume this fixture

`GPXEditorTests/Services/GPXParserTests.swift` —
`parsesMinimalGPX10()` asserts:

- `version == "1.0"` (distinguishes from the 1.1 fixture)
- `metadataName == "Minimal 1.0 fixture"` (set from `<gpx><name>`, not `<gpx><metadata><name>`)
- `metadataTime == 2026-01-01T00:00:00Z` (set from `<gpx><time>`)
- track data matches the file content exactly
