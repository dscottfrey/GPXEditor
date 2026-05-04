# GPXeditor — Code and Project Conventions

This document records the project-wide engineering and UX conventions GPXeditor is built on. It complements `DECISIONS.md` (architectural choices) and `SECURITY.md` (sandbox and trust posture) by describing *how* the code should be written and *what patterns* recur across the codebase.

When you encounter a situation this document doesn't cover, the spirit of the rules below should still guide the decision. When the spirit produces an answer that contradicts an explicit rule, raise the contradiction in conversation rather than silently choosing one — that's exactly the kind of edge case worth documenting.

## Engineering principles

These are project-wide and apply equally to Swift, JavaScript, configuration files, and shell scripts.

### Occam's Razor

Implement the simplest version that achieves the goal. Refine based on what real use surfaces, not anticipated need. This is a project-wide rule, not advice — a refusal to add complexity now in case it might be needed later.

When two approaches are technically reasonable, pick the smaller one. A weighted-average algorithm is technically more elegant than a uniform average, but if uniform-average works for the use case in the user's hands, ship uniform-average and revisit only if the user reports it feeling wrong. This rule is what kept the brush algorithms (D-016), the spike detection (D-017), and the trim operation (D-018) at their simplest viable shapes despite reasonable arguments for more.

The rule does *not* mean "be lazy" or "skip thinking." It means: do the thinking, identify the simplest shape that works, then resist the urge to pre-build for use cases that haven't been validated. Iteration is the cheap part of software; predicting what will be needed is the expensive part.

When proposing a feature or change, the proposing turn should always include "what would the simplest version of this look like?" before any more elaborate version is suggested. If the simplest version is sufficient, ship it; the elaborate version is iteration material.

### Code comments are part of the deliverable

Every non-obvious decision, algorithm, system interaction, or seam between subsystems gets an inline comment that explains *why*, not *what*. The *what* is what the code already says; the *why* is what disappears the moment the conversational context is gone.

The audience for these comments is explicit: future-Scott six months from now, who has forgotten the details, plus any external reader who clones the public repository with no knowledge of the conversations that produced the code. Treat comments as documentation written for those readers, not as decoration.

Apply this rule uniformly to Swift, JavaScript, plist files (XML comments are valid), entitlement files (XML comments work there too), shell scripts, and any configuration file that supports comments. If something in the file's behavior depends on context that isn't visible in the file itself — a sandbox entitlement, a particular GPX format quirk, a Leaflet API gotcha, why we chose Swift-side computation over JS-side — comment it.

Lean toward over-commenting. We are not optimizing for terseness or "self-documenting code." We are optimizing for legibility months later and to a stranger. A function that takes 10 lines of code plus 8 lines of comment is the right shape for this project; the same function with no comments and a clever name is not.

### Nothing fails silently

Errors must surface. Three concrete rules:

- No `try?` on a Swift call whose failure has any user-visible consequence. If failure means a file didn't save or a network call returned garbage, the error becomes an alert, a logged message, or a returned `Result.failure` — never a swallowed nil.
- No empty `catch {}` blocks. If a caught error is genuinely safe to ignore, the catch block contains a comment explaining why, in plain language. ("This API throws on cancellation; cancellation is the expected control flow here, not an error.")
- No JavaScript `try { ... } catch (e) {}` patterns either. Errors in JS get reported back to Swift via the bridge with a structured error message; Swift decides whether to surface them.

The principle: a future maintainer reading the code should be able to tell, from the code, what every failure path does. Silent swallowing makes that impossible.

### No personal data, no telemetry, no version checks

The application makes no network calls beyond those documented in `SECURITY.md`. No analytics. No crash reporting service. No "phone home" for version checks. No build-time or run-time data collection of any kind. Adding any of these is a `D-XXX` decision in DECISIONS.md plus an update to SECURITY.md's network allow-list — not a routine code change.

## UX principles

Conventions for how the application behaves toward the user, applied across modules and operations.

### Selection-aware operations

Operations that *could* apply to a selection or to a broader scope use this rule consistently: **if a selection exists, the operation applies only to the selection; if no selection exists, it applies to the natural broader scope** (the whole track for trim-style operations, the master for export-style operations, the whole project for project-wide operations).

This is invisible to the user as a rule but visible as consistent behavior — every operation that takes a selection-or-default behaves the same way. Applies to Delete, Snap to Ground, GPS spike removal, the Trim Track operation, simplification-of-selection, and so on. Avoids surprises and matches how every major macOS app behaves.

When implementing a new operation, the question to ask is "what does this do with no selection?" The default scope is documented in each operation's description in `Docs/04_EDITING.md`.

### Color is never the only signal

Visual distinctions in the UI must use at least two cues, never just color. This is partly an accessibility rule (the user has color-vision constraints, see D-013) and partly a robustness rule (color is unpredictable against varying basemap backgrounds).

Concrete implications: track segments are distinguished by both color *and* line style (cycling through solid/dashed/dotted when the palette wraps). Track lines render with a contrasting halo so they remain visible regardless of basemap. Selected items are shown by both an outline and a sidebar highlight, not just a color change. Validation errors are surfaced by both icon and text, not just red coloring.

When designing a new UI affordance, the question to ask is "how does this read to someone who can't distinguish red from green?" If the answer is "they wouldn't see the distinction," add a second cue.

### Direct manipulation, minimal modal dialogs

Single-point operations happen in direct manipulation in the Point Tool — drag to move, click-on-line to add, right-click for context. Modal dialogs are reserved for operations that genuinely need parameters before committing (Trim Track, Filter by Speed if added later, Pin to Ground confirmation). The default is "do the thing immediately, undo if wrong"; the dialog is reserved for "set up the thing carefully because the result will be tedious to fix."

This applies to operation design more broadly: when adding a new feature, the question is "can the user just do this and undo if they don't like it?" If yes, no dialog. If the operation is destructive *and* hard to predict the result of, a dialog with live preview earns its place.

### Tool-switching is cheap; tool roundtrips are not a feature

Single-key shortcuts for every tool, Escape always returns to the Point Tool, spacebar-held temporarily activates Hand Tool from any other tool. The Adze frustration this fixes is documented in D-014 — no operation should require more than one tool switch in the common case, and most should require none.

When designing a new feature, the question is "does the user have to leave their current tool to do this?" If the answer is yes and the feature is common, the design is wrong; the operation needs to be available from the Point Tool (or wherever the user typically is) without a switch.

## Architectural invariants

Project-wide invariants that hold across modules. Violating these is not "stylistically poor" — it is a bug.

### Swift is the source of truth; JavaScript is the presentation layer

All authoritative document state lives in Swift. The `GPXSession` data model, the master/subsidiary relationships, the segment colors, the per-segment edit history, the project file contents — all Swift. JavaScript holds **only** rendering state: the current map view's polylines, the brush preview overlay, the selection-highlight markers, the basemap tile layer.

Edits originate from JavaScript (the user clicks on the map, drags a brush, etc.) but are immediately marshaled to Swift via the bridge. Swift mutates the model, registers the operation with `NSUndoManager`, marks the document dirty, and pushes the new state back to JavaScript for redraw. JavaScript never modifies state autonomously; if it appears to (e.g., the user starts a brush stroke and the preview moves), the preview is transient JavaScript state that does not commit until the gesture ends and Swift accepts the operation.

This invariant is what makes the architecture stable: there is exactly one place to look for "what does this project actually contain right now," and it is Swift. JavaScript can always be reset to match Swift's view of the world; the reverse is not true and must never become necessary.

### The data and operations layers are platform-agnostic

Code in `Models/` and the GPX-handling and editing parts of `Services/` (parser, writer, the `BrushTool` protocol, concrete brushes, `TrimOperation`, `SpikeDetectOperation`, `ElevationService`, and similar) is written portably. Foundation may be imported. AppKit, SwiftUI, and WebKit must not. These types contain no UI code, no view types, no Cocoa-specific types like `NSColor` — color values live as hex strings in the data model, and `Color` from SwiftUI is used only in UI code.

The single exception within `Services/` is `MapBridge`, which is platform-bound by definition because it talks to WKWebView. `MapBridge` may import WebKit. It must still avoid AppKit unless required for the bridge work itself.

This invariant exists because of D-007's note about a hypothetical future iOS port. The data model and editing operations could be lifted into an iOS app, a CLI tool, or a server-side validator without modification; only the UI and bridge layers need to be rewritten. Even if the iOS port never happens, this invariant produces cleaner separation between "what the data is" and "how the user sees it."

`ViewModels/`, `Views/`, and `Components/` freely import AppKit, SwiftUI, and Combine as needed. `WebResources/` is JavaScript/CSS/HTML and is separately governed (see `Docs/03_WEB_RESOURCES.md`).

### The vendored web assets are not modified at runtime

Files in `WebResources/` are read-only at runtime. The application does not write to them, generate them dynamically, or fetch alternate versions. The `loadFileURL` call that loads `index.html` into the WKWebView grants read access *only* to `WebResources/`, not to anywhere else.

Updating a vendored asset is a deliberate development-time event with the protocol documented in SECURITY.md. Generated content (e.g., dynamic per-track configuration sent to JavaScript) is passed via the bridge as data, not by writing to vendored files.

## Swift code conventions

### File organization

The codebase uses **type-kind grouping** at the top level. The standard layout, matching the pattern from prior projects:

- `Models/` — pure data types with no UI dependencies. `GPXModel`, `Track`, `Segment`, `TrackPoint`, `Waypoint`, `GPXSession`, and the supporting types live here.
- `Services/` — non-UI logic that does work. GPX parsing and writing, the `MapBridge` (the Swift side of the JS↔Swift bridge), the elevation service, the `BrushTool` protocol and concrete brushes, the editing operations, the spike detector. Anything that takes inputs and produces outputs without being a view.
- `ViewModels/` — the connective tissue between models and views. The main `SessionViewModel` owns project state and exposes it to the UI via SwiftUI's observation system.
- `Views/` — top-level screen-scope views. `ContentView`, `MapView` (the `NSViewRepresentable` wrapping `WKWebView`), `Sidebar`, `Inspector`, `StatsPanel`, `Toolbar`.
- `Components/` — reusable UI fragments smaller than a screen. `SegmentRow`, `WaypointMarker`, `ColorSwatch`, `BrushSizeSlider`, `IconPicker`. The Views/Components distinction matters: a Component is a building block that could appear in multiple places; a View is a screen.
- `WebResources/` — vendored static JavaScript, CSS, HTML for the WKWebView. Treated as a peer top-level folder rather than nested under any Swift type kind, since it's a distinct artifact under different rules (see `Docs/03_WEB_RESOURCES.md`).
- `Resources/` — Apple bundle resources: `Assets.xcassets`, `Info.plist`, `GPXEditor.entitlements`.

Tests follow the same shape: `GPXEditorTests/Models/`, `GPXEditorTests/Services/`, plus `GPXEditorTests/Fixtures/` for sample GPX files (rules in `Docs/06_FIXTURES.md`).

When a logical subsystem (the GPX I/O subsystem, the editing subsystem, the bridge, the UI) spans multiple folders, that's expected — type-kind grouping deliberately does not co-locate by subsystem. The directive files in `Docs/` describe each subsystem as a logical whole, naming the specific files and types involved across folders.

Within a file, types are ordered: public types and protocols first; private supporting types after; private extensions and helpers last. Each file should be readable top-to-bottom as a story about that file's purpose.

### Small files

Files stay small. The default discipline is one type per file, with the file named after the type. When a file approaches 200-300 lines, look for a natural split point — a private helper type that wants to be a separate file, an extension that has grown its own concerns, a section that doesn't share much with the rest. Splitting earlier rather than later prevents the kind of monolith refactor that requires hours of rework; small files are also easier to review, easier for Claude Code to operate on without thrashing context, and easier to navigate.

This is a habit, not a hard rule with a precise line count. The line count is a prompt to look for a seam, not an automatic split trigger. Some files are naturally small (a 30-line struct definition is fine); some are naturally a bit larger (a complex parser may need 400 lines to be coherent). The discipline is: notice when a file is getting long, and pre-emptively split when a clean seam appears. When in doubt, split — the cost of a small file you might have left combined is trivial; the cost of a large file that should have been split is hours of refactor weeks later.

### Naming

Apple's API Design Guidelines apply by default. Specific points worth calling out:

- The acronym `GPX` is treated as a single word in PascalCase identifiers: `GPXModel`, `GPXEditor`, `GPXDocument`. Lowercase forms (`gpx_data`) are not used in Swift. Some places lowercase the leading character (`gpxData` for a property name) per the standard convention for camelCase.
- The display name `GPXeditor` (with lowercase 'e') is **not** used in code identifiers — that's a UI string only. Code identifiers use `GPXEditor`.
- Boolean properties read as predicates: `isMaster`, `hasUnsavedChanges`, `canExport`, not `master`, `unsavedChanges`, `exportable`.
- Action types and operation names match the user-facing terminology where reasonable: `SmoothBrushOperation`, `TrimTrackOperation` rather than abstract internal names.

### Errors and `Result`

Use Swift's `Error` types for failures. Functions that can fail synchronously return either a throwing function (`throws -> T`) or a `Result<T, SomeError>` depending on whether the caller needs to inspect the error. Avoid `T?` as a stand-in for "this can fail" — it loses the reason for failure.

Caught errors get logged or surfaced; per the "nothing fails silently" rule, the path between "an error occurred" and "the user knows about it (or it's deliberately handled)" must be visible.

### Immutability and value types

Default to `let` over `var` and to value types over reference types. Reference types (`class`, `actor`) earn their place when identity matters or when reference semantics simplify the code; otherwise `struct` is the default.

The data model in `Models/` is heavily value-typed: `GPXSession`, `Track`, `Segment`, `TrackPoint`, `Waypoint` are all structs. Mutations happen by replacing the value rather than by mutating in place when feasible — this makes operations easier to reason about and integrates naturally with `NSUndoManager`'s state-snapshot pattern.

### `final` on classes

Reference types that aren't designed to be subclassed are marked `final`. This makes the inheritance design explicit (subclassing is opt-in, not opt-out) and produces small performance benefits via static dispatch. The convention is taken from prior project work — see CONVENTIONS in IcarusVirtualHub for the same rule.

### Concurrency

Swift's modern concurrency (`async`/`await`, `actor`, `@MainActor`, structured concurrency) is preferred over GCD/`DispatchQueue` for new code. UI work runs on `@MainActor` (which is the default for SwiftUI views and view models). Network calls use `async` `URLSession` methods. Long-running computation that blocks the main thread is offloaded to a background actor or a non-main task.

## JavaScript code conventions

### Modern syntax, no transpilation

The JavaScript in `WebResources/editor.js` and any other custom JS files uses modern ES2020+ syntax targeted at WebKit's current feature set (which is whatever ships in macOS 14's Safari/WebView). No Babel, no TypeScript, no build step. The file as committed is the file as loaded.

This is enabled by the controlled deployment target — we know exactly which JavaScript engine will run this code (WKWebView on macOS 14+). We do not need to transpile for unknown browsers because the code does not run in unknown browsers.

### File organization

The `WebResources/` directory contains:
- `index.html` — the host page loaded by the WKWebView. Minimal — sets up the document, loads the vendored libraries and `editor.js`.
- `editor.js` — our editing layer on top of Leaflet. Initializes the map, defines the bridge handlers, manages the rendering pipeline.
- `leaflet.js`, `leaflet.css`, `simplify.js` — vendored, hash-pinned, do not modify directly. Update protocol in SECURITY.md.
- Project-specific CSS — colocated with `editor.js` in a small `editor.css` if it exceeds inline-style scope.

`editor.js` should not exceed roughly 800 lines. If it grows beyond that, split by concern (e.g., `bridge.js` for bridge handlers, `selection.js` for selection rendering) using ES modules or simple `<script>` tags from `index.html`. The split happens when the file becomes hard to navigate, not on a fixed line count.

### Avoid framework patterns

No React, no Vue, no jQuery, no build tooling. The application's UI is SwiftUI; the WebView is for map editing only. JavaScript code is procedural, modular, and small. Functions and modules over classes; closures over component frameworks.

The vendored Leaflet library is the one large dependency, and we use it directly rather than wrapping it in framework abstractions.

### `console.log` is not for production

Diagnostic JS logging during development is fine, but `console.log` calls left in shipped code are a smell. The bridge has a `log` message type that JS can use to send structured log lines back to Swift, where they appear in the Xcode console alongside Swift logs and are gated by build configuration. Use it for anything you'd want to see in a production build's logs.

## JavaScript ↔ Swift bridge protocol

The bridge is the seam between Swift and JavaScript. Its protocol shape is a project-wide convention; specific message types are documented in `Docs/02_MAP_AND_BRIDGE.md`.

### Message envelope shape

Every message in either direction has the structure:

```json
{
  "type": "verb_in_snake_case",
  "id": "optional-uuid-for-correlation",
  "payload": { /* type-specific data */ }
}
```

The `type` field is the verb that names the operation: `"delete_points"`, `"move_point"`, `"load_session"`, `"render_brush_preview"`, etc. Snake-case is used to make the message format language-neutral — neither Swift's camelCase nor JS's camelCase dominates the wire format.

The `id` field is optional and used when a request expects a response. JavaScript can send a `query_segment_stats` with an `id`, Swift computes the answer and replies with `segment_stats_result` using the same `id`. Most messages are fire-and-forget and don't need it.

The `payload` is type-specific and structured per the message type's documented schema in `Docs/02_MAP_AND_BRIDGE.md`.

### JS → Swift via WKScriptMessageHandler

JavaScript posts messages to `window.webkit.messageHandlers.gpxBridge.postMessage(message)`. The `gpxBridge` handler name is registered once at WebView setup. Messages are JSON-encoded automatically by WKWebView's bridge. The Swift-side `WKScriptMessageHandler` receives the parsed message, dispatches by `type`, and validates the payload against the expected schema.

Validation is strict: an unknown message type or a payload that doesn't match its schema is logged as an error (visible bridge violation) and discarded. Failed validation never silently mutates state.

### Swift → JS via evaluateJavaScript

Swift calls `webView.evaluateJavaScript("window.editor.handleMessage(\(jsonEncodedMessage))")` to send a message into the WebView. JavaScript's `window.editor.handleMessage(message)` dispatches by `type` and routes to the appropriate renderer or state-updater.

The pattern is symmetric: same envelope shape, same dispatch mechanism, same strict validation expectations on the receiving side.

### What does not go through the bridge

Static rendering data that does not change during a session — basemap tile URLs, color palette defaults, the icon set for waypoints — is loaded by JavaScript at startup from `index.html`-embedded JSON or from a static file in `WebResources/`. The bridge is for *dynamic* state and operations, not for shipping configuration that doesn't change after load.

## Comments and documentation

Beyond the "comments are part of the deliverable" principle, three specific patterns:

### File-level header comments

Every Swift and JS source file begins with a brief comment block explaining the file's purpose in two or three sentences, the public surface it exposes, and any non-obvious dependencies. This is the entry point for someone reading the codebase: the question "what does this file do" should be answerable without reading the code itself.

### Function-level documentation

Public Swift functions get DocC-compatible doc comments (`///` triple-slash) describing what the function does, its parameters, what it returns, and any errors it can throw. Private functions get a brief comment if their purpose isn't immediately obvious from the name.

### Inline comments at non-obvious lines

If a line of code does something the next maintainer might not expect — a subtle precondition, a workaround for an Apple framework quirk, a deliberate choice that another reasonable choice was rejected for — that line gets an inline comment.

## Tooling

Xcode is the primary IDE. Claude Code is used for code edits from the repository root. There is no required Swift formatter or linter in v1 — the codebase is small enough that style consistency emerges from the conventions in this document. If style drift becomes a real problem in the future, adding a formatter (`swift-format` is Apple-published and reasonable) is a future decision.

The `.swift-version` file at the repository root pins the Swift toolchain version to whatever ships with the targeted Xcode version. Update deliberately; do not bump silently.

## When this document should be updated

Update CONVENTIONS.md when:

- A new project-wide pattern emerges that should be applied consistently (e.g., a new error-handling pattern, a new comment-format convention).
- A pattern in this document is overturned and a new pattern is adopted in its place.
- A new module is added that introduces patterns the rest of the codebase will follow.

Updates are made in place (this is a current-state document, not append-only like DECISIONS.md). The git history preserves the change history. Significant changes should be discussed before being committed.

When a per-module pattern is project-wide and worth promoting from a per-module directive into this document, that promotion is itself a small refactor — move the text up here, leave a pointer in the per-module directive saying "see CONVENTIONS.md."
