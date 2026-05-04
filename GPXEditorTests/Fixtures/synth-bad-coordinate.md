# synth-bad-coordinate.gpx

**Classification:** synthetic.  Audit policy: fictional content; designed to fail
parsing.  Anchored at Null Island.

## What this fixture is

A GPX 1.1 document with a `<trkpt lat="not-a-number" lon="0.0001"/>` —  the
`lat` attribute is present but isn't parseable as a Double.  Mirrors the
real-world failure mode where a corrupted GPX export contains malformed
numeric attributes (rare but possible from older conversion tools).

## Why this fixture exists

Tests the parser's `.malformedCoordinate(element:attribute:value:)` failure
path.  The parser must distinguish "attribute is missing" (which is a
different error, `.missingRequiredAttribute`) from "attribute is present
but unparseable" (this case).

## Tests that consume this fixture

`GPXEditorTests/Services/GPXParserTests.swift` —
`failsOnMalformedCoordinate()` asserts the parser returns
`.failure(.malformedCoordinate(element: "trkpt", attribute: "lat", value: "not-a-number"))`.
