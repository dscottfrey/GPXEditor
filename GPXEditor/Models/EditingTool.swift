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

/// The currently-active editing tool.  At M3 the wired cases are
/// `point` (default;  marquee selection plus single-point operations)
/// and `lasso` (free-form polygon selection).  Future milestones add
/// brush variants and Waypoint Place.
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
}
