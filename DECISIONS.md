# GPXeditor — Architectural Decisions

This document records the architectural and product decisions made for GPXeditor. Each entry captures what was decided, what alternatives were considered, why this decision was chosen over the alternatives, and what consequences the decision has for code, UX, and future work.

## How to read this document

Decisions are **append-only**. When a decision is overturned, a new entry is added that supersedes the old one — the original is not deleted, edited in place, or rewritten. This preserves the reasoning history so future sessions can see why a path was once taken (and abandoned), avoiding the trap of re-litigating settled questions or accidentally re-introducing previously-rejected approaches.

The Status field on each entry is one of:
- **Accepted (date)** — currently in force.
- **Superseded by D-XXX (date)** — replaced by a newer decision; reasoning preserved here for context.
- **Deprecated (date)** — no longer relevant due to scope change; included for historical visibility.

When implementing code that touches a decision area, read the relevant entry in full before making changes. When proposing to overturn a decision, write the new entry first, get it accepted, then refactor — do not edit the old entry's body.

## How to add a new decision

When a new architectural choice arises during development:

1. Pick the next available decision number (e.g., D-019 if the latest accepted is D-018).
2. Draft the entry following the format used below.
3. Discuss with the user; iterate until accepted.
4. Append the accepted entry to the bottom of this document, preserving numerical order.
5. If the decision affects in-flight work, also update HANDOFF.md.

The entry format is: a section heading with the decision number and a short noun-phrase title, followed by Status, Decision (one paragraph), Alternatives considered (brief), Rationale (why this over alternatives), and Consequences (implications for code, UX, future decisions).

---

## D-001: Display name

**Status:** Accepted (2026-04-30)

**Decision:** The application's user-visible display name is **GPXeditor** (one word, lowercase 'e'). This name appears in the app bundle's `CFBundleName` and `CFBundleDisplayName`, the menu bar, the About panel, the title of GitHub Releases, and the public README. The Xcode project name and Swift module name follow the conventional acronym-PascalCase style (`GPXEditor`) for code-side consistency with Apple naming guidelines; the file paths in the repository (`GPXEditor.xcodeproj/`, `GPXEditor/`, `GPXEditorTests/`) use the PascalCase form. The display string and the project string can differ.

**Alternatives considered:** "GPX Editor" (two words with a space — readable but slightly more bureaucratic-looking); a more whimsical name like "Adze Reborn" or "Trailmaker" (rejected as either too tied to the predecessor or too generic).

**Rationale:** Short, descriptive, immediately recognizable to anyone who knows what GPX is. Works as a search term on GitHub. Doesn't bake the author's name into the user-facing identity, supporting the public-release goal where the project should read as a project, not as someone's personal tool.

**Consequences:** All UI strings, documentation, README, in-app About panel, GitHub repo name, and DMG filenames use "GPXeditor". Code-side identifiers (Xcode project, Swift module, type names containing the project name) use `GPXEditor`. Future contributors must respect this distinction.

---

## D-002: License

**Status:** Accepted (2026-04-30)

**Decision:** The project is licensed under the **MIT License**. The repository contains a `LICENSE` file at the root with the standard MIT text and Scott Frey's copyright notice.

**Alternatives considered:** Apache 2.0 (adds an explicit patent grant, slightly safer for contributors but unnecessary friction for a small give-away utility); GPL-3.0 (forces derivative works to also be open — a stronger philosophical statement but discourages forks for closed projects); BSD-3-Clause (essentially equivalent to MIT in practice with marginally different language).

**Rationale:** Maximally permissive for a give-away utility. Anyone can use, modify, redistribute, or fork the source freely, including for commercial purposes, provided the copyright notice and the MIT license text are preserved. The simplest license that achieves the give-away intent without imposing additional obligations.

**Consequences:** No restriction on derivative works. Forks may re-license their additions however they wish, as MIT permits. Per-file copyright headers are not required; the root `LICENSE` file suffices. Third-party vendored web assets (Leaflet, simplify.js) carry their own licenses (BSD-2-Clause, MIT) that are compatible with MIT and are credited in the README and in-app About panel.

---

## D-003: Bundle identifier

**Status:** Accepted (2026-04-30)

**Decision:** The application's bundle identifier is **`com.gpxeditor.app`**. This value is used in `Info.plist`, in the entitlements file, in code signing configuration, in notarization submissions, and anywhere else in the project that requires a stable application identity.

**Alternatives considered:** `com.scottfrey.gpxeditor` (author-scoped; works but slightly awkward for forks who would need to rename); `org.openadze.app` (lean into "spiritual successor to Adze" branding but dilutes the project's own identity).

**Rationale:** Project-scoped, deliberately does not bake the author's name in. A fork doesn't need to rename. Reads as the project's bundle, not anyone's personal bundle. With direct distribution (D-004), there is no App Store namespace to collide with, so the bundle ID's only requirement is being a valid reverse-DNS string.

**Consequences:** Anyone forking the project to ship their own build must change the bundle identifier to their own reverse-DNS string before signing and notarizing — they cannot ship a build under `com.gpxeditor.app` because that signing identity is bound to the original project's developer credentials. The bundle ID is referenced consistently across `Info.plist`, the entitlements file, and any code that needs application-identity awareness.

---

## D-004: Direct distribution, not Mac App Store

**Status:** Accepted (2026-04-30)

**Decision:** GPXeditor is distributed as a **signed and notarized DMG attached to a GitHub Releases entry**, not through the Mac App Store. Code signing uses a Developer ID Application certificate. Notarization is performed via `xcrun notarytool`. The notarization ticket is stapled to the DMG before publication.

**Alternatives considered:** Mac App Store distribution (would require an App Store signing certificate provisioned separately, App Store Review compliance, and submission lifecycle management); a simple unsigned ZIP download (would force Gatekeeper warnings on first launch, unprofessional for a public release).

**Rationale:** Direct distribution removes the App Store review queue, the rejection risk for guideline interpretations Apple changes year over year, and the in-band submission lifecycle. For an open-source give-away utility published via GitHub, App Store distribution adds friction without meaningful benefit — discoverability via App Store search and the "Install" button UX are irrelevant for a tool publicized via GitHub. The architectural posture (App Sandbox + Hardened Runtime + notarization) is *stricter* than direct distribution requires; App Sandbox is our security choice, not Apple's mandate. The user has confirmed they are obtaining the Developer ID Application certificate.

**Consequences:** The build pipeline includes notarization steps but does not include App Store Connect submission. The signing identity is Developer ID Application; the App Store signing identity is not provisioned. Auto-update is not provided in v1; users re-download from GitHub Releases when they want a new version. Sparkle (or a similar auto-update framework) may be considered in a future version as a separate decision; this is captured as a future-improvement item in HANDOFF.md.

---

## D-005: Repository visibility timeline

**Status:** Accepted (2026-04-30)

**Decision:** The GitHub repository is **private during development** and **flipped to public at the time of first release**. The flip is gated on a checklist of preparation tasks: a signed and notarized DMG must be buildable from a clean checkout, the test fixture audit must be complete, the README and LICENSE must be in place, CONTRIBUTING.md and CODE_OF_CONDUCT.md must be written, and issue templates must be created. The checklist is maintained in HANDOFF.md as the "Pre-public-release tasks" section.

**Alternatives considered:** Public from day one (would require fixture-audit hygiene from the first commit and prevent the "let me commit my real GPX file to debug this parser issue" workflow during development); private permanently (would defeat the give-away goal).

**Rationale:** A private development phase removes the policing burden on what can be committed to test fixtures, allows real-world tracks (especially public-trail recordings) to be used as fixtures freely during debugging and development, and lets the project develop without simultaneously maintaining public-release hygiene. The flip to public is a deliberate gate — everything that needs to be in place for public consumption is verified before the visibility change, so there are no last-minute surprises.

**Consequences:** The pre-public-release checklist in HANDOFF.md is a hard gate; no public-flip happens until every item is checked off. After the flip, normal public-repo hygiene applies: no personal data in commits, no credentials, additions to the fixture set are audited for personal data exposure. Discussions and decisions made during the private phase may freely reference private context; once public, anything sensitive that ended up in commit history must be carefully scrubbed before the flip.

---

## D-006: macOS deployment floor

**Status:** Accepted (2026-04-30)

**Decision:** The minimum supported macOS version is **macOS 14 Sonoma**. Earlier versions are not supported.

**Alternatives considered:** macOS 13 Ventura (slightly broader compatibility, but loses some SwiftUI document API conveniences and would require version-conditional code paths); macOS 12 or earlier (significant SwiftUI feature loss, more workarounds, not worth supporting for a v1 personal tool); macOS 15 Sequoia (would tighten the floor further but excludes a meaningful slice of users still on Sonoma).

**Rationale:** macOS 14 includes the modern SwiftUI document APIs and WKWebView features GPXeditor depends on, without requiring `if #available` checks for the features actually used. Anyone on a Mac that cannot run macOS 14 is on hardware older than approximately 2018 and unlikely to be in the target audience for a give-away GPX editor in 2026. Supporting older versions would mean working around feature gaps for marginal user benefit.

**Consequences:** `Info.plist` declares `LSMinimumSystemVersion` as `14.0`. Build settings target the macOS 14 SDK or later. No `if #available(macOS 14, *)` guards are needed for the APIs we use. As macOS evolves, future features from macOS 15+ may require `if #available` guards if we want to use them while still supporting macOS 14.

---

## D-007: App shell architecture — SwiftUI + WKWebView + Leaflet

**Status:** Accepted (2026-04-30)

**Decision:** GPXeditor is a native macOS **SwiftUI** application whose primary editing surface is a **WKWebView** hosting **Leaflet.js** with vendored static web assets. Swift owns the data model, edit operations, and document state. JavaScript is the presentation layer — it handles map rendering and live-preview overlays. The two communicate via a defined message protocol (specified in CONVENTIONS.md and detailed in `Docs/02_MAP_AND_BRIDGE.md`). Native shell concerns (file dialogs, NSDocument-equivalent integration via `FileDocument`, dock icon, file association, menu bar, keyboard shortcuts) are handled by SwiftUI; map editing UI complexity (vertex dragging, polyline manipulation, marquee selection, brush previews) is handled by Leaflet.

**Alternatives considered:** PyQt6 + WebView + Leaflet (similar hybrid pattern but Python-shelled; rejected because the user's actual current workflow is Xcode + Claude Code on Swift projects, not Python; PyQt6 would also add a substantially larger trust-surface dependency than the Apple-shipped frameworks); SwiftUI + MapKit (rejected because MapKit lacks the mature interactive editing primitives that Leaflet has; reimplementing those in MapKit would take months and produce inferior UX); Tauri or Electron (rejected because they don't match the existing native macOS development workflow); pure web app served from a Docker container (rejected because it loses the native macOS file integration features that are core to the UX — drag-onto-dock, Finder file association, native save dialogs).

**Rationale:** The hybrid pattern gives a native macOS shell where it matters (file handling, dock integration, signing, sandboxing, notarization, menu bar) and a battle-tested map editing UI where that matters (Leaflet has fifteen-plus years of accumulated interactive map manipulation primitives). Swift's verbosity is offset by zero external native-shell dependencies — Foundation, AppKit, SwiftUI, and WebKit are all Apple-shipped and updated by macOS Software Update. Trust surface is "Apple plus a small set of vendored JS files" rather than "Apple plus Qt plus JS files." App Sandbox, Hardened Runtime, code signing, and notarization are all first-class Xcode concerns with mature tooling. The architecture also matches the user's existing Xcode + Claude Code workflow exactly.

**Consequences:** **Swift Package Manager dependencies are added only by deliberate decision.** The initial build ships with zero third-party SPM dependencies, and any addition during the project's life requires an explicit `D-XXX` entry in this file recording the rationale. The default posture leans toward minimalism — each new dependency is a trust commitment and a maintenance burden — but it is **not** an absolute prohibition. When a candidate library would meaningfully help, the working pattern is: Claude proactively surfaces the proposal in conversation with the relevant context (what the library does, why it's preferable to an in-house implementation, project health and license, transitive dependency footprint, any sandbox or notarization implications); the user takes time to research before deciding; acceptance results in a new `D-XXX` entry plus `Package.resolved` committed to lock the version. Web assets (Leaflet, simplify.js, custom editor JavaScript, CSS, HTML) are vendored as static files inside the app bundle, hash-pinned against tampering, and never fetched from a CDN at runtime — they follow a separate update protocol documented in `Docs/03_WEB_RESOURCES.md`. JavaScript-to-Swift communication uses `WKScriptMessageHandler`; Swift-to-JavaScript uses `evaluateJavaScript`. The Swift-as-source-of-truth, JS-as-presentation-layer split is a project-wide invariant — JavaScript never holds authoritative state. The data and editing layers (code in `Models/` and the GPX-handling and editing parts of `Services/`) are written portably with no AppKit, SwiftUI, or WebKit imports, so a hypothetical future iOS port would not require rewriting the editing logic. See CONVENTIONS.md for the precise scope of the platform-agnostic layer.

---

## D-008: Document model — non-destructive session

**Status:** Accepted (2026-04-30)

**Decision:** GPXeditor is a **non-destructive session-based editor**, not a traditional file editor. Source GPX files are *ingested* (read once at import time), their original bytes are preserved as immutable per-track copies inside the project file, and they are never re-read from disk thereafter. The working state is a parsed, mutable copy that all edits operate on. The original immutable copy supports a per-track "Reset to Original" action that discards the current working edits and starts fresh from the ingested bytes. Import is available as an action at any time during a session — not only at project creation — which also handles the "I want a fresh copy of this track" use case without needing a separate re-ingest operation.

**Alternatives considered:** Traditional file-editor model where opening a `.gpx` file allows direct editing and saving (rejected because the user's workflow involves combining multiple input tracks into one refined output, which doesn't fit the one-file-in-one-file-out model); session with external file references and hash-based change detection (rejected because it adds complexity, introduces "source has changed" warnings, and requires re-reading source files); Lightroom-style centralized catalog (rejected as overkill for a single-user tool focused on per-trail-map sessions).

**Rationale:** The user's typical workflow is loading multiple GPX recordings of the same trail and combining them into a refined output, where the source files function as inputs rather than as documents. Treating sources as immutable preserves the explicit "never overwrite the original" requirement. Embedding original bytes inside the project (instead of holding external references) makes projects self-contained and portable, eliminates "source file changed since save" surprises, and removes any need for path tracking or hash checking. The user could delete a source file from disk after import and the project would still work perfectly.

**Consequences:** The project file is the single source of truth for project state. Project files are larger than they would be with external references — each track carries its original ten-to-five-hundred kilobytes of XML — but practically negligible at the realistic scale of a few tracks per project. The sandbox needs filesystem access only at import time (read) and at save or export time (write); no background filesystem access is required. The data model (in `Models/`) represents each track as `(immutableOriginalBytes, currentWorkingState, displayMetadata)`. Session-load logic and crash-recovery logic share the same code path: load the project file, populate the in-memory model, ready to edit.

---

## D-009: Edit history — bounded in-memory undo

**Status:** Accepted (2026-04-30)

**Decision:** Edit history uses **`NSUndoManager` with bounded depth** — ten levels by default, with the depth made configurable in Settings in a future version. Operations coalesce per gesture: one drag, one brush stroke, one marquee delete is one undo unit regardless of how many internal points are modified. Undo history is **purely in-memory** and **not persisted**: opening a saved project starts the undo stack fresh and empty. Every editing primitive is defined as a discrete, named operation so the undo menu shows meaningful descriptions ("Undo Smooth Brush", "Undo Delete Points") rather than generic "Undo".

**Alternatives considered:** Unbounded undo history (would consume memory and complicate the file format if persisted); a fully event-sourced model with a persistent operation log (was the initial proposal during this design conversation; rejected as over-engineered once the user clarified that time-travel, infinite undo, branchable sessions, and shareable session logs are explicitly not wanted); per-point undo granularity (would clutter the undo history and make multi-point gestures painful to undo).

**Rationale:** The bounded, gesture-coalesced, non-persistent model exactly matches the user's stated undo needs — "rare to walk back through history; never want huge cross-session history." Apple's `NSUndoManager` handles all of this with built-in primitives: `levelsOfUndo`, `beginUndoGrouping`/`endUndoGrouping`, action names. The implementation is therefore standard Cocoa rather than custom code. The simpler state-based architecture replaced the more elaborate event-sourced model once persistence and time-travel were ruled out as unwanted features.

**Consequences:** Editing primitives (in `Services/`, alongside the brushes and other operation types) are still defined as named operations — good design discipline that supports clear undo menu strings — even though they are not persisted to disk. The session file format (D-010) is state-based, not log-based; there is no operation log to write. Crash autosave snapshots the current working state, not a sequence of operations. The undo stack lives entirely inside `NSUndoManager`, configured with `levelsOfUndo = 10` at app startup. If the user makes more than ten edits and an older operation falls off the bottom of the stack, that operation's effects become baseline state and are no longer reversible — this is acknowledged and accepted as the trade-off for a bounded, simple model.

---

## D-010: Project file format — self-contained `.gpxeditor` JSON

**Status:** Accepted (2026-04-30)

**Decision:** Projects are saved as `.gpxeditor` files containing a **single self-contained JSON document**. The JSON includes: a format version field, project metadata (name, creation date, last-saved date), per-track records (each containing the immutable original GPX bytes as a string, the parsed-and-edited current working state, master/subsidiary role, segment list with per-segment color and waypoints, display metadata), the active basemap selection, and view-port state. There are no external file references, no source-file hashes, no operation log, and no separate snapshot file.

**Alternatives considered:** Apple-style document package (a folder that looks like a single file in Finder, containing separate files for project metadata and source GPX bytes; cleaner for very large projects but premature complexity for v1); SQLite-backed project format (more efficient for incremental saves and large projects but premature complexity); operation log file format (rejected in D-009).

**Rationale:** Single-file JSON is the simplest format that achieves all the requirements: human-readable for debugging, line-diffable for git review, easily versionable, and requires no special tooling. File sizes are small enough at the scale we expect (under a few megabytes even for projects with multiple tracks) that compression is unnecessary. If file sizes become unwieldy in real use, migrating to a package format is straightforward and reversible.

**Consequences:** The project file format is a versioned format we maintain compatibility for. Forward compatibility is achieved by never removing fields (deprecating instead) and by always adding new fields with sensible defaults so older app versions can ignore them gracefully. Backward compatibility (loading newer-format files in older app versions) is best-effort; the version field allows clean rejection with a clear error message when a newer format is encountered. Crash autosave writes the same JSON format to a scratch location periodically; on app relaunch, if a newer scratch file exists than the user's last-saved project, the user is prompted to recover. Migration to a package format if file sizes ever grow unwieldy is captured as a future-improvement item in HANDOFF.md.

---

## D-011: Master/subsidiary track semantics

**Status:** Accepted (2026-04-30)

**Decision:** A project has **exactly one master track** and an arbitrary number of subsidiary tracks linked to that master. Tracks may also exist as **unaffiliated tracks** — present in the project but not part of the master/subsidiary group. The master serves as the canonical reference frame for the project: its recorded date and time become the file-level metadata in the exported GPX file (D-012), and the Average brush operates by writing into the master's working state using subsidiary tracks as inputs (D-016). Subsidiaries are **not consumed** by the average operation — they persist in the project after averaging, available as inputs for further strokes. The master is identified by a tag in the sidebar; it gets no special visual treatment in the map view.

**Alternatives considered:** Multiple masters per project (would support multi-trail projects in one file but adds complexity; users needing this can use multiple project files instead); no master/subsidiary distinction (rejected because the user's workflow explicitly treats one track as the canonical reference and others as inputs to refine it); master gets distinct visual treatment in the map view such as different stroke weight or a dedicated color tier (rejected as unnecessary; the sidebar tag is sufficient).

**Rationale:** The walkthrough described a clear workflow where multiple GPX recordings of the same trail are combined into one refined output. Designating one as master makes that intent visible in the data model and gives the Average brush a clear destination for its results. One-master-per-project keeps the data structure simple; multi-trail use cases (rare) are handled by using multiple project files.

**Consequences:** Promotion or demotion (changing which track is the master mid-session) is **deferred** — no clear use case has emerged for it during design; revisit if real use surfaces a need. The Average brush operates on the master only (D-016). Export emits only the master (D-012); subsidiaries are not included in exported GPX. The data model's track type carries an optional master/subsidiary role enum.

---

## D-012: Export model

**Status:** Accepted (2026-04-30)

**Decision:** Export emits **only the master track's working state** as a new GPX 1.1 file. Subsidiaries are not emitted. **Per-point timestamps are dropped entirely** in exports — GPX 1.1 makes the `<time>` element on `<trkpt>` optional, and the file remains spec-valid without them. The file-level `<metadata><time>` is set to the master's recorded date and time. **Segments are preserved**: the exported `<trk>` contains multiple `<trkseg>` elements, one per visual segment in the master's working state, retaining the user's editing structure. A subset-export option allows exporting only a selected subset of segments.

**Alternatives considered:** Exporting all tracks including subsidiaries (rejected because the user's deliverable is "a track on a map" — one canonical output, not a multi-track GPX of the editing session); preserving per-point timestamps from the master with synthetic timestamps for averaged points (rejected as introducing fictional data that other apps might misinterpret as a real workout, polluting trustworthy timestamps elsewhere); collapsing all segments into a single `<trkseg>` (rejected because it loses the user's editing structure and breaks the self-overlap case where two passes converge geometrically while remaining distinct as recording history).

**Rationale:** The use case is map-making, not workout recording. Per-point timestamps are noise that no map viewer cares about; dropping them produces unambiguous output and sidesteps every "what timestamp does an averaged point have" question. Segment preservation costs nothing in compatibility — every major GPX viewer handles multi-segment tracks correctly — and preserves user intent through any export-then-reimport round trip. The self-overlap insight (two passes of the same trail can be averaged together to share geometry while remaining distinct as `<trkseg>` elements) is a free benefit of preserving segments.

**Consequences:** The GPX writer (in `Services/`, with the GPX type definitions in `Models/`) produces files with `<metadata><time>` at the file level, a single `<trk>` containing the master's name in `<name>`, and one or more `<trkseg>` elements containing `<trkpt>` elements with only `<lat>`, `<lon>`, and (optionally) `<ele>` attributes — no `<time>` per point. Optional Garmin-style color extensions are not written (D-013); the file is maximally portable. KML export (planned for v1.0 polish) follows the same model.

---

## D-013: Per-segment color and accessibility

**Status:** Accepted (2026-04-30)

**Decision:** Color is a **per-segment property**, stored as a hex string in the project file. Each segment has its own color. New segments get their color auto-assigned from a curated palette; the user can change any segment's color via an inspector or context menu. The default palette is **colorblind-safe** (Okabe-Ito or a similar widely-published colorblind-safe palette) and is **fully editable in the app's Settings** — every slot is user-replaceable via the standard macOS color picker, with a "Restore Defaults" affordance. Color is **not exported** in GPX files. To address potential color-vision conflicts beyond palette tuning, segments use **redundant visual signals**: line style cycles through solid, dashed, and dotted variants when the palette wraps, and segments are rendered with a **contrasting halo or outline** so they remain visible against any basemap.

**Alternatives considered:** Storing color by palette slot index instead of hex (would make palette changes retroactively recolor old segments — rejected because it makes projects depend on user state and breaks predictability when sharing project files across machines or with collaborators); storing color per-track instead of per-segment (rejected because segments need to be visually distinguishable when displayed together, especially after a track has been split); not exporting color at all (chosen — see consequences); exporting Garmin-style `<gpxx:DisplayColor>` extensions (rejected as adding non-standard XML to a portable file for marginal benefit, since most GPX viewers ignore vendor color extensions anyway).

**Rationale:** Hex storage makes projects self-contained and stable across palette changes and across machines. The user-editable palette is required because the user has color-vision constraints that vary individual to individual; a fixed default palette cannot satisfy everyone, and a user-editable one with sensible colorblind-safe defaults handles the common case while supporting personal tuning. Redundant visual signals (line-style cycling, halos) ensure color is never the only signal — a project-wide accessibility principle that benefits everyone, not just the colorblind case.

**Consequences:** The "color is never the only signal" principle is captured in CONVENTIONS.md as a project-wide accessibility rule. Line-style cycling is a small CSS-and-Leaflet rule. Halos are rendered as a thin contrasting outline behind each polyline. Settings includes a palette editor with the standard macOS color picker per slot. Garmin's color extensions are not written into exported GPX. KML export, when added, follows the same "no color exported" policy.

---

## D-014: Editing tools roster

**Status:** Accepted (2026-04-30)

**Decision:** The editing surface comprises a small set of tools, each accessible by a single-key keyboard shortcut, with Escape always returning to the default Point Tool:

- **Point Tool** (default; shortcut V) — single-point operations including click-to-select, drag-to-move, click-on-line-to-add, right-click for a context menu (Delete, Edit Attributes, Snap to Ground, Promote to Waypoint, Set as Segment Boundary, Select Entire Segment), and drag-in-empty-space for rectangular marquee selection. All single-point operations are available without leaving the tool, directly addressing the Adze frustration where each operation required a tool switch.
- **Hand Tool** (shortcut H, plus spacebar-held for temporary mode in any other tool) — click-and-drag pans the map; no editing interactions while active.
- **Lasso Tool** (shortcut L) — free-form polygon selection for irregularly-shaped clusters.
- **Brush family** (shortcuts 1 through 4) — Simplify, Smooth, Average, Add Detail. Implementation architecture documented separately in D-015.
- **Waypoint Place Tool** (shortcut W) — drops a waypoint at the click location with a chosen icon from the curated waypoint icon set.

**Zoom** is keyboard- and gesture-driven with no explicit Zoom tool: ⌘+ and ⌘- step in and out, ⌘0 fits the view to all visible content, ⌘2 fits the view to the current selection, plus standard trackpad pinch and two-finger gestures. Operations follow the **selection-aware-operations** principle: an operation triggered while a selection exists applies only to that selection; with no selection, it applies project-wide or to the master, depending on the operation. Selection-aware-operations is documented as a project-wide UX rule in CONVENTIONS.md.

**Alternatives considered:** Per-action separate tools — one tool to add a point, another to move it, another to delete it (the Adze pattern, rejected as the very tedium the user explicitly wanted to fix); a single "edit tool" that subsumes all behaviors including brushes (would conflate brush strokes with point operations confusingly); an explicit Zoom tool with click-to-zoom-in / option-click-to-zoom-out semantics (rejected as superfluous given keyboard and trackpad gestures handle zoom directly).

**Rationale:** Standard vector-editor convention in Illustrator, Sketch, Figma, and Affinity Designer groups operations by intent: a "selection and direct manipulation" tool for single-element work, navigation tools, and structured modes for specialized tasks. Keyboard-cheap tool switching plus the spacebar-pan shortcut means tool roundtrips cost almost nothing in flow. The Point Tool's design directly fixes the Adze tedium the user named — single-point operations should never require a tool switch.

**Consequences:** The editing subsystem (concrete tools and their supporting types live in `Services/`) organizes around the tool roster. Each tool has its own implementation file conforming to a `Tool` protocol that defines the basic infrastructure (cursor changes, gesture forwarding, key handling). The Point Tool's behaviors (drag-to-move, click-on-line-to-add, right-click context menu, marquee selection) are implemented as separate gesture handlers within one tool. Cursor changes per active tool follow standard macOS conventions: open hand and closed hand for Hand, crosshair for placement modes, arrow for Point Tool. **Mid-drag spacebar pan** (the Photoshop-style continuation of an in-progress drag at a new viewport position) is **deferred** to a future polish item; v1's spacebar pan only works when no drag is in progress.

---

## D-015: Brush family architecture

**Status:** Accepted (2026-04-30)

**Decision:** The four brush tools (Simplify, Smooth, Average, Add Detail) share a unified abstraction. A top-level `BrushTool` protocol handles the shared infrastructure: gesture tracking, live preview during drag, undo grouping, commit-on-release. Two specializations exist below it: `RegionBrushTool` for brushes that operate on existing points within a circular region around the cursor (Simplify, Smooth, Average), and `PathBrushTool` for brushes that generate new points along the cursor path (Add Detail). Each individual brush conforms to one of the two specializations and provides only its specific point-operation logic.

**Alternatives considered:** Four parallel brush implementations with no shared code (would duplicate gesture tracking, preview logic, undo wiring, and brush-radius UI four times; would create drift between brushes over time as one is updated and another is not); a single flat `BrushTool` protocol without the region/path split (would conflate "modify existing points" with "generate new points" — structurally different operations that share little beyond the gesture frame).

**Rationale:** The four brushes share substantial machinery — drag handling, live preview, commit-on-release behavior, brush-radius UI. Duplicating that machinery four times is tedious and creates drift. Add Detail is structurally different from the other three (generative versus modificational), so a single flat protocol would either pollute the protocol with both kinds of behavior or force awkward type casts at call sites; two specializations cleanly separate the concerns while still sharing the infrastructure.

**Consequences:** Adding a fifth brush in the future is small: implement the operation, conform to one of the two specializations, register the keyboard shortcut. Brush-specific parameters (RDP tolerance for Simplify, smoothing kernel for Smooth, search radius for Average, point density for Add Detail) live with each individual brush; shared parameters (brush radius, hardness if introduced later) live at the protocol level. Implementation details for each individual brush are documented in `Docs/04_EDITING.md`.

---

## D-016: Average brush algorithm — v1

**Status:** Accepted (2026-04-30)

**Decision:** The Average brush v1 uses **uniform spatial averaging with full-strength application**. For each master track point inside the cursor's circular brush region during a stroke, the algorithm finds all subsidiary track points within the same radius around that master point's location, takes the uniform (unweighted) average of their lat/lon coordinates, and moves the master point fully to that averaged position. Subsidiaries with no nearby points contribute nothing for that master point; if no subsidiaries have nearby points anywhere in the brush region, the master point doesn't move on this stroke. Live-preview overlay during the drag, commits as one undo unit on release. **No keyboard radius adjustment** in v1 — fixed default radius. **No hardness slider** in v1 — always full-strength.

**Alternatives considered:** Inverse-distance weighted averaging where closer subsidiary points contribute more (produces smoother results in regions where subsidiaries diverge but rejected as v1 over-engineering); nearest-neighbor only where the master pulls toward only the single closest subsidiary point (rejected as worse for the multi-pass-converging use case); brush hardness with falloff where the center of the brush fully affects and the edges partially affect (rejected as v1 over-engineering); time-aligned averaging where corresponding points across tracks are matched by timestamp (rejected because timestamps in source data are unreliable for this use case).

**Rationale:** Following the project-wide Occam's Razor principle (CONVENTIONS.md), ship the simplest version that achieves the goal and refine based on actual use rather than anticipated need. Uniform averaging is intuitive, predictable, and addresses the primary use case: overlapping passes of the same trail converging to a representative path.

**Consequences:** Default brush radius is approximately 30 meters real-world; the exact value is tunable based on the first real track the user applies it to. Iteration paths if v1 doesn't feel right, in increasing complexity: add inverse-distance weighting (handles divergent subsidiaries more smoothly); add a hardness slider (controls how aggressively each stroke moves toward the averaged target); add a brush-radius slider with `[` and `]` keyboard adjustment (handles tracks at varying scales); add gradient hardness (smoother per-stroke effect). All of these are additive refinements that do not restructure the underlying architecture; each can be added in a future decision when a real need is demonstrated.

---

## D-017: GPS spike detection

**Status:** Accepted (2026-04-30)

**Decision:** Automatic GPS spike removal in v1 is **one-shot with undo**. A menu item or toolbar button "Remove GPS Spikes" runs a detection pass over the current selection (or the whole track if no selection), identifies spike points using cheap heuristics, and deletes them all in one operation. The user reviews the result by examining the map, and if it removed too much (or too little), one ⌘Z reverts the entire pass and the user can re-run with adjusted thresholds. Detection in v1 uses two heuristics run together: implausible instantaneous speed (default threshold approximately 50 m/s, well above any human-powered speed) and sudden lat/lon deviation from the moving average of neighboring points. **Manual** spike removal uses the existing marquee or lasso selection plus the Delete key, requiring no separate mechanism.

**Alternatives considered:** Flag-for-review with per-point confirmation where the user clicks through each suspect point individually (rejected as v1 over-engineering — one ⌘Z covers the same intent with less ceremony for the typical case); always-on automatic detection running in the background and flagging suspect points continuously (rejected as too intrusive); sophisticated detection algorithms such as Kalman filtering or Hampel filter (rejected as v1 over-engineering — the simple two-heuristic approach handles common cases).

**Rationale:** Following Occam's Razor. The one-shot-with-undo pattern matches how every other operation in the app works and produces the same end-user benefit as a flag-for-review pattern with significantly less implementation weight. The simple two-heuristic detection handles the common cases — signal-loss spikes, transient outliers — without the complexity of statistical methods.

**Consequences:** The spike threshold is exposed in the operation's dialog or in a Settings panel as a single configurable parameter. The detection algorithm is documented in `Docs/04_EDITING.md`. Iteration paths if v1 is insufficient: a flag-for-review mode becomes a Settings option; more sophisticated detection (Hampel filter, Kalman smoothing) becomes a separate, more careful operation. None of this is in v1 unless real use surfaces a need.

---

## D-018: Track trim — time-based, both ends

**Status:** Accepted (2026-04-30)

**Decision:** Track trimming uses a **single Edit → Trim Track…** menu item that opens a dialog with two optional sections: "Trim start at time" (with a time picker defaulting to the track's actual start) and "Trim end at time" (with a time picker defaulting to the track's actual end). Each section has a checkbox to enable it. A live-preview overlay on the map shows the points that would be removed in red as the user adjusts the controls. OK commits all enabled trims as one undo unit; Cancel discards. **Speed-based trim is deferred** — time-based trim handles every realistic boundary-cleanup case fully when the user remembers (or can look up) when they actually finished the activity.

**Alternatives considered:** Speed-based trim with min/max thresholds at each end, allowing the user to express "trim until speed exceeds 1 km/h at the start, then trim from the end while speed is below 1 km/h or above 30 km/h" to handle the "stood around then drove away" double-junk case (rejected as v1 over-engineering — time trim handles all of these cases identically when the user supplies a time, and the speed variant is a convenience for "I don't remember when I stopped" that doesn't earn its complexity); separate menu items for start trim and end trim (rejected as more menu clutter than a unified dialog); an always-on time scrubber rendered on the map view (rejected as visual clutter for an infrequent operation).

**Rationale:** Following Occam's Razor. Time-based trim handles every realistic boundary-cleanup case the user will encounter in the workflows described. Speed-based trim is a convenience for a use case the user articulated as marginal and acceptable to defer. A single dialog with both ends covered is cleaner than separate menu items.

**Consequences:** The Trim Track operation honors the "operates on selection if present" principle for time-based trim within a selected range, though the typical use is no-selection-trim-the-whole-track. Speed-based trim is captured as a future enhancement path in HANDOFF.md if real use surfaces a need; it would extend the same dialog with additional optional sections rather than replacing the existing structure.

---

## D-019: Self-signed certificate for local development signing

**Status:** Accepted (2026-05-04)

**Decision:** For local development signing during milestones M0 through M9, the project uses a **self-signed code-signing certificate** ("Lab Code Cert") held in the developer's login keychain in place of Xcode's Personal Team automatic-signing identity. The certificate is issued locally via Keychain Access's Certificate Assistant with a 10-year validity period, the `Digital Signature` key usage, and the `Code Signing` extended key usage. Both `GPXEditor` and `GPXEditorTests` targets are signed with the same certificate (Manual signing style, no Development Team). Hardened Runtime, App Sandbox, the entitlements file, and the broader notarization-readiness posture are unchanged. The transition to a Developer ID Application certificate at M10 remains a single Xcode build-setting change, identical in shape to the current switch.

**Alternatives considered:** Continue using Xcode's free Personal Team automatic signing (the prior posture; discarded because Personal Team certificates expire after one year and are subject to silent revocation when Apple rotates issuing infrastructure — three revoked entries are presently visible in the developer's keychain, each one having silently broken builds at unpredictable moments); wait for the paid Developer ID Application certificate to become active and use it for development as well as distribution (delays the elimination of the expiry/revocation failure mode and conflates two categorically different signing roles); ad-hoc signing (`-` identity) (would lose Hardened Runtime + library validation enforcement, weakening the security-posture testing the development build is meant to support).

**Rationale:** Personal Team certificates have a one-year validity and are subject to revocation events outside the developer's control. Each revocation silently breaks builds until the developer notices, then forces a re-provisioning roundtrip with Apple's infrastructure. A self-signed certificate with a 10-year validity eliminates that failure mode entirely; the certificate's only function during development is to satisfy macOS code-signing requirements (Hardened Runtime, sandbox enforcement) on the developer's own machine, none of which depend on Apple's signing infrastructure. The certificate is local-only — it has no relationship with Apple's servers, is never published, and is replaced by the Developer ID Application certificate at M10. The 10-year validity is a deliberate reach: by then the project will either have moved past needing it (Developer ID active since M10) or it can be regenerated trivially.

**Consequences:** The `CODE_SIGN_STYLE` build setting changes from `Automatic` to `Manual` for both targets; `CODE_SIGN_IDENTITY` is set to `Lab Code Cert`; `DEVELOPMENT_TEAM` is cleared. Both targets must use the same certificate because Hardened Runtime's library validation requires consistent signing identity across the host app and any loaded test bundles. The certificate's private key is never committed (analogous to the Developer ID Application private key — same `.gitignore` rules cover both). M10's distribution-build work explicitly switches `CODE_SIGN_IDENTITY` back to `Developer ID Application: <name>` and re-enables Automatic signing if desired; that switch is a single build-setting edit and does not require any code, entitlement, or sandbox change. SECURITY.md is updated in the same commit as this decision to reflect that development builds may be signed with either a self-signed certificate or a Personal Team identity. The procedure is captured as a reusable best-practice doc at `Docs/self-signed-cert-for-development.md`.

---

## D-020: OpenTopoData dataset choice for v1

**Status:** Accepted (2026-05-08)

**Decision:** GPXeditor's Pin to Ground and Snap to Ground features query elevation from the public **OpenTopoData** service (`api.opentopodata.org`) using the **`mapzen` dataset**.  `mapzen` is OpenTopoData's hosted blend of Mapzen Terrain Tiles — itself a global blend of SRTM, ASTER, GMTED2010, NED, EU-DEM and ETOPO1 — picked per location for best available coverage.  Public-server limits are honored: ≤1 request/second, ≤1000 requests/day.  Dataset choice is hardcoded in v1;  no user-facing picker.

**Alternatives considered:** `aster30m` (global ASTER 30m DEM, better at high latitudes but coarser elsewhere); `srtm30m` (limited to ±60° latitude — excludes Alaska, much of Canada, Scandinavia); `ned10m` (US-only 10m NED — finer resolution but no use abroad); self-hosted OpenTopoData server (would remove rate limits but adds infrastructure burden incompatible with a give-away utility); rolling our own DEM service (out of scope — the project's value is in the editing UI, not DEM hosting); a Settings-level dataset picker (rejected for v1 per Occam's Razor — invites questions ("what's the difference between aster30m and srtm30m?") that the v1 give-away utility shouldn't have to answer);  ship one default, observe real use, iterate.

**Rationale:** `mapzen` covers everywhere a hiker / cyclist might go without forcing the user to choose a DEM by region.  The blend quietly picks the best-resolution source per location — good in the US (NED), good in the EU (EU-DEM), good elsewhere (ASTER, SRTM, ETOPO1 fallback for ocean).  Picking a single globally-usable, free-tier-friendly dataset satisfies the M7 "selection or whole-master" Pin to Ground use case without dataset-management UI complexity.  A future Settings-level picker is in HANDOFF.md's deferred parking lot if real users hit cases the v1 default doesn't fit.

**Consequences:** `Services/ElevationService.swift` bakes `mapzen` into the request URL via the `dataset` static constant.  Allow-list enforcement against `api.opentopodata.org` happens in the same file before every request — `NetworkAllowList.swiftSideEndpoints` is the single source of truth and a regression test (`ElevationServiceTests.hostIsAllowListed`) ties the two together so changing one without the other breaks loudly.  Per-batch rate limiting is enforced via an actor-isolated `nextAllowedRequestTime` clock that defers each outbound request to honor the 1-req/sec gap;  a 500-point Pin operation runs as 5 batches over ~5 seconds plus latency.  On a 429 response with Retry-After header the service waits per the header and retries once before surfacing `ElevationServiceError.rateLimited`.  The User-Agent set on the URLSession matches the WebView's UA per SECURITY.md "Identifying User-Agent" — `GPXeditor/<sha>+ (+<repo URL>)`.  No SECURITY.md change is required for this decision because the host (`api.opentopodata.org`) was already named in the network allow-list at M2 in anticipation of M7.

---

## End of accepted decisions

Add new decisions below this line as D-021 onward. Maintain the same format and the append-only rule.
