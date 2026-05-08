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
import AppKit
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

    /// Pending Merge-Track-Picker sheet request.  Non-nil while the
    /// sheet is presented.  Triggered by the "Merge Track Into…" menu
    /// item;  the destination is established by the selection.  The
    /// sheet lists candidate sources;  the user's pick + confirmation
    /// route back through applyMergeTracks.
    @Published var mergeTracksRequest: MergeTracksRequest? = nil

    /// Pending Trim-Track sheet request.  Non-nil while the sheet is
    /// presented;  the dialog reads its initial state from this and
    /// the user's adjustments drive `trimPreviewGroups` for the live
    /// preview.
    @Published var trimTrackRequest: TrimTrackRequest? = nil

    /// Live preview groups for the Trim Track dialog.  Nil means "no
    /// active preview" (MapView sends clear_trim_preview);  non-nil
    /// means "render the named groups" (MapView sends preview_trim).
    /// MapView observes this via SwiftUI's update cycle and diff-
    /// sends only when the value changes.
    @Published var trimPreviewGroups: [TrimTrackOperation.PreviewGroup]? = nil

    /// Pending Pin-to-Ground sheet request (M7).  Non-nil while the
    /// confirm-and-progress sheet is presented;  the sheet drives an
    /// async ElevationService loop and calls back into
    /// applyPinToGround on success.  Triggered by the Edit menu's
    /// "Pin to Ground…" item;  the scope (selection or whole-master)
    /// is decided by requestPinToGround per the selection-aware-
    /// operations rule in CONVENTIONS.md.
    @Published var pinToGroundRequest: PinToGroundRequest? = nil

    /// The track currently selected in the M7.5 sidebar, if any.
    /// Distinct from `selection` (which is per-point) — this is the
    /// "user clicked on a track row in the sidebar" affordance,
    /// used by the Inspector to show track-level info when no
    /// individual points are selected.  Nil means no sidebar
    /// selection (Inspector falls back to project-metadata mode or
    /// the points-selection-driven mode).
    @Published var selectedSidebarTrackId: UUID? = nil

    /// One-shot trigger for the `zoom_to_bounds` bridge message
    /// (M7.5).  Each invocation of `zoomToTrack(trackId:)` (and
    /// future ⌘2 "Zoom to Selection") sets a new value with a
    /// fresh UUID id.  MapView's coordinator observes via
    /// SwiftUI's update cycle and dispatches the bridge message
    /// when it sees a previously-unseen id.  The fresh-UUID-per-call
    /// pattern means two consecutive zooms to the SAME bounds still
    /// trigger a re-fit (Equatable comparison on the wrapper finds
    /// them different because the ids differ).
    @Published var zoomBoundsTrigger: ZoomBoundsTrigger? = nil

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

    // MARK: - Trim Track (with undo) — M6

    /// Open the Trim Track dialog for the named track.  If the track
    /// has no timestamped points, surface an alert and don't open the
    /// sheet — there's nothing for the dialog's date pickers to act
    /// on.  The menu item gates on the same condition but the
    /// duplicate guard keeps the operation honest if the menu state
    /// is stale.
    func requestTrimTrack(trackId: UUID) {
        guard let session = documentBinding?.wrappedValue.session else { return }
        guard let track = session.tracks.first(where: { $0.id == trackId }) else { return }
        guard let range = TrimTrackOperation.timestampRange(of: trackId, in: session) else {
            // No timestamped points — the operation is meaningless.
            // Surface via NSAlert per CONVENTIONS.md "describe, don't
            // accuse":  state the operation, expectation, and
            // observation without verdict-loading the user's data.
            let alert = NSAlert()
            alert.messageText = "Trim Track is unavailable for this track."
            alert.informativeText = "Trim Track filters by per-point timestamps;  this track has no points with recorded times."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        trimTrackRequest = TrimTrackRequest(
            trackId: trackId,
            trackName: track.name,
            timestampRange: range
        )
    }

    /// Recompute the live preview for the dialog's current bounds and
    /// publish via `trimPreviewGroups`.  MapView observes the
    /// published change and sends preview_trim through the bridge.
    /// Both bounds nil clears the preview;  we set [] (empty array)
    /// in that case rather than nil so the dialog being open with
    /// nothing-to-trim is distinguishable from the dialog being
    /// closed.
    func updateTrimPreview(trackId: UUID, startBefore: Date?, endAfter: Date?) {
        guard let session = documentBinding?.wrappedValue.session else { return }
        let groups = TrimTrackOperation.pointsToRemove(
            in: session,
            trackId: trackId,
            trimStartBefore: startBefore,
            trimEndAfter: endAfter
        )
        trimPreviewGroups = groups
    }

    /// Clear the trim preview.  Called from the sheet's onDisappear so
    /// MapView re-syncs to "no active preview" via clear_trim_preview.
    func clearTrimPreview() {
        trimPreviewGroups = nil
    }

    /// Apply the trim with snapshot/undo.  Called from the dialog's
    /// OK button after the preview was already showing what would be
    /// dropped.  Selection cleared because indices may have shifted.
    func applyTrimTrack(trackId: UUID, startBefore: Date?, endAfter: Date?) {
        guard let documentBinding = documentBinding else {
            logger.warning("applyTrimTrack called with no document binding")
            return
        }
        let priorSession = documentBinding.wrappedValue.session
        let priorSelection = selection

        let result = TrimTrackOperation.apply(
            to: priorSession,
            trackId: trackId,
            trimStartBefore: startBefore,
            trimEndAfter: endAfter
        )
        if result.touched.isEmpty { return }

        documentBinding.wrappedValue.session = result.session
        selection.clear()
        registerUndoToRestore(session: priorSession, selection: priorSelection, actionName: "Trim Track")
    }

    // MARK: - Merge Tracks (with undo) — M6

    /// Open the Merge-Track-Picker sheet for the named destination.
    /// The picker presents every other track as a candidate source;
    /// the user selects one and confirms;  on commit the sheet calls
    /// back into applyMergeTracks.  Stale destination ids silently
    /// no-op — the menu item shouldn't have been offered for an
    /// unknown track but the guard prevents a crash.
    func requestMergeTracks(destinationId: UUID) {
        guard let session = documentBinding?.wrappedValue.session else { return }
        guard let destination = session.tracks.first(where: { $0.id == destinationId }) else { return }
        // Candidate sources:  every track except the destination.
        // Stripping the destination here (rather than in the sheet)
        // means the sheet's empty-state can be precise:  "no other
        // tracks to merge" rather than "no tracks except the one you
        // can't pick anyway."
        let candidates = session.tracks.filter { $0.id != destinationId }
        if candidates.isEmpty {
            // Nothing to merge — defensive log;  the menu's enabled
            // gate already requires tracks.count >= 2 so this should
            // never fire in normal operation.
            logger.info("requestMergeTracks: no candidate sources")
            return
        }
        mergeTracksRequest = MergeTracksRequest(
            destinationId: destinationId,
            destinationName: destination.name,
            candidates: candidates.map { MergeTracksRequest.Candidate(id: $0.id, name: $0.name) }
        )
    }

    /// Apply the merge.  Source segments and waypoints append to the
    /// destination;  source track is removed.  Selection is cleared
    /// because indices on the source track no longer have a host
    /// track at all, and indices on the destination's pre-merge
    /// segments are still valid but the user's selection mental
    /// model resets after a structural edit of this size.
    func applyMergeTracks(sourceId: UUID, destinationId: UUID) {
        guard let documentBinding = documentBinding else {
            logger.warning("applyMergeTracks called with no document binding")
            return
        }
        let priorSession = documentBinding.wrappedValue.session
        let priorSelection = selection

        let result = MergeTracksOperation.apply(
            to: priorSession,
            sourceTrackId: sourceId,
            destinationTrackId: destinationId
        )
        if result.touched.isEmpty { return }

        documentBinding.wrappedValue.session = result.session
        selection.clear()
        registerUndoToRestore(session: priorSession, selection: priorSelection, actionName: "Merge Tracks")
    }

    // MARK: - Split Track (with undo) — M6

    /// Split a track into two at the named point.  The original track
    /// keeps everything up to (but not including) the point;  a new
    /// track is created holding the named point onward.  Selection is
    /// cleared because indices on the original track may have shifted
    /// (the post-split portion no longer belongs to that track).
    func applySplitTrack(trackId: UUID, segmentId: UUID, pointIndex: Int) {
        guard let documentBinding = documentBinding else {
            logger.warning("applySplitTrack called with no document binding")
            return
        }
        let priorSession = documentBinding.wrappedValue.session
        let priorSelection = selection

        let result = SplitTrackOperation.apply(
            to: priorSession,
            trackId: trackId,
            segmentId: segmentId,
            pointIndex: pointIndex
        )
        if result.touched.isEmpty { return }

        documentBinding.wrappedValue.session = result.session
        selection.clear()
        registerUndoToRestore(session: priorSession, selection: priorSelection, actionName: "Split Track")
    }

    // MARK: - Reverse Track (with undo) — M6

    /// Reverse a track's direction.  Flips segment order and the
    /// per-segment point order;  per-point metadata (elevation,
    /// timestamp) stays attached to each point.  Selection is cleared
    /// because every point's index has shifted — preserving selection
    /// across a reverse would require translating each (segment,
    /// index) reference into a (segment_count - 1 - segment_index,
    /// point_count - 1 - point_index) form, and a no-selection result
    /// after a reverse is the simpler and less error-prone behaviour.
    /// The user can re-select after reversing if they need to.
    func applyReverseTrack(trackId: UUID) {
        guard let documentBinding = documentBinding else {
            logger.warning("applyReverseTrack called with no document binding")
            return
        }
        let priorSession = documentBinding.wrappedValue.session
        let priorSelection = selection

        let result = ReverseTrackOperation.apply(to: priorSession, trackId: trackId)
        if result.touched.isEmpty { return }

        documentBinding.wrappedValue.session = result.session
        selection.clear()
        registerUndoToRestore(session: priorSession, selection: priorSelection, actionName: "Reverse Track")
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

    // MARK: - Pin to Ground / Snap to Ground / Properties of This Location (M7)

    /// Open the Pin to Ground sheet.  Resolves the scope per the
    /// selection-aware-operations rule (CONVENTIONS.md):  if a
    /// selection exists, the operation runs against it;  otherwise it
    /// runs against the master track if one is tagged.  At M7 the
    /// master tagging UI doesn't exist yet (lands at M9), so the
    /// no-selection-no-master branch surfaces a clear NSAlert
    /// nudging the user toward selection-based use until M9.
    func requestPinToGround() {
        guard let documentBinding = documentBinding else {
            logger.warning("requestPinToGround called with no document binding")
            return
        }
        let session = documentBinding.wrappedValue.session

        // Resolve refs + scope description.
        let refs: [Selection.PointReference]
        let scope: PinToGroundRequest.Scope

        if !selection.isEmpty {
            refs = Array(selection.points)
            scope = .selection(pointCount: refs.count)
        } else if let master = session.tracks.first(where: { $0.role == .master }) {
            refs = Self.allPointReferences(of: master)
            scope = .wholeTrack(trackName: master.name, pointCount: refs.count)
        } else {
            // Neither selection nor master available.  At M7 this is
            // the typical state — master tagging is M9 work.  The
            // alert points at the workable path (select first).
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "Pin to Ground needs a selection or a master track."
            alert.informativeText = "Select the points to pin (⌘A selects every point), then choose Pin to Ground.  Whole-track pinning will be available once master-track tagging lands."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        // Snapshot current lat/lon for each ref — the sheet sends
        // these to OpenTopoData.  Drop any ref whose (track,
        // segment, index) is somehow stale (shouldn't happen for a
        // selection just resolved from current state, but defensive).
        var queries: [PinToGroundRequest.PointQuery] = []
        for ref in refs {
            if let track = session.tracks.first(where: { $0.id == ref.trackId }),
               let segment = track.segments.first(where: { $0.id == ref.segmentId }),
               ref.pointIndex >= 0, ref.pointIndex < segment.points.count {
                let point = segment.points[ref.pointIndex]
                queries.append(.init(
                    reference: ref,
                    latitude: point.latitude,
                    longitude: point.longitude
                ))
            }
        }
        guard !queries.isEmpty else {
            logger.warning("requestPinToGround: scope resolved to zero queries")
            return
        }

        pinToGroundRequest = PinToGroundRequest(scope: scope, queries: queries)
    }

    /// Synchronous commit of a Pin-to-Ground (or Snap-to-Ground)
    /// operation.  Snapshots prior state, applies the pure operation,
    /// registers an undo entry with the supplied action name.  No-op
    /// if the operation didn't actually change anything (touched
    /// list empty) — avoids spurious undo entries when the queried
    /// elevations matched what was already there.
    func applyPinToGround(
        refs: [Selection.PointReference],
        newElevations: [Double?],
        actionName: String = "Pin to Ground"
    ) {
        guard let documentBinding = documentBinding else {
            logger.warning("applyPinToGround called with no document binding")
            return
        }
        let priorSession = documentBinding.wrappedValue.session
        let priorSelection = selection

        let result = PinToGroundOperation.apply(
            to: priorSession,
            references: refs,
            newElevations: newElevations
        )
        if result.touched.isEmpty {
            // Nothing actually changed — don't dirty the document or
            // push an undo entry.  Sheet dismissal is feedback enough.
            logger.info("applyPinToGround: no-op (touched list empty)")
            return
        }

        documentBinding.wrappedValue.session = result.session
        registerUndoToRestore(
            session: priorSession,
            selection: priorSelection,
            actionName: actionName
        )
    }

    /// Single-point Snap to Ground from the right-click context menu.
    /// Async because it touches the network.  On success applies via
    /// applyPinToGround;  on error surfaces an NSAlert.  No sheet —
    /// one-point lookups are fast enough that a progress UI is
    /// overkill.
    func applySnapToGround(trackId: UUID, segmentId: UUID, pointIndex: Int) {
        guard let documentBinding = documentBinding else {
            logger.warning("applySnapToGround called with no document binding")
            return
        }
        let session = documentBinding.wrappedValue.session
        guard let track = session.tracks.first(where: { $0.id == trackId }),
              let segment = track.segments.first(where: { $0.id == segmentId }),
              pointIndex >= 0, pointIndex < segment.points.count
        else {
            logger.warning("applySnapToGround: stale (track, segment, index)")
            return
        }
        let lat = segment.points[pointIndex].latitude
        let lon = segment.points[pointIndex].longitude
        let ref = Selection.PointReference(
            trackId: trackId, segmentId: segmentId, pointIndex: pointIndex
        )

        Task { [weak self] in
            do {
                let service = ElevationService()
                let result = try await service.fetchElevations(for: [
                    ElevationQuery(latitude: lat, longitude: lon)
                ])
                let newEle = result.first ?? nil
                await MainActor.run {
                    guard let self = self else { return }
                    if let newEle = newEle {
                        self.applyPinToGround(
                            refs: [ref],
                            newElevations: [newEle],
                            actionName: "Snap to Ground"
                        )
                    } else {
                        self.surfaceNoElevationDataAlert()
                    }
                }
            } catch {
                await MainActor.run {
                    self?.surfaceElevationErrorAlert(error, contextDescription: "Snap to Ground")
                }
            }
        }
    }

    /// "Properties of This Location" right-click empty-space action.
    /// Looks up DEM elevation for the named point and presents an
    /// informational NSAlert with lat / lon / elevation.  Async
    /// because it touches the network.
    func showPropertiesOfLocation(latitude: Double, longitude: Double) {
        Task { [weak self] in
            do {
                let service = ElevationService()
                let result = try await service.fetchElevations(for: [
                    ElevationQuery(latitude: latitude, longitude: longitude)
                ])
                let elevation = result.first ?? nil
                await MainActor.run {
                    self?.surfaceLocationProperties(
                        latitude: latitude,
                        longitude: longitude,
                        elevation: elevation
                    )
                }
            } catch {
                await MainActor.run {
                    self?.surfaceElevationErrorAlert(error, contextDescription: "Properties of This Location")
                }
            }
        }
    }

    /// Walk every (track, segment, index) inside the supplied track
    /// and return a list of references.  Used by Pin to Ground's
    /// whole-master scope to enumerate every point.  Static because
    /// it doesn't depend on view-model state — it's a pure function
    /// of the track.
    private static func allPointReferences(of track: Track) -> [Selection.PointReference] {
        var refs: [Selection.PointReference] = []
        for segment in track.segments {
            for i in segment.points.indices {
                refs.append(Selection.PointReference(
                    trackId: track.id,
                    segmentId: segment.id,
                    pointIndex: i
                ))
            }
        }
        return refs
    }

    /// Surface an elevation-service error via NSAlert.  Per
    /// CONVENTIONS.md "describe, don't accuse" the message describes
    /// what was attempted and what was observed — the user's network
    /// or input isn't pronounced "broken."
    private func surfaceElevationErrorAlert(_ error: Error, contextDescription: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\(contextDescription) could not complete."
        // ElevationServiceError's localizedDescription already follows
        // the describe-don't-accuse pattern;  other errors fall through
        // to their default description.
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Surface a "the lookup succeeded but the DEM has no value here"
    /// alert.  Distinguished from the error path because this is not
    /// an error — the service did its job, the underlying DEM just
    /// has no data at the requested location.
    private func surfaceNoElevationDataAlert() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "No elevation data at that location."
        alert.informativeText = "OpenTopoData's mapzen dataset returned no elevation for the requested point.  This is unusual on land but can occur at far-offshore locations or in regions outside the underlying DEM's coverage."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Present the "Properties of This Location" informational alert
    /// — lat / lon / elevation in a compact format.  Elevation is
    /// shown as "—" when the DEM has no data at that location, which
    /// is more honest than 0 or "N/A."
    private func surfaceLocationProperties(latitude: Double, longitude: Double, elevation: Double?) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Properties of This Location"
        let latString = String(format: "%.6f", latitude)
        let lonString = String(format: "%.6f", longitude)
        let eleString: String
        if let elevation = elevation {
            eleString = String(format: "%.1f m", elevation)
        } else {
            eleString = "—  (no DEM data at this location)"
        }
        alert.informativeText = """
        Latitude: \(latString)
        Longitude: \(lonString)
        Elevation: \(eleString)

        Elevation values come from OpenTopoData's mapzen dataset (a global SRTM / ASTER / NED / EU-DEM blend).
        """
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Sidebar-driven track operations (M7.5)

    /// Replace the selection with every point in the named track.
    /// Used by the sidebar's right-click "Select All Points" item
    /// and its companion in the Track menu.  Selection is window-
    /// scoped transient state, not undoable (matches selectAll's
    /// existing posture).  No-op if the trackId doesn't resolve.
    func selectEntireTrack(trackId: UUID) {
        guard let doc = documentBinding?.wrappedValue else {
            logger.warning("selectEntireTrack called with no document binding")
            return
        }
        guard let track = doc.session.tracks.first(where: { $0.id == trackId }) else {
            return
        }
        var refs: Set<Selection.PointReference> = []
        for segment in track.segments {
            for i in segment.points.indices {
                refs.insert(Selection.PointReference(
                    trackId: track.id,
                    segmentId: segment.id,
                    pointIndex: i
                ))
            }
        }
        selection = Selection(points: refs)
    }

    /// Delete a track from the session entirely.  Captures prior
    /// session and selection so undo restores both;  also clears
    /// the sidebar selection if it pointed at the deleted track
    /// (matching the "stale references shouldn't hang around" rule
    /// the rest of the editing operations follow).  No-op if the
    /// trackId doesn't resolve.
    func deleteTrack(trackId: UUID) {
        guard let documentBinding = documentBinding else {
            logger.warning("deleteTrack called with no document binding")
            return
        }
        let priorSession = documentBinding.wrappedValue.session
        let priorSelection = selection
        let priorSidebarSelection = selectedSidebarTrackId

        guard let trackIndex = priorSession.tracks.firstIndex(where: { $0.id == trackId }) else {
            return
        }
        var newSession = priorSession
        newSession.tracks.remove(at: trackIndex)
        documentBinding.wrappedValue.session = newSession

        // Clear point selection if it touched the deleted track —
        // PointReferences pointing at a no-longer-existing track
        // would just be stale and operations would silently skip
        // them, but cleaner to drop them from the canonical state.
        let prunedRefs = selection.points.filter { $0.trackId != trackId }
        if prunedRefs.count != selection.points.count {
            selection = Selection(points: prunedRefs)
        }

        // Clear sidebar selection if it pointed at the deleted track.
        if selectedSidebarTrackId == trackId {
            selectedSidebarTrackId = nil
        }

        // Register undo restoring the prior session AND the prior
        // selection (point + sidebar).  registerUndoToRestore handles
        // session + point-selection;  the sidebar bit we set
        // explicitly here so the inverse closure restores it too.
        let priorSidebarCapture = priorSidebarSelection
        registerUndoToRestore(session: priorSession, selection: priorSelection, actionName: "Delete Track")
        if let undoManager = undoManager {
            undoManager.registerUndo(withTarget: self) { vm in
                vm.selectedSidebarTrackId = priorSidebarCapture
            }
        }
    }

    /// Zoom the map view to fit the named track's bounds.  Computes
    /// the lat/lon envelope from the track's points and dispatches
    /// a `zoom_to_bounds` bridge message via the published trigger
    /// that MapView's coordinator observes.  No-op if the trackId
    /// doesn't resolve, the track has no segments, or every segment
    /// is empty (no points → no bounds).
    func zoomToTrack(trackId: UUID) {
        guard let doc = documentBinding?.wrappedValue else {
            logger.warning("zoomToTrack called with no document binding")
            return
        }
        guard let track = doc.session.tracks.first(where: { $0.id == trackId }) else {
            return
        }
        guard let bounds = Self.boundingBox(of: track) else {
            // Empty track or all-empty segments — nothing to zoom to.
            logger.info("zoomToTrack: track \(trackId.uuidString, privacy: .public) has no points to bound")
            return
        }
        zoomBoundsTrigger = ZoomBoundsTrigger(id: UUID(), bounds: bounds)
    }

    /// Compute the lat/lon bounding box of every point in every
    /// segment of the track.  Returns nil if there are no points.
    /// Static — pure function of the track.
    private static func boundingBox(of track: Track) -> GeographicBounds? {
        var north: Double = -.greatestFiniteMagnitude
        var south: Double = .greatestFiniteMagnitude
        var east: Double = -.greatestFiniteMagnitude
        var west: Double = .greatestFiniteMagnitude
        var sawAny = false
        for segment in track.segments {
            for point in segment.points {
                sawAny = true
                if point.latitude > north { north = point.latitude }
                if point.latitude < south { south = point.latitude }
                if point.longitude > east { east = point.longitude }
                if point.longitude < west { west = point.longitude }
            }
        }
        guard sawAny else { return nil }
        return GeographicBounds(north: north, south: south, east: east, west: west)
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

// MARK: - Scene-level publication
//
// SessionViewModel is published at scene level via
// `.focusedSceneObject(sessionVM)` in ContentView so menu commands
// in AppCommands.swift can find the active window's view model when
// triggered from the menu bar.  AppCommands reads it via
// `@FocusedObject private var sessionVM: SessionViewModel?`.
//
// We use the `@FocusedObject` / `.focusedSceneObject` pair (rather
// than the older `@FocusedValue` / `.focusedSceneValue` + custom
// FocusedValueKey extension) because @FocusedObject SUBSCRIBES to
// the ObservableObject's @Published changes, which is what makes
// menu commands re-evaluate their `.disabled(...)` clauses when the
// view model's selection / activeTool / etc. changes.  @FocusedValue
// gives you the object but doesn't observe — getting that wrong
// produces the silent "menu commands stay disabled even after the
// selection populates" bug we hit at M7.

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

// MARK: - MergeTracksRequest
//
// Drives ContentView's .sheet(item:) presentation for the merge-
// track-picker dialog.  Identifiable for SwiftUI;  carries the
// destination's name (for the sheet's "Merge into <name>" header)
// and a pre-filtered candidate list (every track except the
// destination, mapped to lightweight (id, name) records so the
// sheet doesn't reach back into the session).

struct MergeTracksRequest: Identifiable {
    let id = UUID()
    let destinationId: UUID
    let destinationName: String
    let candidates: [Candidate]

    struct Candidate: Identifiable, Hashable {
        let id: UUID
        let name: String
    }
}

// MARK: - TrimTrackRequest
//
// Drives ContentView's .sheet(item:) presentation for the Trim
// Track dialog.  Carries the track id, name (for the dialog
// header), and the timestamp range (for the date pickers' default
// values and bounds).

struct TrimTrackRequest: Identifiable {
    let id = UUID()
    let trackId: UUID
    let trackName: String
    let timestampRange: ClosedRange<Date>
}

// MARK: - PinToGroundRequest
//
// Drives ContentView's .sheet(item:) presentation for the Pin-to-
// Ground confirmation-and-progress sheet (M7).  Carries:
//   - `scope`:  describes what the operation will run against —
//     the current selection (point count) or a whole master track
//     (track name + point count).  The sheet's header text is
//     derived from this.
//   - `queries`:  the per-point (lat, lon) snapshot that will be
//     sent to OpenTopoData.  The PointReference is preserved so
//     the sheet can map each returned elevation back to the right
//     point on commit.
//
// The sheet runs the async ElevationService loop itself rather
// than going through the SessionViewModel — progress reporting is
// sheet-local SwiftUI state and would be awkward to plumb through
// the view model.  On success the sheet calls back into
// applyPinToGround with the parallel elevations;  on cancel the
// in-flight Task is cancelled and the sheet dismisses without
// committing.

struct PinToGroundRequest: Identifiable {
    let id = UUID()
    let scope: Scope
    let queries: [PointQuery]

    /// What the operation will pin.  The sheet renders different
    /// header text per case so the user knows whether they're
    /// operating on a deliberate selection or implicitly on the
    /// whole master.
    enum Scope {
        case selection(pointCount: Int)
        case wholeTrack(trackName: String, pointCount: Int)
    }

    /// One point in the per-request payload — preserves the
    /// PointReference so the sheet can map each returned elevation
    /// back to the right point.  Lat/lon are snapshotted at request
    /// time;  if the user moves a point mid-Pin (impossible at v1
    /// but defensive), the snapshot is what gets queried.
    struct PointQuery: Sendable {
        let reference: Selection.PointReference
        let latitude: Double
        let longitude: Double
    }
}

// MARK: - Zoom bounds (M7.5)
//
// Geometric envelope used by the `zoom_to_bounds` bridge message.
// Pure data;  not part of the saved document (zoom is transient
// view state, like selection).  WGS84 decimal degrees.

/// Lat/lon bounding box.  `north > south` and `east > west` is the
/// caller's responsibility (Leaflet tolerates the inverse but the
/// result wouldn't match user intent).
struct GeographicBounds: Equatable, Sendable {
    let north: Double
    let south: Double
    let east: Double
    let west: Double
}

/// One-shot trigger wrapper for the zoom_to_bounds bridge message.
/// The fresh-UUID-per-call id makes Equatable comparisons in
/// SwiftUI's update cycle treat each invocation as a distinct
/// event, so MapView's coordinator dispatches once per call —
/// even if the user requests the same bounds twice in a row.
struct ZoomBoundsTrigger: Equatable, Sendable {
    let id: UUID
    let bounds: GeographicBounds
}
