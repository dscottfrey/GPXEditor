# synth-degenerate-counts.gpx

**Classification:** synthetic.  Audit policy (per `Docs/06_FIXTURES.md`):  fictional
coordinates anchored at Null Island, zero personal data, safe for the post-
public-flip era.

## What this fixture is

A GPX 1.1 file with one track containing:

- One **empty** `<trkseg>` — zero `<trkpt>` children.
- One **single-point** `<trkseg>` — exactly one `<trkpt>`.

Both edge cases live in one fixture because they exercise the same class
of bug (degenerate counts at the loop boundaries) and a real recording
could plausibly contain both shapes in a single track.

## Why this fixture exists

GPX makes no minimum-count guarantee on `<trkseg>` content:  segments with
zero or one point are syntactically valid.  Real recordings produce both:

- **Empty segments** show up when a recording is started and immediately
  stopped (e.g., the user accidentally taps Start then Stop before the GPS
  acquires a fix), or when a tool like GPSBabel splits a recording on
  signal-loss boundaries and one of the resulting segments is empty.
- **Single-point segments** show up when a user pauses immediately after
  starting, or when filtering tools delete all but one point in a segment
  during cleanup.

The parser must not crash, drop the parent track, or mis-route the next
element when it encounters either shape.  Specifically:

- Empty segments must be appended to their track's `segments` array with
  `points.count == 0`.  A bug that only appended segments-with-points
  would silently drop the structural information.
- Single-point segments must contain exactly one `RawPoint`.  A bug that
  only appended segments after seeing the second point would lose them.

Most renderers handle these shapes by simply not drawing a polyline (a
zero- or one-point polyline has no edges).  But the data-model invariant
must hold:  the fixture's track has 2 segments, period.

## Tests that consume this fixture

`GPXEditorTests/Services/GPXParserTests.swift` —
`parsesDegenerateSegmentCounts()` asserts:

- One track is parsed
- The track has exactly 2 segments (the empty one is preserved)
- segments[0].points.count == 0
- segments[1].points.count == 1
- The single point in segments[1] has the expected lat/lon/ele
