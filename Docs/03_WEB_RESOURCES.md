# 03 — Web Resources (STUB)

> **Status: stub.** Section headings outline intended scope; bodies are placeholders. The substantive policy is already in SECURITY.md; this directive expands it operationally for the maintainer touching the `WebResources/` folder.

## Scope

The `WebResources/` folder contains the static JavaScript, CSS, and HTML loaded into the WKWebView. This document describes what files live there, the rules governing their modification, the hash-pinning mechanism, and the update protocol for vendored third-party files. SECURITY.md "Vendored web assets" is the source-of-truth on the security-relevant rules; this document is the operational reference.

## File inventory

To be expanded. Files in `WebResources/`:

- `index.html` — minimal host page that loads the vendored libraries and `editor.js`. Project-authored.
- `editor.js` — our editing layer on top of Leaflet. Handles bridge messages, manages rendering, implements brush previews. Project-authored. Per CONVENTIONS.md should not exceed roughly 800 lines; split into focused files when it grows beyond that.
- `editor.css` — project-specific styling for editor overlays and selection visualization. Project-authored. Optional if all styling fits inline.
- `leaflet.js` — vendored from leafletjs.com. Hash-pinned.
- `leaflet.css` — vendored from leafletjs.com. Hash-pinned.
- `simplify.js` — Vladimir Agafonkin's RDP simplification library, vendored. Hash-pinned.

Add a new vendored file: see "Update protocol" below.
Modify a project-authored file: routine code change.

## Hash-pinning mechanism

To be expanded. `WEB_RESOURCES_HASHES.txt` at the repository root records SHA-256 of each vendored file (not project-authored files, since those are authoritatively the repository content). Pre-commit hook (or CI step) recomputes hashes on staged changes and rejects divergence unless `WEB_RESOURCES_HASHES.txt` is updated in the same commit.

## Update protocol for vendored files

To be expanded; mirror of SECURITY.md "Update protocol for vendored files." Steps: (1) verify upstream release legitimacy via the project's official source, (2) download via HTTPS, (3) diff against current vendored copy and scan the diff for red flags (new outbound URLs, new `eval()` calls, etc.), (4) replace the vendored file, (5) update `WEB_RESOURCES_HASHES.txt`, (6) commit both file and hash update with a message naming the upstream version, (7) run the application and exercise WebView features, verify nothing broken.

## What's not allowed

To be expanded. No CDN loads at runtime. No `npm install`, no `package.json`, no Babel, no TypeScript transpilation. No JavaScript fetched from outside the application bundle. CSP in `index.html` declares `default-src 'self'` as additional defense. Any change to these rules requires a `D-XXX` decision in DECISIONS.md plus a SECURITY.md update.

## Coordinate with `Docs/02_MAP_AND_BRIDGE.md`

To be expanded. Bridge protocol (message envelope shape, JS-side dispatch in `editor.js`) is documented in `02_MAP_AND_BRIDGE.md`; this document covers the rules around the *files themselves* rather than their contents. When adding a new bridge message that requires JS changes, the work spans both directives — update them together if the change is large enough to warrant.

## Cross-references

- `DECISIONS.md` D-007 (app shell architecture; web assets vendored)
- `SECURITY.md` Vendored web assets section (authoritative on security policy)
- `CONVENTIONS.md` JavaScript code conventions
- `Docs/02_MAP_AND_BRIDGE.md` What the WebView does with these files
