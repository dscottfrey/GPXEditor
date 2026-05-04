# synth-wrong-root.gpx

**Classification:** synthetic.  Audit policy: fictional content; designed to fail
parsing.  Anchored at Null Island.

## What this fixture is

A well-formed XML document whose root element is `<svg>`, not `<gpx>`.  Files
of this shape arrive when a user accidentally drops a non-GPX file on the
import dialog (an SVG, an Atom feed, an arbitrary XML config) and the
`.gpx` extension was renamed by hand.

## Why this fixture exists

Tests the parser's `.unexpectedRootElement(found:)` failure path.  Without
this check the parser would walk the SVG tree producing no tracks, no
waypoints, and no errors — a confusingly silent failure mode.  Surfacing
the wrong-root condition early gives the user a clear "this isn't a GPX
file" message.

## Tests that consume this fixture

`GPXEditorTests/Services/GPXParserTests.swift` —
`failsOnWrongRoot()` asserts the parser returns
`.failure(.unexpectedRootElement(found: "svg"))`.
