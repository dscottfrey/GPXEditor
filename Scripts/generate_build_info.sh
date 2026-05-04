#!/bin/bash
# Scripts/generate_build_info.sh
#
# Build-identifier retrofit, phase 1 of 2:  write
# GPXEditor/Generated/BuildInfo.swift with a build timestamp, the short git
# SHA of HEAD, a "tree was dirty" flag, and the active build configuration.
# The companion script (bump_built_info_plist.sh) handles the Release-only
# CFBundleVersion bump on the *built* Info.plist.
#
# Why this exists:  troubleshooting a bug report or a screenshot is much
# faster when each binary embeds an unambiguous identifier.  Manual build-
# number incrementing fails closed (humans forget exactly when it matters
# most), so the work is automated.  See the project's HANDOFF.md for the
# full rationale of the retrofit.
#
# Wiring:  invoked from a Run Script build phase on the GPXEditor target,
# positioned BEFORE "Compile Sources" so the regenerated file exists by
# the time the compiler reads it.  "Based on dependency analysis" must be
# unchecked so the script runs every build.  The Run Script's command is:
#
#     "${SRCROOT}/Scripts/generate_build_info.sh" \
#         "${SRCROOT}/GPXEditor/Generated/BuildInfo.swift"
#
# Idempotent and side-effect-free outside the BuildInfo.swift output file.
# Always runs (Debug and Release) — the timestamp/SHA/dirty values are
# useful regardless of configuration.

set -e

# --- Compute build identifier values ---

# Format YYMMDDhhmm — ten digits, compact for an About-panel display
# string while remaining strictly monotonically increasing minute-to-minute.
# Ten digits also fits cleanly inside CFBundleVersion's "string of period-
# separated integers" rule (Apple Bundle Programming Guide), which the
# Release-only script reuses.
TIMESTAMP=$(date +%y%m%d%H%M)

# Build phases run with a minimal PATH; locate git via xcrun (which Xcode
# always provides on its build agents) or fall back to a search.  The
# fallback matters when running from xcodebuild on a cleaned-up CI shell.
GIT=$(xcrun -find git 2>/dev/null || which git || echo "/usr/bin/git")

if [ -x "$GIT" ] && "$GIT" -C "$SRCROOT" rev-parse --git-dir > /dev/null 2>&1; then
    GIT_SHA=$("$GIT" -C "$SRCROOT" rev-parse --short HEAD 2>/dev/null || echo "nohead")
    # "Dirty" means there is anything either staged-but-not-committed or
    # modified-in-working-tree.  Untracked files do NOT count — they are
    # often legitimate scratch space (notes, debugging fixtures, etc.) and
    # don't tell us anything about whether the running binary diverges
    # from the committed source.
    if "$GIT" -C "$SRCROOT" diff --quiet 2>/dev/null && \
       "$GIT" -C "$SRCROOT" diff --cached --quiet 2>/dev/null; then
        IS_DIRTY="false"
    else
        IS_DIRTY="true"
    fi
else
    # No git — building from a tarball or a non-git checkout.  Use stable
    # placeholder values rather than failing the build; an unidentified
    # binary is bad but a non-buildable project is worse.
    GIT_SHA="nogit"
    IS_DIRTY="false"
fi

# --- Write BuildInfo.swift ---

# The output path is supplied as the first argument so the script doesn't
# have to know about target / source-folder layout — the Run Script in
# Xcode passes the target-specific path.  This keeps the script reusable
# if a second target ever needs its own BuildInfo (unlikely in v1, but
# zero-cost to support now).
BUILD_INFO_PATH="$1"
if [ -z "$BUILD_INFO_PATH" ]; then
    echo "error: generate_build_info.sh requires the BuildInfo.swift output path as its first argument"
    exit 1
fi

mkdir -p "$(dirname "$BUILD_INFO_PATH")"

# The generated file is intended to be tracked-once-then-skip-worktree
# rather than gitignored outright; see GPXEditor/Generated/BuildInfo.swift's
# header comment and the project's .gitignore for the rationale (Xcode's
# PBXFileSystemSynchronizedRootGroup needs the file to exist on a fresh
# clone so it gets included in the build graph from the first build).
cat > "$BUILD_INFO_PATH" <<EOF
// BuildInfo.swift
// AUTO-GENERATED at build time by Scripts/generate_build_info.sh.
// Do not edit by hand.  After cloning the repository, run once:
//   git update-index --skip-worktree GPXEditor/Generated/BuildInfo.swift
// to suppress local-modification noise from every build.

enum BuildInfo {
    static let timestamp: String = "$TIMESTAMP"
    static let gitSHA: String = "$GIT_SHA"
    static let isDirty: Bool = $IS_DIRTY
    static let configuration: String = "$CONFIGURATION"

    /// Display string suitable for an About screen, e.g. "2604051847 · a3f9c1e+".
    /// The trailing "+" appears when the working tree had uncommitted changes
    /// at build time — a quick visual cue that the binary doesn't correspond
    /// to a clean commit.
    static var displayString: String {
        let dirtyMarker = isDirty ? "+" : ""
        return "\(timestamp) · \(gitSHA)\(dirtyMarker)"
    }
}
EOF

echo "BuildInfo: $TIMESTAMP $GIT_SHA dirty=$IS_DIRTY config=$CONFIGURATION"
