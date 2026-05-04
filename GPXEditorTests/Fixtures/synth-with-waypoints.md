# synth-with-waypoints.gpx

**Classification:** synthetic.  Audit policy (per `Docs/06_FIXTURES.md`):  fictional
coordinates anchored at Null Island, zero personal data, safe for the post-
public-flip era.

## What this fixture is

A GPX 1.1 file with three file-level `<wpt>` elements and a small track:

- **Waypoint 0** — fully populated: name, sym, desc, elevation.
- **Waypoint 1** — name and sym only; no elevation, no desc.
- **Waypoint 2** — bare minimum: just lat/lon.  Self-closing `<wpt/>`.
- A two-point track alongside, unrelated to the waypoints' positions.

## Why this fixture exists

GPX puts waypoints at the document level (peer to `<trk>`).  Three things
need to work:

- Waypoint fields parse correctly in their various combinations.  The fully-
  populated case verifies the whole field set; the partial cases verify
  optional fields produce nil rather than empty strings or sentinels.
- Waypoints and tracks coexist without cross-contamination.  A bug in the
  parent-context routing of `<name>` could attach the waypoint name to the
  track, or vice versa — this fixture has both kinds of `<name>` and
  asserts they end up on the right entities.
- The bare-minimum self-closing `<wpt/>` form is handled correctly.  No
  text content, no children — but it still must produce a `RawWaypoint`
  with the lat/lon set.

## Tests that consume this fixture

`GPXEditorTests/Services/GPXParserTests.swift` —
`parsesWaypoints()` asserts:

- Three waypoints produced
- Waypoint 0 has all fields populated
- Waypoint 1 has nil for elevation and description
- Waypoint 2 has nil for everything except lat/lon
- The track is present alongside, with its own name on the track (not
  cross-contaminated with any waypoint name)
