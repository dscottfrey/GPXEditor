# GPXeditor — Security Posture

This document is the single page that says, in concrete terms, what GPXeditor is and is not allowed to do — at the macOS sandbox level, the network level, the dependency level, and the build pipeline level. Read this before changing anything that touches entitlements, `Info.plist`, network code, vendored assets, package manifests, or the signing/notarization pipeline. Any change to those areas requires a corresponding update to this document in the same commit.

The threat model is **not** "what if this app is malicious." It is "what if a dependency, a piece of vendored code, or our own implementation does something we did not intend." The posture is built around making such accidents either impossible (sandbox-enforced) or visible (auditable allow-lists, hash-pinned assets, lockfiles).

## Sandbox entitlements

GPXeditor runs with **App Sandbox enabled** and **Hardened Runtime enabled**. Both are non-negotiable. App Sandbox is configured to grant the minimum capabilities needed for the application to function and nothing else. The `GPXEditor.entitlements` file at `GPXEditor/Resources/GPXEditor.entitlements` is the source of truth for sandbox capabilities; this section explains what each entitlement is, why it is granted, and what is deliberately *not* granted.

### Granted entitlements

`com.apple.security.app-sandbox` — `true`. Enables App Sandbox. Without this, none of the rest of the entitlement story applies.

`com.apple.security.files.user-selected.read-only` — `true`. Allows the application to read files the user explicitly chooses through an `NSOpenPanel` dialog. Used at GPX import time. Without this entitlement, the user cannot open a GPX file from disk.

`com.apple.security.files.user-selected.read-write` — `true`. Allows the application to write to files the user explicitly chooses through an `NSSavePanel` dialog. Used when saving `.gpxeditor` project files and when exporting GPX or KML files. Without this entitlement, the user cannot save or export.

`com.apple.security.network.client` — `true`. Allows outbound network connections. Required because the application makes HTTP requests to tile servers (for basemap rendering inside the WKWebView) and to the elevation API (for the Pin to Ground feature). The sandbox treats this entitlement as binary — it does not allow per-domain restriction. Per-domain enforcement is implemented in application code; see "Network allow-list" below.

That is the complete list. No other entitlements are granted.

### Deliberately not granted

The following entitlements would represent meaningful capability expansion if added. None are present in the entitlements file. Future sessions should not add any of these without a `D-XXX` entry in DECISIONS.md justifying the addition.

`com.apple.security.network.server` — would allow the application to accept incoming connections. Not needed; we make outbound calls only.

`com.apple.security.device.camera`, `com.apple.security.device.microphone`, `com.apple.security.personal-information.location`, `com.apple.security.personal-information.contacts`, `com.apple.security.personal-information.calendars` — none of these capabilities are required by the application. Not granted.

`com.apple.security.files.bookmarks.app-scope` and `com.apple.security.files.bookmarks.document-scope` — security-scoped bookmark capabilities for persisting access to user-selected files across launches. Not granted in v1 because the document model (D-008) ingests source files immediately and never re-reads them; the application has no reason to retain access to a source file after import. If a future feature requires retained file access, this changes — but it requires explicit sandbox-update reasoning in DECISIONS.md.

`com.apple.security.cs.allow-jit`, `com.apple.security.cs.allow-unsigned-executable-memory`, `com.apple.security.cs.disable-library-validation`, `com.apple.security.cs.allow-dyld-environment-variables` — Hardened Runtime exception entitlements that loosen its protections. None are needed; WKWebView's JIT runs in its own service process and does not require any host-app exception. Not granted.

Anything else in `com.apple.security.*` is either irrelevant to a desktop application or represents capability expansion that requires explicit justification.

## Network allow-list

The application reaches a small, fixed set of external network endpoints and **no others**. The sandbox's network entitlement is binary, so per-domain restriction is implemented in application code rather than at the OS level — but it *is* enforced.

### Allowed endpoints

**Tile servers** (basemap rendering inside the WKWebView):

- `tile.openstreetmap.org` — OpenStreetMap Standard, the default basemap.
- `tile.opentopomap.org` — OpenTopoMap, topographic rendering for hiking.
- `basemap.nationalmap.gov` — USGS National Map (US-only topographic).
- `server.arcgisonline.com` — Esri World Imagery (satellite verification).
- One or more CyclOSM mirrors — to be selected at M2 from the published list at `cyclosm.org`.
- One or more NOAA Charts endpoints — to be confirmed at M2 against the current state of NOAA's chart tile services; if the integration is not clean enough to ship, NOAA Charts is dropped from v1 and tracked as a future addition. See HANDOFF.md.

**Elevation API:**

- `api.opentopodata.org` — used by the Pin to Ground feature to look up DEM-derived elevation values for track points.

That is the complete allow-list. No analytics, no telemetry, no crash reporting service, no version-check endpoint, no third-party CDN, no font service, no ad network, no error-tracking service. The application makes no other outbound calls under any circumstances.

### Enforcement mechanism

Two complementary mechanisms enforce the allow-list:

For network calls originating in the WKWebView (tile fetching, since Leaflet runs inside the web view and issues its own HTTP requests for tiles), a **`WKContentRuleList`** is compiled at app startup from a JSON specification listing exactly the allowed tile-server domains. Every other network request originating in the web view is blocked at the WebKit layer before any actual HTTP traffic occurs. The rule list is rebuilt at startup from the same source-of-truth list of allowed tile domains used elsewhere in the app, so adding a tile server requires updating exactly one place.

For network calls originating in Swift code (the elevation API), all `URLSession` traffic is routed through a wrapper that validates the request URL against the allowed Swift-side endpoints before allowing the request to proceed. Any request to a host not in the Swift allow-list raises an error and is logged.

Both mechanisms use the same root configuration: a `NetworkAllowList` Swift type in `Services/` that exposes the lists, with the WebView consumer building a `WKContentRuleList` from the tile domains and the URLSession consumer using the elevation domains directly.

### Why tile servers are not user-configurable in v1

D-015 (tile source picker) ships a curated build-time list with no user-added custom URLs in v1. The reason is in the security model: a custom URL the user adds at runtime would have to be added to the `WKContentRuleList`, which means recompiling the rule list dynamically and broadening the runtime network surface. Doable, but it widens the attack surface and complicates the threat model. In v1, the allow-list is fully build-time-static. Custom URL support is a future v2 decision that comes with its own SECURITY.md update.

## Vendored web assets

The `WebResources/` directory contains the static JavaScript, CSS, and HTML files loaded into the WKWebView. These are vendored — committed to the repository as files, never fetched from a CDN at runtime. The detailed update protocol lives in `Docs/03_WEB_RESOURCES.md`; this section captures the security-relevant rules.

### Hash-pinning

A file at the repository root, `WEB_RESOURCES_HASHES.txt`, records the SHA-256 hash of every file in `WebResources/` that originated from a third-party project (Leaflet, simplify.js, plus their CSS and any related resources). Files we wrote ourselves (`index.html`, `editor.js`, project-specific CSS) are not hash-pinned because their authoritative version is the repository content itself.

A pre-commit hook (or, equivalently, a CI step at PR time) recomputes the hashes of vendored files and compares them against `WEB_RESOURCES_HASHES.txt`. Any divergence requires either (a) the change is intentional and the hash file is updated in the same commit with a clear commit message naming the upstream version, or (b) the change is rejected.

### Update protocol for vendored files

Updating a vendored file (e.g., bumping Leaflet from version X to version X+1) is a deliberate, visible event. The required steps:

1. Verify the upstream release is legitimate — check the project's GitHub releases page, signature if available, official source.
2. Download the new file via HTTPS from the official source.
3. Diff the new file against the current vendored copy. Read the diff if it is small; if it is large, at minimum scan for any new outbound URLs, new `eval()` calls, or other red flags.
4. Replace the vendored file.
5. Recompute the hash and update `WEB_RESOURCES_HASHES.txt`.
6. Commit the file change and the hash file change together with a commit message that names the upstream version (e.g., `Update Leaflet 1.9.4 → 1.9.5`).
7. Run the application, exercise the WebView features that use the updated library, verify nothing has broken visibly.

This protocol is the same in spirit as `requirements.txt --require-hashes` for Python projects: a deliberate event with auditable evidence, not silent adoption.

### What is not allowed

Loading any JavaScript, CSS, or HTML at runtime from a URL not in the application bundle. The WebView's `loadFileURL` is restricted via the `allowingReadAccessTo:` parameter to the `WebResources/` folder inside the bundle; any attempt to load resources from other locations fails. The Content Security Policy in `index.html` (`WebResources/index.html`) declares `default-src 'self'` to make this an additional layer of defense — even if file-URL access were misconfigured, the CSP blocks loads from elsewhere.

The vendored web assets are also covered by Apple's app bundle code signing — the entire bundle's signature is invalidated if any file inside it (including `WebResources/`) is modified after signing. This means a deployed signed `.app` cannot have its vendored JS files swapped out without breaking the signature; the user (or Gatekeeper) sees a signature mismatch immediately.

## Swift Package Manager dependencies

D-007 is the source of truth for SPM dependency policy. This section captures the security-relevant aspects.

The initial build of GPXeditor ships with **zero third-party SPM dependencies**. The `Package.resolved` file in the repository reflects this — it should contain only Apple-shipped frameworks if any are listed at all. Any future dependency addition is gated by a `D-XXX` entry in DECISIONS.md and committed alongside an updated `Package.resolved` that locks the version.

When a dependency *is* added, the security checks at acceptance time include:

1. The library is hosted on a reputable platform (typically GitHub) under an organization or active maintainer with a track record.
2. The license is compatible with MIT — typically MIT, BSD, or Apache 2.0. Copyleft licenses (GPL family) require careful consideration since they would propagate to GPXeditor's distribution.
3. The transitive dependency footprint is reviewed; a library that pulls in twenty packages of its own is a much larger trust commitment than a leaf package with no dependencies.
4. The library has no native code or compiled binaries unless those are signed and verifiable.
5. `Package.resolved` is committed in the same change as the dependency addition.
6. The library does not require entitlements that GPXeditor does not already have. If it does, that is a separate decision.

`pip-audit` and `safety` style tools have rough Swift equivalents (e.g., `nmap` for SBOM, GitHub's Dependabot if the repository is public). Once the repository goes public (D-005), Dependabot is enabled with security-only updates so we are notified of CVEs but not surprised by aggressive version bumps.

## Code signing and notarization

GPXeditor uses two distinct signing arrangements depending on context. For **distributable builds**, the application is signed with a **Developer ID Application** certificate and notarized via `xcrun notarytool` before publication; the notarization ticket is stapled to the DMG before release. For **development builds** (milestones M0 through M9 in HANDOFF.md), the application is signed locally using Xcode's free Personal Team — a development-only signing identity provisioned automatically when the developer signs into Xcode with an Apple ID. Both arrangements use **identical entitlements, hardened runtime configuration, and sandbox capabilities**; they differ only in the signing identity and in whether notarization is performed.

The Personal Team build runs on the developer's own Mac with full sandbox, hardened runtime, and entitlement enforcement, so all security-posture testing — verifying that the sandbox restricts what it should, that the network allow-list blocks unexpected requests, that entitlements behave as documented — can be done from day one without waiting for the paid Apple Developer Program membership. The Personal Team build cannot be distributed to other Macs without Gatekeeper warnings, but distribution is an M10 concern, not a development concern. When the paid Developer ID Application certificate becomes active, the transition to distribution-ready builds is a single signing-identity change in Xcode's signing settings plus the M10 milestone work itself; no code, entitlement, or sandbox configuration changes are required to switch from local-development signing to Developer ID signing.

Signing identity management, certificate provisioning, and notarization workflow are not part of this document — they live in `HANDOFF.md` (build/sign/notarize commands and the certificate setup checklist) and reference Apple's developer documentation. What this document records is the *security posture* of the signed build:

- The entire app bundle is signed, including `WebResources/`. Any post-build modification of vendored files invalidates the signature.
- Hardened Runtime is enabled with no exception entitlements. Library validation is on; the bundle cannot load unsigned dynamic libraries at runtime.
- Notarization runs Apple's malware scan on the binary. A notarized build passes Gatekeeper without warnings on macOS 14+ for end users.
- The build produces a reproducible artifact: same source + same `Package.resolved` + same Xcode version + same signing identity should produce a byte-comparable `.app`. Reproducibility is a verification tool, not a strict requirement — small build-time variations are tolerated.

The signing certificate's private key never enters the repository. Notarization API keys never enter the repository. These live in the developer's keychain or secure environment variables on the build machine. The repository's `.gitignore` covers any file that has historically been mistakenly committed in similar projects (private keys, `.p12`, `*.cer`, `notarization-credentials.json`, etc.).

## Personal data

D-005 details the repo-visibility-aware personal-data policy. Summary for this document:

While the repository is private (the development phase), test fixtures and example tracks may include real-world recordings, including the user's own recordings of public-trail outings. Credentials, signing certificates, Apple Developer team IDs, and notarization API keys are *never* committed regardless of repo visibility — those are absolute.

Before the repository flips public (the gate condition described in D-005), `GPXEditorTests/Fixtures/` is audited: every track in the directory is verified to be either synthetic or from a clearly public location, and any track revealing home, work, or routine personal routes is removed.

After the public flip, new fixtures committed must be synthetic or from public-trail recordings.

## What this document does not cover

This document is the security-posture page for the application itself — sandbox, network, dependencies, signing. It does not cover:

- **Operational security** of the developer's machine (keychain hygiene, certificate backup, etc.) — that's for the developer to handle outside the project.
- **GitHub repository security** (branch protection, two-factor authentication, signed commits) — those live in the repo's own configuration once it exists.
- **Privacy policy** for end users — there is none to write because the application collects, stores, and transmits no user data beyond what the user explicitly types into a save dialog or supplies as input. Any future policy is a separate document keyed to a feature that introduces such collection.

## Update protocol for this document

Changes to this document follow the same append-and-deliberate pattern as DECISIONS.md, but in place rather than append-only — this is a current-state document, not a history. A change is required when:

- An entitlement is added, removed, or modified.
- A new network endpoint is added to the allow-list (or one is removed).
- The vendored-asset update protocol changes.
- A Swift Package Manager dependency is added.
- The signing or notarization pipeline changes.

Such changes are made in the same commit as the underlying code or configuration change. PRs that touch entitlements, network code, or signing without a corresponding SECURITY.md update should be flagged in review.
