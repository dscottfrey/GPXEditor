// EditingTool.swift
//
// The active editing tool the user has selected.  D-014 specifies the full
// roster — Point, Hand, Lasso, Brush family (1-4), Waypoint Place — but
// this enum grows incrementally as each milestone lands the corresponding
// gesture handlers.  At M3 only `point` and `lasso` are wired;  later
// cases land at the milestones that need them.
//
// The active tool is window-scoped editing state held by SessionViewModel.
// Persisting it to the project file would mean reopening a saved project
// returned the user to the tool they were using when they saved, but
// that's surprising more often than helpful (the user opens a project
// fresh and expects the default Point Tool, not "whatever I happened to
// be using yesterday").  D-014's "Escape always returns to Point Tool"
// rule reinforces:  Point is the canonical resting state.
//
// Per CONVENTIONS.md "platform-agnostic data layer," this file is
// Foundation-only and never imports SwiftUI.

import Foundation

/// The currently-active editing tool.  At M4 the wired cases are
/// `point`, `lasso`, `brushSimplify`, and `brushSmooth`.  Future
/// milestones add the remaining brush variants and Waypoint Place.
public enum EditingTool: Equatable, Sendable {

    /// Point Tool, keyboard shortcut V.  Default tool.  Single-point
    /// operations including click-to-select and drag-in-empty-space
    /// for rectangular marquee selection (D-014).  Future milestones
    /// extend this with click-on-line-to-add and the right-click
    /// context menu.
    case point

    /// Lasso Tool, keyboard shortcut L.  Free-form polygon selection
    /// (D-014).  The user drags along a path to enclose points;  on
    /// release the points inside the closed polygon become the new
    /// selection (or are added/subtracted per the modifier).
    case lasso

    /// Simplify Brush, keyboard shortcut 1 (D-014 brush family).  Drag
    /// the cursor over a track section;  on release, redundant points
    /// (those whose perpendicular distance from the straight line
    /// connecting their neighbors is below tolerance) are removed via
    /// RDP (D-015, D-016).  Does NOT move points or smooth jitter —
    /// pair with Smooth Brush (`2`) for that.
    case brushSimplify

    /// Smooth Brush, keyboard shortcut 2 (D-014 brush family;  pulled
    /// forward from M9 to M4 because Scott's first-track verification
    /// surfaced that "remove jitter and make the points more in a line"
    /// is what users actually expect from a brush, and Simplify alone
    /// doesn't do that).  Drag the cursor over a noisy section;  on
    /// release, every point in the brush region is replaced by the
    /// uniform average of itself and its `k` nearest neighbors in
    /// index space.  Doesn't drop any points — pair with Simplify
    /// (`1`) afterwards if you want fewer points after the smoothing.
    case brushSmooth
}
