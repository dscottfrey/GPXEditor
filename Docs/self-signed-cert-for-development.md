# Self-Signed Code-Signing Certificate for Local Development

A reusable procedure for replacing Xcode's automatic Personal Team signing with a long-lived self-signed certificate, so local development builds stop breaking when Apple rotates Personal Team issuing infrastructure or the certificate's one-year window elapses.

This document is both a reference and a runnable Claude prompt: hand it to a Claude Code session along with "switch this project to self-signed dev signing per the procedure" and the agent has everything it needs.

---

## What this is for

Personal Team certificates (Xcode's free auto-provisioned signing identity, used when a developer signs in with an Apple ID but has no paid Developer Program membership) have a **one-year validity** and are **subject to silent revocation** when Apple rotates issuing infrastructure. Every time this happens, local builds break with cryptic signing errors until the developer re-provisions through Xcode. The keychain accumulates `CSSMERR_TP_CERT_REVOKED` entries.

A **self-signed code-signing certificate** with a long validity (a decade is reasonable) eliminates this failure mode for local development. The cert is locally issued in Keychain Access, never touches Apple's servers, and remains valid until you delete it. Because development builds run only on the developer's own machine, the absence of Apple-trusted issuance is a non-issue.

This is **not** a substitute for a real Developer ID Application certificate. Distribution-ready builds still need Apple-issued signing for Gatekeeper / notarization. The self-signed cert is a development-time tool only.

---

## Decisions baked into this approach

For when future-you wonders why something was done this way.

### Why self-signed instead of waiting for the paid Developer Program

Two reasons. First, the Developer Program membership can take days or weeks to activate, and during that interim the developer is stuck on Personal Team's expiring/revoking churn. Second, even after the paid membership is active, conflating "the certificate that signs distribution builds" with "the certificate that signs local builds" is a category error — the distribution cert is precious (loss = re-issuance through Apple Connect) while the development cert is disposable (loss = recreate in 30 seconds). Keep them separate.

### Why a 10-year validity

By that point you'll either have a Developer ID Application cert (irrelevant) or you can regenerate the dev cert trivially. The 10-year reach is deliberate — pick a number that's longer than you expect to care about so the cert is not on your maintenance radar.

### Why the same cert for app target AND test target

Hardened Runtime enables library validation, which enforces that all loaded code must be signed by the same team identifier as the host (or by Apple). When unit tests run, the test bundle is loaded into the host app's process; if the test bundle is signed with a different cert, library validation fails the load. So both targets get the same cert. Same applies to any framework target the app loads.

### Why Manual signing style

`CODE_SIGN_STYLE = Automatic` looks at `DEVELOPMENT_TEAM` and tries to provision a matching Apple-issued cert. With a self-signed cert (no team), Automatic mode either fails or silently falls back to Personal Team. Manual signing pins the identity explicitly: `CODE_SIGN_IDENTITY = "Lab Code Cert"` (or whatever you named it), and Xcode uses exactly that.

---

## Phase 0 — Survey before editing

Don't edit anything until you know:

1. **The certificate exists and is usable.** Run `security find-identity -v -p codesigning`. The cert should appear in the output. If it doesn't, see "Creating the certificate" below before continuing.
2. **The certificate has the right attributes.** Run:

       security find-certificate -c "<CertName>" -p | openssl x509 -noout -subject -issuer -dates -ext keyUsage,extendedKeyUsage,basicConstraints

   Verify:
   - `subject` and `issuer` are identical (i.e., self-signed).
   - `notAfter` is several years out.
   - `Basic Constraints: CA:FALSE` (it's not a CA, just a leaf code-signing cert).
   - `Key Usage: Digital Signature` (required for code signing).
   - `Extended Key Usage: Code Signing` (required for code signing — without this, the cert won't be picked up by `security find-identity -p codesigning`).

3. **Current signing config in `.pbxproj`.** Search for `CODE_SIGN_STYLE`, `CODE_SIGN_IDENTITY`, `DEVELOPMENT_TEAM`, `PROVISIONING_PROFILE`. Note current values for each target × configuration so the rollback is unambiguous if needed.
4. **Targets that need switching.** Every target whose product runs in the same process as the host app (test bundles, frameworks the host loads at runtime) must use the same signing identity due to library validation.

Summarize findings, propose changes, **wait for confirmation before editing.**

---

## Phase 1 — Files Claude writes

Documentation only — the actual signing-config change is manual in Xcode (Phase 2). For a project that has decision/security docs:

1. **`SECURITY.md` (or equivalent)** — update the code-signing section to acknowledge the self-signed cert as an acceptable development identity. Note that entitlements, Hardened Runtime, sandbox capabilities, and the M10 transition path are unchanged.
2. **`DECISIONS.md` (or equivalent)** — add a decision entry capturing the choice, alternatives considered, rationale, and consequences. Use the project's existing decision-record format.
3. **`Docs/self-signed-cert-for-development.md` (this doc)** — copy this file in, customize the project-specific details if any.

---

## Phase 2 — Manual Xcode steps for the human

These steps require Xcode's UI. **Do NOT edit `.pbxproj` programmatically** — risk to project integrity isn't worth it.

For **each target that loads into the host app's process** (the app target and any test/framework target):

### Step 1 — Switch Code Signing Style to Manual

1. Project Navigator → top item → TARGETS → target name.
2. **Build Settings** tab → filter buttons set to **All** + **Combined**.
3. Search box: `code signing style`.
4. Find **Code Signing Style** under **Signing**. Click the value (`Automatic`) → set to **Manual**. Set both Debug and Release.

### Step 2 — Set Code Signing Identity

1. Same target → search box: `code signing identity`.
2. Find **Code Signing Identity**. Click the value, type the certificate's exact name (e.g., `Lab Code Cert`) — Xcode will autocomplete from your keychain. Set both Debug and Release.

### Step 3 — Clear Development Team

1. Same target → search box: `development team`.
2. Click the value, choose **None** (or delete the existing team identifier). Set both Debug and Release.

### Step 4 — Repeat for each remaining target

The test target and any framework targets the host loads need the same three changes.

---

## Phase 3 — Verification

1. **`Cmd-B` Debug build.** Should succeed with no signing errors.
2. **`codesign -dv --verbose=4`** on the built `.app` (path: `~/Library/Developer/Xcode/DerivedData/<project>-<hash>/Build/Products/Debug/<App>.app`):

       codesign -dv --verbose=4 ~/Library/Developer/Xcode/DerivedData/.../Debug/MyApp.app

   The output should show `Authority=Lab Code Cert` (or your cert's name). No `Authority=Apple Development:` line.
3. **`Cmd-R` run.** App launches, no Gatekeeper warnings (because no quarantine attribute on a locally-built app).
4. **`Cmd-U` test.** Tests pass — the test bundle loads into the host process without library-validation rejection.

---

## Creating the certificate (if you don't already have one)

Done once per machine via Keychain Access.

1. Open **Keychain Access** (in `/Applications/Utilities/`).
2. Menu: **Keychain Access → Certificate Assistant → Create a Certificate…**
3. **Name:** the cert name you'll use in Xcode (e.g., `Lab Code Cert`). Pick something distinctive so it doesn't collide with Apple-issued certs in fuzzy searches.
4. **Identity Type:** Self Signed Root.
5. **Certificate Type:** Code Signing.
6. **Check "Let me override defaults"** — required to set the validity period.
7. **Continue.** Pick a high serial number; doesn't matter much for self-signed.
8. **Validity Period:** 3650 days (10 years). The default is 365 days; that's the same one-year window we're trying to escape, so override it.
9. **Continue through the rest with defaults**: Email Address blank or your address; RSA 2048; Digital Signature (must be checked); Extended Key Usage including Code Signing.
10. **Save in the login keychain.**

Verify with `security find-identity -v -p codesigning` — the new cert should appear in the list.

---

## Known gotchas

### "Code signing identity 'Lab Code Cert' not found" at build time

The cert isn't in a keychain Xcode can see, or its key usage is wrong. Check:

- Is it in the **login** keychain (not just system or some other keychain)?
- Does it have `Code Signing` in the Extended Key Usage field? Without that, `security find-identity -p codesigning` won't see it.
- Is the keychain unlocked? Build phases sometimes fail when the login keychain is locked; use `security unlock-keychain` if needed.

### "errSecInternalComponent" or other code-signing errors

Almost always one of:

- Wrong cert chosen for one target but not another (check every Build Settings entry, all configurations).
- Test bundle still signed with the old Personal Team cert while host is signed with the new self-signed cert → library validation fails the test bundle load. Make sure ALL targets that load into the same process use the same cert.
- Keychain access permission prompts being denied by the user. Allow `codesign` to access the cert's private key, ideally with "Always Allow" so future builds don't re-prompt.

### Signed app shows "from an unidentified developer" if downloaded from the internet

Expected — Gatekeeper checks against Apple-trusted issuers, and a self-signed cert isn't one. Locally-built apps don't have the quarantine attribute, so no warning appears. If you copy the .app to another Mac via AirDrop / a download / etc., quarantine kicks in and Gatekeeper warns. This is the price of self-signed; it's why you switch to Developer ID for distribution.

### M-series Mac requires every binary to be signed (even ad-hoc)

True, but the self-signed cert satisfies this requirement just fine. No special handling needed.

### Library validation blocks loading frameworks signed by other teams

If your app uses third-party SPM packages or frameworks, they're typically not signed (SPM dependencies build from source) so library validation is fine. But if you embed a pre-built framework signed by someone else's team, library validation rejects it. Solutions: build the framework from source, or disable library validation via the `com.apple.security.cs.disable-library-validation` Hardened Runtime exception entitlement (which weakens security and should be a separate, deliberate decision).

### Don't forget to switch back before shipping

This is a development-time identity. Before archiving for distribution:
1. Restore Automatic signing (or set Manual + Developer ID Application).
2. Set DEVELOPMENT_TEAM back to the paid team identifier.
3. Verify with `codesign -dv --verbose=4` that `Authority=Developer ID Application: <name> (<TEAMID>)` appears.

In a project with milestone-based release tracking (like this one's M10), make this an explicit step in the release milestone description so it doesn't get forgotten.

---

## What this procedure does NOT do

- **Does not change entitlements, Hardened Runtime configuration, or sandbox capabilities.** Those stay enabled and unchanged across signing-identity switches.
- **Does not enable distribution.** Self-signed builds work only on the developer's own machine; distribution requires a Developer ID Application certificate and notarization.
- **Does not address provisioning profiles.** Mac apps that don't use entitlements-requiring-provisioning (push notifications, App Groups across multiple apps, iCloud) don't need profiles. iOS apps generally do, and the procedure is more involved there.
- **Does not edit `.pbxproj` programmatically.** Build Settings changes are deliberately left for the human in Xcode UI to avoid risk to project integrity.
- **Does not commit the certificate.** The private key never leaves the developer's keychain; nothing about the cert lives in the repo.
