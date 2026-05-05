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

    /// Pending Edit-Coordinates sheet request.  Non-nil while the sheet
    /// is presented.  ContentView observes this via `.sheet(item:)`
    /// — assigning a value shows the sheet, clearing it dismisses.
    /// Triggered by the right-click context-menu's "Edit Coordinates…"
    /// item;  on commit the sheet calls back into applyMovePoint.
    @Published var editCoordinatesRequest: EditCoordinatesRequest? = nil

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

    // MARK: - Simplify brush (with undo)

    /// Apply the Simplify brush to a single track using the supplied
    /// stroke samples (M4).  Captures prior session for undo;  the
    /// simplify operation can't add points (it only drops them) so the
    /// inverse is "restore the prior session" — same pattern Delete
    /// uses.
    ///
    /// One brush gesture may invoke this method multiple times (once
    /// per touched track).  Each invocation is its own undo unit at
    /// M4;  grouping multi-track-applies into one undo via
    /// NSUndoManager.beginUndoGrouping is iteration material if the
    /// multi-track-brush case becomes common.
    func applySimplifyBrush(trackId: UUID, stroke: [SimplifyBrush.StrokeSample]) {
        guard let documentBinding = documentBinding else {
            logger.warning("applySimplifyBrush called with no document binding")
            return
        }

        let priorSession = documentBinding.wrappedValue.session
        let priorSelection = selection

        let priorPointCount = priorSession.tracks
            .first(where: { $0.id == trackId })?.segments
            .reduce(0) { $0 + $1.points.count } ?? 0

        let result = SimplifyBrush.apply(to: priorSession, trackId: trackId, stroke: stroke)
        if result.touched.isEmpty {
            // Brush stroke didn't touch any segment — no-op, no undo entry.
            logger.info("applySimplifyBrush: no-op (no segments touched), prior point count=\(priorPointCount, privacy: .public)")
            return
        }
        let newPointCount = result.session.tracks
            .first(where: { $0.id == trackId })?.segments
            .reduce(0) { $0 + $1.points.count } ?? 0
        logger.info("applySimplifyBrush: touched=\(result.touched.count, privacy: .public) prior=\(priorPointCount, privacy: .public) new=\(newPointCount, privacy: .public)")

        documentBinding.wrappedValue.session = result.session
        // Selection might reference indices that no longer exist after
        // simplification.  Clear it to avoid stale highlights;  the
        // user can re-select if they wanted that section selected.
        selection.clear()

        registerUndoToRestore(session: priorSession, selection: priorSelection, actionName: "Simplify Brush")
    }

    // MARK: - Smooth brush (with undo)

    /// Apply the Smooth brush to a single track using the supplied
    /// stroke samples (M4).  Same shape as Simplify — snapshot,
    /// apply, register undo.  Smooth doesn't drop points, so undo is
    /// "restore prior session";  no ambiguity about what's reversed.
    func applySmoothBrush(trackId: UUID, stroke: [SmoothBrush.StrokeSample]) {
        guard let documentBinding = documentBinding else {
            logger.warning("applySmoothBrush called with no document binding")
            return
        }

        let priorSession = documentBinding.wrappedValue.session
        let priorSelection = selection

        let result = SmoothBrush.apply(to: priorSession, trackId: trackId, stroke: stroke)
        if result.touched.isEmpty {
            logger.info("applySmoothBrush: no-op (brushed segments already at kernel-average)")
            return
        }
        logger.info("applySmoothBrush: touched=\(result.touched.count, privacy: .public)")

        documentBinding.wrappedValue.session = result.session
        // Selection might reference points whose positions just shifted.
        // The indices are still valid (smoothing doesn't reindex) but
        // the visible markers would now point at slightly-different
        // locations than the user selected.  Acceptable;  unlike
        // Simplify (which can invalidate indices entirely), Smooth's
        // selection survives meaningfully.

        registerUndoToRestore(session: priorSession, selection: priorSelection, actionName: "Smooth Brush")
    }

    // MARK: - Move point (with undo) — M5 vertex draggability

    /// Apply a single-point move from a JS vertex-drag commit.
    /// Captures the prior session for undo;  same shape as the brush
    /// operations.  Selection is NOT cleared — moving a point doesn't
    /// invalidate selection indices, only positions, so a selected
    /// point that just moved stays selected at its new location.
    func applyMovePoint(
        trackId: UUID,
        segmentId: UUID,
        pointIndex: Int,
        latitude: Double,
        longitude: Double
    ) {
        guard let documentBinding = documentBinding else {
            logger.warning("applyMovePoint called with no document binding")
            return
        }

        let priorSession = documentBinding.wrappedValue.session
        let priorSelection = selection

        let result = MovePointOperation.apply(
            to: priorSession,
            trackId: trackId,
            segmentId: segmentId,
            pointIndex: pointIndex,
            latitude: latitude,
            longitude: longitude
        )
        if result.touched.isEmpty {
            // No-op:  stale identifiers or unchanged coordinates.
            return
        }
        documentBinding.wrappedValue.session = result.session
        registerUndoToRestore(session: priorSession, selection: priorSelection, actionName: "Move Point")
    }

    // MARK: - Add point on line (with undo) — M5 click-on-line insert

    /// Apply a click-on-line insertion from a JS polyline click.
    /// Inserts a new point immediately after `afterIndex`;  elevation
    /// and timestamp are linearly interpolated from the surrounding
    /// anchors when both have those values.
    ///
    /// Selection adjustment:  any reference whose `pointIndex >
    /// afterIndex` in the same (track, segment) needs to shift up by
    /// one because the insertion shifted those points' indices.  We do
    /// the simplest thing for v1 — clear the selection on insert.  Re-
    /// indexing live selections is an iteration item if a real workflow
    /// surfaces a need.
    func applyAddPointOnLine(
        trackId: UUID,
        segmentId: UUID,
        afterIndex: Int,
        latitude: Double,
        longitude: Double
    ) {
        guard let documentBinding = documentBinding else {
            logger.warning("applyAddPointOnLine called with no document binding")
            return
        }

        let priorSession = documentBinding.wrappedValue.session
        let priorSelection = selection

        let result = AddPointOnLineOperation.apply(
            to: priorSession,
            trackId: trackId,
            segmentId: segmentId,
            afterIndex: afterIndex,
            latitude: latitude,
            longitude: longitude
        )
        if result.touched.isEmpty {
            return
        }
        documentBinding.wrappedValue.session = result.session
        // Clear selection — any point indices > afterIndex would now
        // refer to wrong points.  See method doc for the iteration
        // path if this becomes problematic.
        selection.clear()
        registerUndoToRestore(session: priorSession, selection: priorSelection, actionName: "Add Point")
    }

    // MARK: - Delete single point (with undo) — M5 follow-up

    /// Delete a single track point identified by (track, segment,
    /// index).  Used by the right-click context-menu's "Delete this
    /// point" item;  doesn't read from `self.selection` so it works
    /// regardless of what's currently selected.  Removes the point
    /// from the canonical selection if it was there, so a subsequent
    /// highlight_selection broadcast doesn't reference a stale index.
    func deleteSinglePoint(trackId: UUID, segmentId: UUID, pointIndex: Int) {
        guard let documentBinding = documentBinding else {
            logger.warning("deleteSinglePoint called with no document binding")
            return
        }
        let priorSession = documentBinding.wrappedValue.session
        let priorSelection = selection

        let oneSelection = Selection(points: [
            Selection.PointReference(trackId: trackId, segmentId: segmentId, pointIndex: pointIndex)
        ])
        let result = DeleteOperation.apply(to: priorSession, deleting: oneSelection)
        if result.touched.isEmpty { return }

        documentBinding.wrappedValue.session = result.session
        selection.subtract([
            Selection.PointReference(trackId: trackId, segmentId: segmentId, pointIndex: pointIndex)
        ])
        registerUndoToRestore(session: priorSession, selection: priorSelection, actionName: "Delete Point")
    }

    // MARK: - Edit Coordinates (request the sheet) — M5 follow-up

    /// Open the Edit-Coordinates sheet for a specific point.  The
    /// caller (right-click menu handler) supplies the (track, segment,
    /// index);  we look up the current lat/lon to pre-fill the sheet
    /// and publish the request via `editCoordinatesRequest`.  The
    /// sheet's onCommit closure calls applyMovePoint with the new
    /// values.  Stale identifiers silently no-op — the menu item
    /// shouldn't have been offered for an unknown point but the
    /// guard prevents a crash if state has shifted between menu show
    /// and selection.
    func requestEditCoordinates(trackId: UUID, segmentId: UUID, pointIndex: Int) {
        guard let session = documentBinding?.wrappedValue.session else { return }
        guard let track = session.tracks.first(where: { $0.id == trackId }),
              let segment = track.segments.first(where: { $0.id == segmentId }),
              pointIndex >= 0, pointIndex < segment.points.count
        else { return }
        let p = segment.points[pointIndex]
        editCoordinatesRequest = EditCoordinatesRequest(
            trackId: trackId,
            segmentId: segmentId,
            pointIndex: pointIndex,
            initialLatitude: p.latitude,
            initialLongitude: p.longitude
        )
    }

    // MARK: - Promote to Waypoint (with undo) — M5 follow-up

    /// Convert a track point into a Waypoint at the same lat/lon.
    /// Snapshots prior session for undo.  Selection is cleared since
    /// the index shift caused by removing the track point can
    /// invalidate other selected indices.
    func applyPromoteToWaypoint(trackId: UUID, segmentId: UUID, pointIndex: Int) {
        guard let documentBinding = documentBinding else {
            logger.warning("applyPromoteToWaypoint called with no document binding")
            return
        }
        let priorSession = documentBinding.wrappedValue.session
        let priorSelection = selection

        let result = PromoteToWaypointOperation.apply(
            to: priorSession,
            trackId: trackId,
            segmentId: segmentId,
            pointIndex: pointIndex
        )
        if result.touched.isEmpty { return }

        documentBinding.wrappedValue.session = result.session
        selection.clear()
        registerUndoToRestore(session: priorSession, selection: priorSelection, actionName: "Promote to Waypoint")
    }

    // MARK: - Set Segment Boundary (with undo) — M5 follow-up

    /// Split a track segment at the named point.  The point becomes
    /// the first point of a new segment;  the original segment shrinks
    /// to [0..pointIndex - 1].  Selection is cleared because indices
    /// no longer mean what they did before the split.
    func applySetSegmentBoundary(trackId: UUID, segmentId: UUID, pointIndex: Int) {
        guard let documentBinding = documentBinding else {
            logger.warning("applySetSegmentBoundary called with no document binding")
            return
        }
        let priorSession = documentBinding.wrappedValue.session
        let priorSelection = selection

        let result = SetSegmentBoundaryOperation.apply(
            to: priorSession,
            trackId: trackId,
            segmentId: segmentId,
            pointIndex: pointIndex
        )
        if result.touched.isEmpty { return }

        documentBinding.wrappedValue.session = result.session
        selection.clear()
        registerUndoToRestore(session: priorSession, selection: priorSelection, actionName: "Set Segment Boundary")
    }

    // MARK: - Place Waypoint (with undo) — M5 follow-up

    /// Place a new Waypoint at a click location.  Returns whether a
    /// waypoint was actually placed — the operation is a no-op if the
    /// project has no tracks (no track to attach the waypoint to).
    /// The caller (right-click empty-space menu handler) can use this
    /// to decide whether to show feedback.
    @discardableResult
    func applyPlaceWaypoint(latitude: Double, longitude: Double) -> Bool {
        guard let documentBinding = documentBinding else {
            logger.warning("applyPlaceWaypoint called with no document binding")
            return false
        }
        let priorSession = documentBinding.wrappedValue.session
        let priorSelection = selection

        let result = PlaceWaypointOperation.apply(
            to: priorSession,
            latitude: latitude,
            longitude: longitude
        )
        guard result.hostTrackId != nil else {
            // No tracks in the project — nothing to attach to.
            return false
        }

        documentBinding.wrappedValue.session = result.session
        registerUndoToRestore(session: priorSession, selection: priorSelection, actionName: "Place Waypoint")
        return true
    }

    // MARK: - Select Entire Segment (no undo) — M5 follow-up

    /// Replace the selection with every point in the named segment.
    /// Used by the right-click "Select Entire Segment" context-menu
    /// item.  Different from `extendSelectionToWholeSegments` which
    /// expands the existing selection — this one starts fresh from a
    /// known target.
    func selectEntireSegment(trackId: UUID, segmentId: UUID) {
        guard let doc = documentBinding?.wrappedValue else { return }
        guard let track = doc.session.tracks.first(where: { $0.id == trackId }),
              let segment = track.segments.first(where: { $0.id == segmentId })
        else { return }

        var refs: Set<Selection.PointReference> = []
        for i in segment.points.indices {
            refs.insert(Selection.PointReference(
                trackId: trackId,
                segmentId: segmentId,
                pointIndex: i
            ))
        }
        selection = Selection(points: refs)
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

// MARK: - EditCoordinatesRequest
//
// Wrapper that drives ContentView's .sheet(item:) presentation for
// the Edit-Coordinates dialog.  Identifiable is required by SwiftUI's
// `.sheet(item:)`;  the id is fresh each time the sheet is opened
// (we don't try to reuse the same id across invocations because each
// open is conceptually a distinct request — the user closing and
// reopening should re-present the sheet from scratch).

struct EditCoordinatesRequest: Identifiable {
    let id = UUID()
    let trackId: UUID
    let segmentId: UUID
    let pointIndex: Int
    let initialLatitude: Double
    let initialLongitude: Double
}
