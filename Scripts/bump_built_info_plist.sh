#!/bin/bash
# Scripts/bump_built_info_plist.sh
#
# Build-identifier retrofit, phase 2 of 2:  on Release builds, set the
# *built* Info.plist's CFBundleVersion to a fresh timestamp.  The source-
# of-truth project settings (CURRENT_PROJECT_VERSION in project.pbxproj)
# are NOT modified, so this never pollutes git status.
#
# Why mutate the built artifact instead of source-edit the .pbxproj or an
# Info.plist file:  this project uses GENERATE_INFOPLIST_FILE = YES (no
# hand-maintained Info.plist exists) — see the M0 outcome notes in
# HANDOFF.md for why generated mode was chosen.  The directive's literal
# PlistBuddy-on-source-Info.plist branch therefore doesn't apply.
# Mutating the built artifact in $BUILT_PRODUCTS_DIR/$INFOPLIST_PATH gives
# us an App Store / TestFlight / Sparkle compatible CFBundleVersion in
# the shipped bundle without touching any committed file.
#
# Why we bother at all when D-004 ships via direct GitHub Releases (not
# the App Store):  monotonically increasing CFBundleVersion is also the
# way Sparkle (deferred per HANDOFF.md but on the table) tells one build
# from the next, and it's an unambiguous unique identifier per submission
# even when notarization re-uses MARKETING_VERSION.  Cheap to add now;
# expensive to retrofit later if Sparkle lands.
#
# Wiring:  invoked from a Run Script build phase on the GPXEditor target,
# positioned AFTER "Process Info.plist" (which generates the plist into
# the built bundle) and BEFORE "Code Sign" (so the modified plist is
# what ends up signed).  "Based on dependency analysis" must be unchecked.
# The Run Script's command is simply:
#
#     "${SRCROOT}/Scripts/bump_built_info_plist.sh"
#
# No-op on Debug builds — exits 0 immediately so day-to-day Debug rebuilds
# stay cheap and never log scary warnings.

set -e

if [ "$CONFIGURATION" != "Release" ]; then
    echo "bump_built_info_plist: skipping (CONFIGURATION=$CONFIGURATION)"
    exit 0
fi

# Match generate_build_info.sh's format so a Release build's BuildInfo
# timestamp and CFBundleVersion are the same minute.  Both scripts run
# in the same xcodebuild invocation; the only way they'd disagree is if
# the build straddles a minute boundary, which is acceptable noise.
TIMESTAMP=$(date +%y%m%d%H%M)

# $BUILT_PRODUCTS_DIR/$INFOPLIST_PATH is Xcode's well-defined location
# for the generated Info.plist inside the .app bundle being constructed.
# "Process Info.plist" writes it; we mutate it in place; "Code Sign"
# wraps the result.
BUILT_PLIST="$BUILT_PRODUCTS_DIR/$INFOPLIST_PATH"

if [ ! -f "$BUILT_PLIST" ]; then
    echo "error: bump_built_info_plist: built Info.plist not found at $BUILT_PLIST"
    echo "       Is this Run Script phase positioned AFTER 'Process Info.plist'?"
    exit 1
fi

# PlistBuddy is the canonical, signed-by-Apple plist editor in /usr/libexec.
# Set replaces an existing key value; CFBundleVersion is always present
# because GENERATE_INFOPLIST_FILE writes it from CURRENT_PROJECT_VERSION.
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $TIMESTAMP" "$BUILT_PLIST"
echo "bump_built_info_plist: CFBundleVersion = $TIMESTAMP (built bundle only; source unchanged)"
