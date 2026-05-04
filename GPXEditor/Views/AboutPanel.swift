// AboutPanel.swift
//
// AppKit helper that surfaces NSApp.orderFrontStandardAboutPanel(_:) with
// the project's build identifier injected into the Credits area.  Called
// from the .commands modifier in GPXEditorApp.swift, which replaces the
// SwiftUI-default "About GPXeditor" menu item with one that routes through
// here.
//
// Why a custom helper instead of letting SwiftUI's default About panel
// handle it:  the default panel reads from Info.plist only — app name,
// marketing version, copyright — and has no entry point for an extra
// "Build" line.  AppKit's NSApp.orderFrontStandardAboutPanel(options:)
// accepts a `.credits` NSAttributedString that we use for the build
// identifier; this gives us the build line without throwing away any of
// the standard panel's other affordances (icon, name, version, copyright).
//
// AppKit is imported here because the standard About panel is an AppKit
// affordance (NSApp).  The wider data layer in Models/ stays platform-
// agnostic per CONVENTIONS.md; AppKit here is appropriate because this
// file lives in Views/ and the file is a UI entry point.

import AppKit

/// Shows the standard macOS About panel with the GPXeditor build
/// identifier embedded in the Credits area.  Wired to the Application
/// menu's "About GPXeditor" item via the .commands modifier on
/// GPXEditorApp.swift's scene.
@MainActor
enum AboutPanel {

    /// Opens the standard About panel.  Idempotent — calling it twice
    /// while the panel is already open just brings it forward.
    static func show() {
        // The Credits area is the lower-left section of the standard
        // About panel.  It accepts an NSAttributedString so we can match
        // the panel's surrounding typography (system font at small size,
        // secondary label color).
        let credits = NSAttributedString(
            string: "Build \(BuildInfo.displayString)",
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
}
