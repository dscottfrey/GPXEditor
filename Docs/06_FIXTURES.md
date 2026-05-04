# 06 — Test Fixtures (STUB)

> **Status: stub.** Section headings outline intended scope; bodies are placeholders. The substantive policy is already in CLAUDE.md "Public release posture" and HANDOFF.md "Pre-public-release checklist." This directive expands it operationally for the maintainer adding fixtures and for the audit step before the public flip.

## Scope

`GPXEditorTests/Fixtures/` holds sample GPX files used as test inputs across the test suite. This directive describes what files may live there during the development phase, the audit policy that gates the public-flip moment, naming conventions, and the synthetic-vs-public-trail distinction. Personal-data policy is repo-visibility-aware (D-005); this document is the operational reference for the people committing fixtures.

## During the private-repo phase (current state)

To be expanded. While the repository is private, fixtures may include any GPX file useful for development:

- Hand-crafted synthetic fixtures designed to exercise specific parser features (GPX 1.0 vs 1.1, namespace declarations, Garmin TrackPointExtension, Strava extensions, missing elevation, missing timestamps, single-point tracks, empty tracks).
- Hand-crafted "messy" fixtures for editing-feature tests (rest-stop clusters, elevation noise, GPS spikes, self-overlapping passes).
- Real-world public-trail recordings from the developer's GPS device — as long as the trail itself is a public location.
- Edge-case files captured from Garmin or Strava exports that surface real format quirks.

What is **never** committed regardless of repo visibility: credentials, Apple Developer team IDs, notarization API keys, signing certificates, keychain exports. Those are absolute, not visibility-dependent.

## Pre-public-release audit

To be expanded. Before flipping the repository to public (the gate condition described in D-005 / HANDOFF.md pre-public-release checklist):

1. Walk through every file in `GPXEditorTests/Fixtures/` one at a time.
2. For each file, verify it is either (a) synthetic — coordinates clearly fictional, often centered on `0°N 0°E` or in the middle of an ocean, or (b) from a clearly public location — a known public trail, park, or other public-by-default outdoor venue.
3. Any file that reveals home, work, or routine personal routes is removed before the flip.
4. Any file whose origin is unclear or undocumented is removed unless it can be re-classified.
5. The audit completion is checked off in HANDOFF.md's pre-public-release checklist with a date and short note.

After the public flip, new fixtures committed must remain synthetic or from public-trail recordings. Personal tracks used for one-off debugging would live in `GPXEditorTests/PrivateFixtures/` (gitignored) if and when that folder becomes needed — not necessary to create up front.

## Naming conventions

To be expanded. Each fixture file gets a short descriptive name plus a category prefix. Examples:

- `synth-rdp-input.gpx` — synthetic, designed for RDP simplification testing
- `synth-multipass.gpx` — synthetic, two passes of the same trail for Average brush testing
- `synth-noisy.gpx` — synthetic, GPS spikes for spike-detection testing
- `real-trail-publictrail-2025.gpx` — real recording, public-trail
- `garmin-tpx-extensions.gpx` — real Garmin export, exercises TrackPointExtension parsing

Each fixture file has a corresponding `<filename>.md` documentation file in the same folder describing what the fixture represents, what tests use it, and (for real recordings) the public-location confirmation. The `.md` companion is what the audit reviewer reads to verify the file's classification.

## Synthetic fixture construction

To be expanded. Hand-crafted GPX files are simply text files containing valid GPX XML. They can be created by hand-editing a template, by writing a small Swift or Python helper that emits GPX given parameters, or by recording a synthetic track in a tool that produces clean GPX. The point is that synthetic fixtures are reproducible from documented parameters and don't require any external recording hardware.

For coordinate placement of synthetic fixtures, anchor them at obviously-fictional coordinates (the `0°N 0°E` "Null Island" location is conventional; mid-Pacific or mid-Atlantic also work) so the synthetic-versus-real distinction is visible at a glance.

## The PrivateFixtures option

To be expanded. If during the public phase a real personal track is needed for one-off debugging — never for committed tests — a `GPXEditorTests/PrivateFixtures/` folder may be created with a `.gitignore` rule blocking it from commits. Tests that depend on private fixtures run only when the private folder is populated, skipping with a clear "private fixture not available" message otherwise. This folder is **not** required up front; create only if and when needed.

## Cross-references

- `DECISIONS.md` D-005 (repo visibility timeline)
- `CLAUDE.md` Public release posture, Personal-data policy
- `HANDOFF.md` Pre-public-release checklist (the audit step lives there as a check item)
- `Docs/01_DOCUMENT.md` Tests in `GPXEditorTests/Services/` consume these fixtures
