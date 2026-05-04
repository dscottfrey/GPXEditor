# synth-fractional-time.gpx

**Classification:** synthetic.  Audit policy (per `Docs/06_FIXTURES.md`):  fictional
coordinates anchored at Null Island, zero personal data, safe for the post-
public-flip era.

## What this fixture is

A GPX 1.1 file with three `<trkpt>` elements whose `<time>` values include
fractional seconds:  `.000`, `.500`, `.250`.  The metadata `<time>` also
uses the fractional form.  Sub-second precision varies (000ms, 500ms, 250ms)
to confirm the parser captures the actual fractional value rather than
silently truncating.

## Why this fixture exists

`ISO8601DateFormatter` with `.withInternetDateTime` only matches whole-second
ISO 8601 strings.  Adding `.withFractionalSeconds` is required for the
sub-second variant.  The parser keeps two formatter instances and tries
the plain one first, falling back to the fractional one — see
`GPXParser.swift`'s `parseDate(_:)` helper.

Strava, Garmin watches with sub-second sampling, and some fitness apps emit
fractional-second timestamps; some others do not.  The parser must accept
both shapes transparently.

A bug that only kept the plain-seconds formatter would silently fail this
fixture with `.malformedTimestamp` errors on every point — making the
fixture's failure mode loud and obvious rather than subtle.

## Tests that consume this fixture

`GPXEditorTests/Services/GPXParserTests.swift` —
`parsesFractionalSecondTimestamps()` asserts:

- All three points parse without error
- Their timestamps match the fractional-second values exactly:
  - point[0].time == 2026-01-01T00:00:00.000Z
  - point[1].time == 2026-01-01T00:00:00.500Z
  - point[2].time == 2026-01-01T00:00:01.250Z
- The metadata time is also captured with fractional precision
