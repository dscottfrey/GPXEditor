# synth-bad-timestamp.gpx

**Classification:** synthetic.  Audit policy: fictional content; designed to fail
parsing.  Anchored at Null Island.

## What this fixture is

A GPX 1.1 document with a `<trkpt>` whose `<time>` text is the literal string
"not a real timestamp" — neither plain ISO 8601 nor the fractional-second
form will parse it.

## Why this fixture exists

Tests the parser's `.malformedTimestamp(value:)` failure path.  Both
ISO8601DateFormatter variants in the parser's `parseDate(_:)` helper fail,
and the parser raises a structured error rather than silently storing a
nil timestamp (which would lose the failure signal — the user thinks the
file is fine but elsewhere parts of the app silently behave differently
because of the missing data).

## Tests that consume this fixture

`GPXEditorTests/Services/GPXParserTests.swift` —
`failsOnMalformedTimestamp()` asserts the parser returns
`.failure(.malformedTimestamp(value: "not a real timestamp"))`.
