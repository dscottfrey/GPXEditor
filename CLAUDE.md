# GPXeditor — Project Orientation

This file is the entry point for any Claude session working on this project. Before doing anything else — answering questions, writing code, modifying files — read the directives below in this order:

1. `SECURITY.md` — what this app is and is not allowed to do, sandboxing posture, dependency rules. Non-negotiable.
2. `DECISIONS.md` — architectural choices and the reasoning behind them. Do not re-litigate without a documented update.
3. `CONVENTIONS.md` — code patterns, naming, error handling, the JS↔Swift bridge protocol.
4. `HANDOFF.md` — current state of the build, next milestone, open questions.
5. The relevant directive doc in `Docs/` for any subsystem you're about to modify (e.g., `Docs/02_MAP_AND_BRIDGE.md` before changing the map view, `Docs/04_EDITING.md` before adding a new brush or operation).

If any of those files are missing, stop and tell the user before proceeding.

## What this project is

A native macOS application called **GPXeditor** that opens, edits, and saves GPX track files. It replaces the discontinued Adze (getadze.com), excluding all route-planning features. Built primarily for Scott's personal use, but with a public release on GitHub as an explicit goal — both the source and the signed/notarized .app should be give-away artifacts that other Mac users can pick up and run. The motivation: Adze is the only Mac app that filled this niche, its developer's domain is now a defunct spam site, and there is no current Mac-native alternative for this set of features. Mac-only. Sandboxed and code-signed.

## Architecture in one paragraph

SwiftUI app shell using `FileDocument` for native macOS file handling (drag-onto-dock, Finder file association, save dialogs, undo/redo). The map editing UI is **Leaflet.js** with OpenStreetMap tiles, hosted inside a `WKWebView` that's wrapped as a SwiftUI `NSViewRepresentable`. Swift is the source of truth for all model state and editing operations; JavaScript handles only rendering and live previews. The two communicate via a strict message protocol described in `CONVENTIONS.md`. GPX parsing/writing is pure Swift using stdlib `XMLParser`. No third-party Swift Package Manager dependencies in the initial build. Web assets (`leaflet.js`, `simplify.js`, `editor.js`, `index.html`, `leaflet.css`) are vendored into the bundle and hash-pinned — no CDN, no `package.json`, no `npm install` ever.

## What this project is not

- Not a route planner. No "plan a future trip" features, no turn-by-turn, no waypoint-based navigation generation. Adze had these; we are deliberately not replicating them.
- Not a sync service. No accounts, no cloud, no sharing.
- Not cross-platform in v1. macOS only. An iOS/iPadOS sibling app may happen later as a separate project; the data and editing layers (code in `Models/` and the GPX-handling and editing parts of `Services/`) should therefore be written portably — no AppKit, SwiftUI, or WebKit imports in those types — so a future port is feasible. Do not add iOS-specific scaffolding now.
- Not a commercial product. No paid tiers, no telemetry, no analytics, no version-check-on-launch, no crash-reporting service. The signed/notarized .app is given away free.

## Public release posture

This project is built to be released publicly on GitHub. That changes a few defaults from a typical "just for me" project and is worth stating up front:

- **Repo visibility timeline.** Private during development; flipped public when the project is ready for its first release. The flip is deliberately gated — it happens after (1) the Developer ID Application certificate is active and signing/notarization works end-to-end, (2) the fixture audit is complete (see personal-data policy below), (3) `README.md`, `LICENSE`, and credits are in place, (4) `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, and issue templates are written, and (5) at least one signed/notarized DMG is buildable from a clean checkout. Tracked in `HANDOFF.md` under "Pre-public-release checklist." Until the flip, normal "private repo" rules apply — no public-facing artifacts are required, and discussions/decisions can refer to private context freely.
- **License: MIT.** Maximally permissive — anyone may use, modify, redistribute, or fork the source freely, including for commercial use, provided the copyright notice and the MIT license text are preserved. A `LICENSE` file at the repo root contains the standard MIT text with Scott Frey's copyright. The decision rationale lives in `DECISIONS.md`.
- **Personal-data policy is repo-visibility-aware.** While the repo is private (the entire development phase): test fixtures may include any GPX file useful for development — hand-crafted synthetic fixtures, Scott's real-world recordings of public-trail outings, edge-case files captured from his Garmin/Strava exports, anything. **Credentials, Apple Developer team IDs, notarization API keys, signing certificates, and keychain exports are never committed regardless of repo visibility** — those are absolute, not visibility-dependent. **Before flipping the repo public, an audit of `GPXEditorTests/Fixtures/` is required**: verify each committed track is either synthetic or from a clearly public location (a known public trail, park, or other public-by-default outdoor venue), and remove any track that reveals home, work, or routine personal routes. After the public flip, new fixtures must remain synthetic or from public-trail recordings. Personal tracks used for one-off debugging would live in `GPXEditorTests/PrivateFixtures/` (gitignored) if and when that folder becomes needed — not necessary up front. The `.gitignore` covers `*.gpx` at the repo root by default with explicit allow-listing for `GPXEditorTests/Fixtures/`. The fixture audit is itself a checklist item in `HANDOFF.md` under the pre-public-release tasks. See `Docs/06_FIXTURES.md` for the rules on what fixtures must look like and how they must be documented.
- **Bundle identifier: `com.gpxeditor.app`.** Project-scoped reverse-DNS, deliberately does not bake Scott's name in so a fork doesn't have to rename. This is the canonical value used in `Info.plist`, the entitlements file, code signing, notarization, and any references in code. The decision rationale lives in `DECISIONS.md`.
- **Public-facing `README.md` is a separate deliverable.** Audience is human GitHub visitors: what the app does, screenshots, install instructions, build-from-source instructions, license, credits to upstream projects (Leaflet, OSM, OpenTopoData, simplify.js). It is *not* the same audience as `CLAUDE.md`. Keep them separate. Do not assume one substitutes for the other.
- **Distribution is direct — not Mac App Store.** Releases are code-signed with a Developer ID Application certificate, notarized via `xcrun notarytool`, stapled, and shipped as a DMG attached to a GitHub Releases entry. Decision rationale: no App Store review queue, no rejection risk on guideline interpretation drift, immediate release cadence, and direct distribution is the natural fit for an open-source give-away utility. App Store distribution is not a future goal; do not preserve App-Store-only constraints in code or build settings. The architectural posture (App Sandbox + Hardened Runtime + notarization) is *stricter* than direct distribution requires — App Sandbox is our choice for security, not Apple's mandate.
- **Auto-update is out of scope for v1.** Users re-download from GitHub Releases when they want a new version. Sparkle (or similar) may be added later as a separate, deliberate decision; do not pre-architect for it.
- **Pre-cert development builds are not *publicly* distributed.** No GitHub Releases attachment, no general advertising, no general-public availability. Personal multi-machine use and small-circle beta-tester sharing is fine and expected — recipients accept the Gatekeeper unsigned-developer warning (right-click → Open on macOS 14, or attempt to launch then approve via System Settings → Privacy & Security on macOS 15+). The Lab-Code-Cert private key never leaves Scott's own machines; beta testers do not receive the certificate and rely on the Gatekeeper-bypass path instead. The notarized DMG is the public-release artifact and waits for M10.
- **Issue templates, `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`: deferred.** Worth writing before the repo flips public, but not before code exists. Tracked in `HANDOFF.md` as a pre-public-release checklist.
- **Credits and attribution are non-optional.** OSM tile attribution must be visible in the map view; Leaflet, simplify.js, and OpenTopoData get named in the `README.md` credits and the in-app About panel.

## Repo layout

```
GPXEditor/
├── GPXEditor.xcodeproj/
├── GPXEditor/                           // Source folder (Apple convention)
│   ├── GPXEditorApp.swift               // @main App
│   ├── Models/                          // Pure data types: GPXModel, Track, Segment,
│   │                                    //   TrackPoint, Waypoint, GPXSession
│   ├── Services/                        // Non-UI logic: GPXParser, GPXWriter,
│   │                                    //   ElevationService, MapBridge,
│   │                                    //   BrushTool protocol, concrete brushes,
│   │                                    //   editing operations, spike detector
│   ├── ViewModels/                      // SessionViewModel and supporting view models
│   ├── Views/                           // Top-level screens: ContentView, MapView,
│   │                                    //   Sidebar, Inspector, StatsPanel, Toolbar
│   ├── Components/                      // Reusable UI fragments: SegmentRow,
│   │                                    //   WaypointMarker, ColorSwatch, BrushSizeSlider
│   ├── WebResources/                    // Vendored JS/CSS/HTML — see Docs/03
│   │                                    //   index.html, leaflet.js, simplify.js,
│   │                                    //   leaflet.css, editor.js
│   └── Resources/                       // Apple bundle resources
│       ├── Assets.xcassets
│       ├── Info.plist
│       └── GPXEditor.entitlements
├── GPXEditorTests/
│   ├── Models/                          // Tests mirror the type-kind layout
│   ├── Services/
│   └── Fixtures/                        // Sample GPX files — rules in Docs/06
├── Docs/                                // Per-subsystem directive documents + glossary
│   ├── 01_DOCUMENT.md                   // GPX I/O, data model, parsing/writing
│   ├── 02_MAP_AND_BRIDGE.md             // WKWebView, JS↔Swift protocol, message types
│   ├── 03_WEB_RESOURCES.md              // Vendored asset rules, hash protocol
│   ├── 04_EDITING.md                    // Brushes, operations, tools
│   ├── 05_UI.md                         // SwiftUI views, sidebar, inspector, panels
│   ├── 06_FIXTURES.md                   // Fixture rules and audit policy
│   └── GLOSSARY.md                      // Project terminology — living reference, consult when terms are unclear
├── WEB_RESOURCES_HASHES.txt             // SHA-256 of vendored web assets
├── CLAUDE.md                            // This file
├── SECURITY.md
├── DECISIONS.md
├── CONVENTIONS.md
├── HANDOFF.md
└── .claude/
    └── settings.json                    // Permissions allow/deny for unattended runs
```

The codebase uses **type-kind grouping** (`Models/`, `Services/`, etc.) rather than domain grouping. When a logical subsystem (the GPX I/O subsystem, the editing subsystem, the bridge) spans multiple folders, that's expected — the directive docs in `Docs/` describe each subsystem as a logical whole, naming the specific files and types involved across folders.

## Workflow

Scott uses Xcode for builds, signing settings, and the entitlements UI. Code edits happen via Claude Code from the repo root. Builds run from Xcode (⌘R); tests run from Xcode (⌘U). For unattended longer runs (e.g., "implement milestone M3"), Scott uses `claude -p "..." --dangerously-skip-permissions` with the allow-list in `.claude/settings.json` constraining what tools are available.

## Status

Nothing built yet. Next milestone is **M0 — Project skeleton** (see `HANDOFF.md`). The build plan listing all milestones is in `HANDOFF.md`; the architectural reasoning behind each choice is in `DECISIONS.md`.

## Ground rules for any session working on this project

- **Read the directives before acting.** Always.
- **Code comments are part of the deliverable.** Write generous, explanatory comments inline. Comments explain *why*, not *what* — the *what* is in the code. Treat the comments as documentation for a maintainer who has none of the conversational context this project was built in: future-Scott six months from now, or any external reader who clones the repo. If a function's behavior depends on something that isn't visible in the function itself — a sandbox entitlement, a particular GPX format quirk, a Leaflet API gotcha, why we chose Swift-side computation over JS-side — comment it. Lean toward over-commenting. We are explicitly not optimizing for terseness or "self-documenting code"; we are optimizing for legibility months later and to a stranger. Apply this rule to Swift, JavaScript, plist comments, entitlements file comments, and shell scripts equally.
- **Swift Package Manager dependencies are added only by deliberate decision** (see D-007 in `DECISIONS.md`). The default posture leans toward minimalism, but it is not an absolute prohibition. When you spot a library that would meaningfully help, proactively surface it as a proposal — describe what it does, why it's preferable to an in-house implementation, the trust and maintenance calculus (project health, single-author vs organization, license, transitive dependencies), and any sandbox or notarization implications — then give the user time to research before deciding. Acceptance results in a new `D-XXX` entry in `DECISIONS.md` plus `Package.resolved` committed to lock the version.
- **Do not touch `WebResources/`** without reading `Docs/03_WEB_RESOURCES.md`. Vendored assets are hash-pinned and have a specific update protocol.
- **Do not add or change entitlements** without updating `SECURITY.md` in the same change.
- **Nothing fails silently.** Surface failures to the user via alerts or explicit logging — no `try?` swallowing errors, no empty `catch {}` blocks. If a failure is genuinely safe to ignore, comment why explicitly at the call site.
- **Personal-data policy is visibility-aware** (see the public-release posture section above). Credentials, team IDs, signing certificates, and notarization API keys are *never* committed. Real-world GPX tracks may be committed while the repo is private but must pass an audit before the public flip — no surprises at the moment of going public.
- **After completing meaningful work, update `HANDOFF.md`** so the next session has accurate state.
