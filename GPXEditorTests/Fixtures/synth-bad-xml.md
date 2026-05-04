# synth-bad-xml.gpx

**Classification:** synthetic.  Audit policy: fictional content; designed to fail
parsing.  Anchored at Null Island.

## What this fixture is

A GPX-shaped document with **deliberately mismatched tags**:  the `<name>`
element is opened but never closed before `<trkseg>` starts, which violates
XML well-formedness.

## Why this fixture exists

Tests the parser's `.invalidXML(message:)` failure path — the underlying
`XMLParser` raises a syntax error, and our delegate wraps it into
`GPXParseError.invalidXML` with line/column info folded into the message.

## Tests that consume this fixture

`GPXEditorTests/Services/GPXParserTests.swift` —
`failsOnMalformedXML()` asserts the parser returns `.failure(.invalidXML(...))`.
The exact message string is not asserted — that's tooling output that varies
across XMLParser implementations.
