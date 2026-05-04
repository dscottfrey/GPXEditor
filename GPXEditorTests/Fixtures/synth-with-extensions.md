# synth-with-extensions.gpx

**Classification:** synthetic.  Audit policy (per `Docs/06_FIXTURES.md`):  fictional
coordinates anchored at Null Island, zero personal data, safe for the post-
public-flip era.

## What this fixture is

A GPX 1.1 file with two flavors of vendor extensions, both declared with
namespace prefixes on the root element:

- **`gpxtpx:TrackPointExtension`** inside each `<trkpt><extensions>` —
  Garmin's per-point telemetry (heart rate, cadence, ambient temperature).
  This is the most common extension in the wild; it appears in nearly every
  Garmin Connect, Strava, and watch-app GPX export.
- **`gpxx:TrackExtension`** at the track level — Garmin's display-metadata
  extension carrying `gpxx:DisplayColor`.  Less common but exercises the
  track-level extension code path.

Two `<trkpt>` elements so the test can confirm both extension blocks are
ignored uniformly (not just the first).

## Why this fixture exists

Per D-008 / Q2 from the M1 design pass, vendor extensions are deliberately
ignored by the parser.  The working-state `RawPoint` and `RawTrack` models
have no fields for heart rate, cadence, display color, or any other
vendor-specific data — extensions survive a round-trip via the
`immutableOriginalBytes` blob (the original GPX file's bytes, preserved
verbatim per D-008), and the writer never emits them on export per D-012.

This fixture verifies three behaviors:

1. **The parser doesn't crash or fail on prefixed element names.**  With
   `shouldProcessNamespaces` left at its default of `false`, prefixed
   elements like `gpxtpx:hr` come through with their prefix intact and
   naturally don't match any of our switch cases.  A bug that turned
   namespace processing on could cause `gpxx:name` to accidentally match
   our `<name>` handler and produce wrong results.
2. **Extension content is silently dropped.**  No telemetry shows up in
   the parsed `RawPoint` because there's no field for it.  Tests assert
   the points have only the standard `lat`, `lon`, `ele`, `time` fields
   populated.
3. **The standard fields inside `<trkpt>` (`<ele>`, `<time>`) parse
   correctly even when followed by an `<extensions>` sibling.**  A bug in
   parent-context routing could cause the `<time>` inside
   `<gpxtpx:TrackPointExtension>` to accidentally overwrite the
   trkpt-level time — but with `shouldProcessNamespaces=false` the inner
   element is `gpxtpx:something`, parent is `gpxtpx:TrackPointExtension`,
   neither of which matches our switch cases.

## Tests that consume this fixture

`GPXEditorTests/Services/GPXParserTests.swift` —
`parsesAndIgnoresExtensions()` asserts:

- The track has 2 points
- Each point has the expected lat/lon/ele/time
- The parser succeeds (no error from the unfamiliar prefixed elements)
- (The fact that no other fields exist is implicit — `RawPoint` only has
  the four standard fields, so extension data has nowhere to go even if
  the parser tried to capture it)
