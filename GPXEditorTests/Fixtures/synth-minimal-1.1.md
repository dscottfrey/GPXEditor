# synth-minimal-1.1.gpx

**Classification:** synthetic.  Audit policy (per `Docs/06_FIXTURES.md`):  fictional
coordinates anchored at Null Island (0°N 0°E approximately), zero personal data,
safe for the post-public-flip era.

## What this fixture is

The smallest valid GPX 1.1 document the parser needs to handle correctly.  One
track ("Synthetic Null Island stroll") with one `<trkseg>` containing three
`<trkpt>` elements that each carry `<ele>` and `<time>`.  File-level
`<metadata>` includes both `<name>` and `<time>`.  No waypoints.  No vendor
extensions.

This is the baseline "happy path" — every other fixture in this folder is a
delta against this one (missing field, multiple segments, a different version,
a structural error).

## Coordinates

Three points stepping 0.0001° east-and-north each, starting at (0.0001, 0.0001).
Total path length is approximately 30 meters — close enough to Null Island to
be visibly synthetic at a glance, far enough from exactly (0, 0) that the
points distinguish themselves under inspection.

Elevations are 10 m, 11 m, 12 m.  Timestamps are ten seconds apart starting
at 2026-01-01T00:00:00Z.  All values are deliberately tidy round numbers so a
test reading them can assert exact equality.

## Tests that consume this fixture

`GPXEditorTests/Services/GPXParserTests.swift` —
`parsesMinimalGPX11()` asserts every field of the resulting `RawGPX` matches
the file content exactly:  version, creator, metadata name and time, track
name, segment count (1), point count (3), and per-point lat/lon/ele/time
values.

## Why this fixture exists

A regression in any of the parser's basic responsibilities — recognizing the
`<gpx>` root, capturing version/creator attributes, walking into `<metadata>`
and `<trk>` correctly, parsing ISO 8601 timestamps, parsing decimal-string
lat/lon attributes, parsing `<ele>` text content, appending points to
segments, appending segments to tracks, appending tracks to the result —
will surface as a failure on this fixture before we even consider the edge
cases.  Keep this fixture trivial; complexity belongs in the deltas, not the
baseline.
