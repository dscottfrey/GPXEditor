# synth-multi-trkseg.gpx

**Classification:** synthetic.  Audit policy (per `Docs/06_FIXTURES.md`):  fictional
coordinates anchored at Null Island, zero personal data, safe for the post-
public-flip era.

## What this fixture is

A GPX 1.1 file with one `<trk>` containing **two `<trkseg>` elements**.  The
first segment has two points starting at (0.0001, 0.0001); the second segment
has three points starting at (0.0010, 0.0010) — a deliberate gap between the
two segments so a renderer connecting all points blindly with a polyline
would produce a visibly wrong result.

Per-point timestamps are deliberately absent from this fixture (only `<ele>`
is included on each `<trkpt>`).  Time is exercised in `synth-minimal-1.1.gpx`
already; this fixture's purpose is segment structure.

## Why this fixture exists

D-012 requires the GPX writer to preserve segment structure ("the exported
`<trk>` contains multiple `<trkseg>` elements, one per visual segment in the
master's working state, retaining the user's editing structure").  That
contract begins at the parser:  the model must distinguish two-segment input
from one-segment input.  If the parser silently merged segments here, the
self-overlap use case from D-016 (two passes of the same trail averaged
together while remaining distinct as `<trkseg>` elements) would be impossible
to support.

The fixture also doubles as a check that the parser correctly opens, closes,
and routes the second `<trkseg>` — a one-trkseg-only parser bug would silently
swallow the second segment's points or attach them to the first.

## Tests that consume this fixture

`GPXEditorTests/Services/GPXParserTests.swift` —
`parsesMultiSegmentTrack()` asserts:

- Track count is 1 (not 2 — multi-segment is one track with multiple segments)
- Segment count is 2
- First segment has 2 points; second segment has 3 points
- The points in each segment match the fixture exactly (gap between the two
  segments confirms they didn't merge)
