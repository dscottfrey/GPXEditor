# synth-bad-version.gpx

**Classification:** synthetic.  Audit policy: fictional content; designed to fail
parsing.  Anchored at Null Island.

## What this fixture is

A GPX-shaped document declaring `version="0.5"` — a version that never
existed.  Stand-in for any future or legacy version we don't support
(GPX 0.x would be hypothetical legacy; a future GPX 2.0 would be
hypothetical future).

## Why this fixture exists

Tests the parser's `.unsupportedVersion(String)` failure path.  The parser
accepts `"1.0"` and `"1.1"` and rejects everything else loud — better to
fail explicitly than to walk an unknown-shape document with our 1.0/1.1
logic and silently produce wrong output.

## Tests that consume this fixture

`GPXEditorTests/Services/GPXParserTests.swift` —
`failsOnUnsupportedVersion()` asserts the parser returns
`.failure(.unsupportedVersion("0.5"))`.
