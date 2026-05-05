// SessionViewModel.swift
//
// Per-window editing-state holder.  Owns:
//
//   - The active selection (window-scoped, not persisted with the
//     document — see Models/Selection.swift).
//   - The active editing tool (window-scoped — see Models/EditingTool.swift).
//   - The plumbing that bridges menu commands and direct manipulation
//     to the document mutation path:  a Binding to the FileDocument and
//     a weak reference to the window's UndoManager.
//
// Why a class (ObservableObject) for this layer:  reference semantics
// matter because (1) the menu bar (AppCommands.swift) and the MapView
// both need to address the same window-scoped state, and (2)
// NSUndoManager's `registerUndo(withTarget:handler:)` requires a class
// target — the registered closure captures `self` so that on undo the
// closure can mutate the captured target's properties to restore the
// prior state.
//
// Lifetime:  one SessionViewModel per document window, created in
// ContentView via @StateObject.  ContentView is also responsible for
// setting `documentBinding` and `undoManager` on this view model
// before any operation runs (`.onAppear` and `.onChange(of: undoManager)`).
// If those references are nil at the time a method is invoked, the
// method is a no-op and a warning is logged — that should never happen
// in normal operation but defensive guards prevent a hard crash if a
// menu command races with a window teardown.
//
// Undo pattern:  every mutating method snapshots the prior state and
// registers a closure with the undo manager that restores it.  The
// restore method itself registers an undo (which becomes the redo of
// the original action), and so on.  This is the standard recursive
// Cocoa pattern;  see "Apply a delete" below for the canonical shape.
//
// Per CONVENTIONS.md, ViewModels/ may import SwiftUI freely.

import SwiftUI
import Combine
import os

@MainActor
final class SessionViewModel: ObservableObject {

    // MARK: - Published state

    /// The window's current point-level selection.  Drives the
    /// `highlight_selection` bridge message and feeds operations like
    /// Delete that take "the current selection" as their input scope.
    @Published var selection: Selection = Selection()

    /// The active editing tool.  V switches to Point, L switches to
    /// Lasso, Escape returns to Point.  Brush and Waypoint cases come
    /// online at later milestones.
    @Published var activeTool: EditingTool = .point

    // MARK: - Bridges to the SwiftUI environment

    /// Weak reference to the window's UndoManager.  ContentView
    /// observes the SwiftUI environment and assigns this on appear and
    /// on change.  Held weakly so the SessionViewModel doesn't form a
    /// retain cycle with the manager (the manager retains registered
    /// closures, which capture `self` strongly — that's the correct
    /// direction for the cycle, and weak here breaks it).
    weak var undoManager: UndoManager?

    /// Binding to the FileDocument, supplied once by ContentView.  All
    /// document mutations route through this binding so SwiftUI's
    /// FileDocument autosave / dirty-tracking machinery notices.
    var documentBinding: Binding<GPXEditorDocument>?

    // MARK: - Logging

    private let logger = Logger(subsystem: "com.gpxeditor.app.SessionViewModel", category: "session")

    init() {}

    // MARK: - Selection control

    /// Clear the selection.  ⇧⌘A "Deselect All" lands here.  The
    /// previous selection isn't undoable — selection is purely
    /// transient view state, and an undo stack full of "(de)select"
    /// actions would push real edits off the bottom for no benefit.
    func clearSelection() {
        selection.clear()
    }

    /// Select every point in every track.  ⌘A "Select All" lands here.
    /// Builds a Selection covering every (track, segment, index)
    /// triple in the current document.  Like clearSelection above,
    /// not undoable — selection changes don't push to the undo stack.
    func selectAll() {
        guard let doc = documentBinding?.wrappedValue else {
            logger.warning("selectAll called with no document binding")
            return
        }
        var refs: Set<Selection.PointReference> = []
        for track in doc.session.tracks {
            for segment in track.segments {
                for i in segment.points.indices {
                    refs.insert(Selection.PointReference(
                        trackId: track.id,
                        segmentId: segment.id,
                        pointIndex: i
                    ))
                }
            }
        }
        selection = Selection(points: refs)
    }

    /// Select every point in the segment(s) currently touched by the
    /// selection.  ⌘E "Select Entire Segment" lands here:  if the user
    /// has any point in segment X selected, all of segment X's points
    /// become selected.  No-op if the selection is empty.
    func extendSelectionToWholeSegments() {
        guard let doc = documentBinding?.wrappedValue else {
            logger.warning("extendSelectionToWholeSegments called with no document binding")
            return
        }
        if selection.isEmpty { return }
        // Collect the (trackId, segmentId) pairs the current selection
        // touches, then expand each to every point in that segment.
        var segmentKeys: Set<SegmentKey> = []
        for ref in selection.points {
            segmentKeys.insert(SegmentKey(trackId: ref.trackId, segmentId: ref.segmentId))
        }
        var refs: Set<Selection.PointReference> = []
        for track in doc.session.tracks {
            for segment in track.segments {
                let key = SegmentKey(trackId: track.id, segmentId: segment.id)
                if segmentKeys.contains(key) {
                    for i in segment.points.indices {
                        refs.insert(Selection.PointReference(
                            trackId: track.id,
                            segmentId: segment.id,
                            pointIndex: i
                        ))
                    }
                }
            }
        }
        selection = Selection(points: refs)
    }

    // MARK: - Tool control

    /// Switch to the named tool.  The tool's keyboard shortcut handler
    /// in AppCommands routes here.
    func setTool(_ tool: EditingTool) {
        activeTool = tool
    }

    /// Return to the default Point Tool.  Escape lands here per D-014.
    func returnToPointTool() {
        activeTool = .point
    }

    // MARK: - Delete operation (with undo)

    /// Delete every selected point.  Captures the prior session and
    /// selection so undo restores both.  No-op if nothing is selected
    /// (the menu item is disabled in that case but defensive guard
    /// prevents stray keypaths from hitting it).
    func deleteSelected() {
        guard let documentBinding = documentBinding else {
            logger.warning("deleteSelected called with no document binding")
            return
        }
        if selection.isEmpty { return }

        let priorSession = documentBinding.wrappedValue.session
        let priorSelection = selection

        let result = DeleteOperation.apply(to: priorSession, deleting: priorSelection)
        documentBinding.wrappedValue.session = result.session
        selection.clear()

        // Register undo:  restore prior session + prior selection.
        // `restoreState` itself re-registers an undo that snapshots
        // the current state, which becomes the redo path.
        registerUndoToRestore(session: priorSession, selection: priorSelection, actionName: "Delete Points")
    }

    // MARK: - Undo plumbing

    /// Register an undo that restores the supplied (session, selection)
    /// pair.  The restore closure runs on the SessionViewModel because
    /// NSUndoManager requires a class target, and on invocation it
    /// itself registers the inverse — that's how Cocoa's undo turns
    /// into redo when the user picks Edit → Redo.
    private func registerUndoToRestore(session: GPXSession, selection: Selection, actionName: String) {
        guard let undoManager = undoManager else { return }
        undoManager.registerUndo(withTarget: self) { vm in
            vm.restoreState(session: session, selection: selection, actionName: actionName)
        }
        undoManager.setActionName(actionName)
    }

    /// Restore a snapshot of (session, selection).  Registers its own
    /// inverse so the next Undo / Redo continues to flip back and
    /// forth correctly.  Private — only the undo machinery should
    /// call this.
    private func restoreState(session: GPXSession, selection: Selection, actionName: String) {
        guard let documentBinding = documentBinding else { return }
        let snapshotSession = documentBinding.wrappedValue.session
        let snapshotSelection = self.selection

        documentBinding.wrappedValue.session = session
        self.selection = selection

        registerUndoToRestore(
            session: snapshotSession,
            selection: snapshotSelection,
            actionName: actionName
        )
    }

    // MARK: - Helpers

    /// Internal grouping key used by Selection-extension operations.
    private struct SegmentKey: Hashable {
        let trackId: UUID
        let segmentId: UUID
    }
}

// MARK: - FocusedValues plumbing
//
// Parallel to the document binding plumbing in AppCommands.swift,
// SessionViewModel is published into FocusedValues so menu commands
// (Edit > Delete, ⌘A, ⇧⌘A, ⌘E, ⌘2) can find the active window's
// view model when triggered from the menu bar.  ContentView publishes
// the value on the focused scene;  AppCommands consumes via
// @FocusedObject (or @FocusedValue for the optional case).

private struct SessionViewModelFocusedValueKey: FocusedValueKey {
    typealias Value = SessionViewModel
}

extension FocusedValues {
    /// The currently-focused window's SessionViewModel, or nil when no
    /// document window is frontmost.
    var sessionViewModel: SessionViewModel? {
        get { self[SessionViewModelFocusedValueKey.self] }
        set { self[SessionViewModelFocusedValueKey.self] = newValue }
    }
}
