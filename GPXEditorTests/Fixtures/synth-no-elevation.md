# synth-no-elevation.gpx

**Classification:** synthetic.  Audit policy (per `Docs/06_FIXTURES.md`):  fictional
coordinates anchored at Null Island, zero personal data, safe for the post-
public-flip era.

## What this fixture is

A GPX 1.1 file with one track of four `<trkpt>` elements:  the first and
third have `<ele>`, the second and fourth don't (they're self-closing
`<trkpt lat="..." lon="..."/>`).  No `<time>` on any point — orthogonal to
the elevation question.

## Why this fixture exists

GPX makes `<ele>` optional, and many recordings in the wild omit it:

- Cheap GPS units and some phone apps don't capture barometric or GPS
  elevation reliably and skip the field.
- Track-conversion tools (GPSBabel, online GPX cleaners) sometimes strip
  `<ele>` to reduce file size.
- Strava exports occasionally drop elevation on points where the source
  recording had a momentary signal loss.

The parser must handle this transparently:  `RawPoint.elevation` is `Double?`
in the data model, and a missing `<ele>` should produce `nil`, not a sentinel
value (0.0, NaN, or the previous point's elevation).  This fixture makes that
behavior explicit and testable.

The mixed presence (two points with elevation, two without) is more
discriminating than a uniformly-absent fixture would be:

- A bug that propagates the previous point's elevation forward would set
  point[1].elevation = 10.0 (carried from point[0]) instead of nil.
- A bug that defaults missing elevations to 0.0 would set point[1].elevation
  = 0.0 instead of nil.

Both bugs would silently corrupt elevation profiles in the Stats panel
(M8) and the Pin to Ground feature (M7) without producing visible parse
errors.  This fixture catches them.

## Tests that consume this fixture

`GPXEditorTests/Services/GPXParserTests.swift` —
`parsesPointsWithMissingElevation()` asserts:

- All four points present
- Point 0 has elevation 10.0
- Point 1 has elevation nil
- Point 2 has elevation 12.0
- Point 3 has elevation nil
