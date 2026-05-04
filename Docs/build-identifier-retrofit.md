# Build Identifier Retrofit — Xcode Project Best Practice

A reusable procedure for adding automated build identification (timestamp + git SHA + dirty marker) to an existing Xcode project so every build embeds an unambiguous identifier in its About panel.

This document is both a reference and a runnable Claude prompt: hand it to a Claude Code session along with "retrofit this project per the procedure" and the agent has everything it needs.

---

## What this is for

Every build embeds in the About panel:

- A timestamp `YYMMDDhhmm`
- The short git SHA of HEAD
- A `+` dirty marker when the working tree had uncommitted changes
- The active configuration

Example display: `Build 2605041335 · a7672bc+`

Release builds additionally get a monotonically-increasing `CFBundleVersion` (matching the timestamp) for App Store / TestFlight / Sparkle compatibility, *without* mutating any committed file.

**Why:** bug reports and screenshots become useless when you can't tell which build they came from. Manual build-number incrementing fails closed — humans forget exactly when the information matters most. Automation removes the failure mode.

---

## Decisions baked into this approach

For when future-you wonders why something was done this way.

### Mutate the *built* Info.plist on Release, not the source

If the target uses `GENERATE_INFOPLIST_FILE = YES` (Xcode 16 default for new projects), there is no source `Info.plist` file to mutate. Solution: PlistBuddy on the *built* Info.plist (`$BUILT_PRODUCTS_DIR/$INFOPLIST_PATH`) AFTER Xcode generates it but BEFORE Code Sign. Works for both generated and hand-maintained modes. Never touches a committed file. The source `CURRENT_PROJECT_VERSION` in `.pbxproj` stays at its baseline value.

### Two Run Script phases, not one

The two operations need different positions in the build phase order:

- **"Generate BuildInfo"** runs BEFORE Compile Sources — the Swift file must exist before the compiler reads it.
- **"Bump CFBundleVersion (Release only)"** runs AFTER Copy Bundle Resources (which is implicitly after Process Info.plist on a generated-Info.plist project) — the built plist must exist before we mutate it.

A single script can't be in two places. So: two phases, two scripts.

### Track the BuildInfo.swift placeholder; tolerate or suppress its noise

`BuildInfo.swift` is regenerated on every build. Three options for handling git-status noise:

1. **Tolerate the noise.** For a solo dev who stages by filename (not `git add -A`), the noise lives only in `git status` output and Xcode's "M" badges. Doesn't pollute commits. **Default for solo projects.**
2. **`git update-index --skip-worktree` per clone.** Eliminates noise but requires every contributor to remember the setup step. **Use for a multi-contributor public project.**
3. **Redesign to read from `Bundle.main.infoDictionary`.** No source file is touched on every build. More invasive but eliminates the issue entirely. **Use when contributor onboarding matters more than implementation simplicity.**

Why not pure gitignore: `PBXFileSystemSynchronizedRootGroup` (Xcode 16+) determines target membership at build-graph construction time, before any Run Script runs. A pure-gitignore approach risks the first build on a fresh clone omitting `BuildInfo.swift` from the binary.

### About panel via `NSApp` + `.commands` (macOS SwiftUI)

Override the SwiftUI default "About <App>" menu item with `.commands { CommandGroup(replacing: .appInfo) { ... } }`. The button calls an AppKit helper that uses `NSApp.orderFrontStandardAboutPanel(options:)` with a `.credits` `NSAttributedString` containing the build line. The standard panel's icon, name, version, and copyright are preserved; only the Credits area gets a build line added.

For iOS or a SwiftUI custom About view, just put `Text("Build \(BuildInfo.displayString)")` somewhere visible.

---

## Phase 0 — Survey before editing

Don't write anything until you know:

1. **Platform and targets.** Which native targets ship as apps (`com.apple.product-type.application`)? Skip framework / extension / test targets unless they need their own About.
2. **Info.plist mode per target.** Search for any hand-maintained `Info.plist` file. If none and `.pbxproj` has `GENERATE_INFOPLIST_FILE = YES`, it's generated mode. The Release-bump path differs depending on which mode you're in.
3. **Existing About surface.** Search for `orderFrontStandardAboutPanel`, custom About views, references to `CFBundleShortVersionString`. Note where existing UI lives (or that none exists).
4. **`.gitignore` is at the repo root.**
5. **Existing version-related build phases.** Search `.pbxproj` for `agvtool`, `PlistBuddy`, `CFBundleVersion`, or any `PBXShellScriptBuildPhase`. Surface conflicts before adding more.
6. **Source folder per target.** The folder name inside `$SRCROOT` — usually matches the target name but not always.
7. **Synchronized groups vs classic membership.** Search `.pbxproj` for `fileSystemSynchronizedGroups`. If present, files dropped into the synchronized folder are auto-included in the target — no manual project-navigator drag needed. The directive's "drag into navigator" step is unnecessary on Xcode 16 synchronized projects.

Summarize, propose, **wait for confirmation before editing.**

---

## Phase 1 — Files Claude writes

### `Scripts/generate_build_info.sh` (tracked, executable)

Writes `<target_source>/Generated/BuildInfo.swift` with timestamp / SHA / dirty / configuration. Always runs.

### `Scripts/bump_built_info_plist.sh` (tracked, executable)

On Release only, PlistBuddy-mutates `$BUILT_PRODUCTS_DIR/$INFOPLIST_PATH`'s `CFBundleVersion` to a fresh timestamp. Exits 0 immediately on Debug.

### `<target_source>/Generated/BuildInfo.swift` (tracked placeholder)

Static-constant placeholder with sentinel values (`"uninit"`). The script overwrites it every build. Track it so the synchronized group sees it on a fresh clone.

**`git add -f` it** if `.gitignore` matches the path before you stage.

### `.gitignore` addition

    **/Generated/BuildInfo.swift

Documents intent; inert on a tracked file. Caught for any other future `Generated/` files.

### About panel wiring (macOS SwiftUI)

`<target_source>/Views/AboutPanel.swift` — AppKit helper, `@MainActor enum AboutPanel { static func show() }` calling `NSApp.orderFrontStandardAboutPanel(options: [.credits: ...])`.

Modify `<target>App.swift` — add `.commands { CommandGroup(replacing: .appInfo) { Button("About <App>") { AboutPanel.show() } } }` on the scene. Forward-compatible with `WindowGroup → DocumentGroup` migration since `.commands` attaches to the scene.

---

## Phase 2 — Manual Xcode steps for the human

These three steps require Xcode's UI. **Do NOT edit `.pbxproj` programmatically** — risk to project integrity isn't worth it.

### Step 1 — Add "Generate BuildInfo" Run Script phase

1. Project Navigator → top item → TARGETS → app target.
2. **Build Phases** tab → `+` → **New Run Script Phase**.
3. Rename to `Generate BuildInfo`.
4. **Drag it ABOVE Compile Sources** (also called Sources).
5. **Uncheck "Based on dependency analysis"**.
6. Paste this exact script body — **the surrounding `"` characters ARE part of the literal command, not markdown formatting**:

       "${SRCROOT}/Scripts/generate_build_info.sh" "${SRCROOT}/<target_source>/Generated/BuildInfo.swift"

   Verify exactly **four `"` characters** in the box. Replace `<target_source>` with the actual folder name.

### Step 2 — Add "Bump CFBundleVersion (Release only)" Run Script phase

1. Same Build Phases tab → `+` → **New Run Script Phase**.
2. Rename to `Bump CFBundleVersion (Release only)`.
3. Position it as the **LAST** phase (after Copy Bundle Resources).
4. **Uncheck "Based on dependency analysis"**.
5. Paste:

       "${SRCROOT}/Scripts/bump_built_info_plist.sh"

   Verify exactly **two `"` characters**.

### Step 3 — Disable User Script Sandboxing

1. Same target → **Build Settings** tab.
2. Filter buttons: **All** + **Combined**.
3. Search box: type `sandbox` (short queries match where longer ones sometimes miss).
4. Find **Build Options → User Script Sandboxing**. Click the value (`Yes`) → set to **No** (for both Debug and Release).

**Why this is safe:** This setting affects only build-time tooling. It does NOT affect the shipped binary's App Sandbox or Hardened Runtime, which remain enabled per the `.entitlements` file. SECURITY.md (if present) does not need an update — this isn't a runtime app capability.

**Why it's necessary:** Xcode 16 default sandboxes Run Scripts so they can only read inside the build directory. Our scripts need to read `Scripts/*.sh` (in the source tree) and run `git` (reads `.git/`). Without disabling, builds fail with cryptic "No such file or directory" errors that don't tell you sandboxing is the cause.

---

## Phase 3 — Verification

1. **`Cmd-B` Debug build.** Should succeed. Build log shows:
   - `BuildInfo: <timestamp> <sha> dirty=<bool> config=Debug`
   - `bump_built_info_plist: skipping (CONFIGURATION=Debug)`
2. **`cat <target_source>/Generated/BuildInfo.swift`** — real values, not `"uninit"`.
3. **`Cmd-R` run + menu → `About <App>`.** Build line appears in the Credits area, looks like `Build 2605041335 · a7672bc+`.
4. **Archive once (Release).** Build log shows `bump_built_info_plist: CFBundleVersion = <timestamp>`. The archived `.app`'s Info.plist has the timestamped `CFBundleVersion`; source `CURRENT_PROJECT_VERSION` in `.pbxproj` is unchanged. `git status` clean afterward.

---

## Known gotchas

### "No such file or directory" on first build

Almost always one of:

1. **Quote stripping during paste.** If you copied the script body from a markdown code block, the surrounding `"` characters may have been stripped (markdown convention is "fence is formatting, content inside is the literal"). Re-check the script body in Xcode — it must include the literal `"` quotes around each path. Count them: four for the first script, two for the second.
2. **User Script Sandboxing = YES.** The sandbox blocks the script from reading `Scripts/` and from running `git`. Set the Build Setting to No.

### About panel shows wrong-cased app name

The standard `NSApp` About panel uses `CFBundleName`, not `CFBundleDisplayName`. With `GENERATE_INFOPLIST_FILE = YES`, Xcode 16 hardcodes `CFBundleName` to track `PRODUCT_NAME`, which typically uses PascalCase. The dock and menu bar correctly show the lowercase display name from `CFBundleDisplayName`.

Three workarounds (all defer-able unless the casing actually matters):

- Run Script + PlistBuddy override of `CFBundleName` post-generation.
- Switch to a hand-maintained `Info.plist`.
- Live with it — the panel still functions.

### `BuildInfo.swift` perpetually shows in `git status`

Expected. The build regenerates it. Three options:

- **Tolerate.** Solo dev, stage by filename, never see it in commits.
- **`git update-index --skip-worktree`** per clone per developer.
- **Bundle redesign:** read from `Bundle.main.infoDictionary` instead. Eliminates noise but requires reworking the scripts and `BuildInfo.swift`.

### Synchronized-group projects: skip the "drag into Project Navigator" step

Xcode 16 projects using `PBXFileSystemSynchronizedRootGroup` auto-include any file written into the synchronized folder. The traditional manual drag is a no-op — the file will already be a target member. Verify by opening Build Phases → Compile Sources after the file is created; it should appear without manual addition.

### `.gitignore` and `git add` interact at staging time

If you run `git add <folder>/` and `.gitignore` matches a file inside, the file is silently skipped — no error. To force-track a file that matches `.gitignore`, use `git add -f <path>`.

This bites the placeholder commit if `.gitignore` is added in the same commit. Either commit the placeholder first and add `.gitignore` after, or use `git add -f` once.

---

## What this retrofit does NOT do

- **Does not change `MARKETING_VERSION` (`CFBundleShortVersionString`).** That stays under human control.
- **Does not redesign existing About UI.** It adds one line; it does not restructure.
- **Does not modify CI configuration.** If the project uses Xcode Cloud, GitHub Actions, or Fastlane, surface that and ask how to integrate. The scripts work as-is on CI runners (they have `git`, `xcrun`, `PlistBuddy`); the only consideration is that CI clones won't have `--skip-worktree` set, so a CI build's working tree shows the BuildInfo.swift modification — harmless on CI.
- **Does not remove or modify any pre-existing version-management build phase.** Surface conflicts during the Phase 0 survey.
- **Does not edit `.pbxproj` programmatically.** Run Script phases and Build Settings changes are deliberately left for the human in Xcode UI to avoid risk to project integrity.
