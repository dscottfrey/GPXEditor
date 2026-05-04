# synth-missing-lat.gpx

**Classification:** synthetic.  Audit policy: fictional content; designed to fail
parsing.  Anchored at Null Island.

## What this fixture is

A GPX 1.1 document with a `<trkpt lon="0.0001"/>` — the `lon` attribute is
present but `lat` is absent.  Mirrors a corrupt GPX export or a hand-edited
file where the user accidentally deleted the lat attribute.

## Why this fixture exists

Tests the parser's `.missingRequiredAttribute(element:attribute:)` failure
path.  Distinguishes from `.malformedCoordinate` — the parser reports
"missing" when the attribute is absent and "malformed" only when the
attribute is present but unparseable.

## Tests that consume this fixture

`GPXEditorTests/Services/GPXParserTests.swift` —
`failsOnMissingLat()` asserts the parser returns
`.failure(.missingRequiredAttribute(element: "trkpt", attribute: "lat"))`.
