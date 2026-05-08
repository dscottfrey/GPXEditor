// Selection.swift
//
// The set of currently-selected track points.  Selection is window-scoped
// editing state, not part of the saved document — opening a `.gpxeditor`
// file doesn't restore a prior selection, and saving doesn't persist
// one (Photoshop-equivalent: lasso state isn't saved with the .psd).
// Lives in `Models/` because it's a pure value type with no UI
// dependency, but it's instantiated and held by the per-window
// SessionViewModel rather than by GPXSession.
//
// Per Docs/02_MAP_AND_BRIDGE.md the bridge protocol identifies points
// by a (track_id, segment_id, point_index) triple.  Selection mirrors
// that:  the canonical representation is a `Set<PointReference>`.  The
// Set form makes set-style modifier merges (replace / add / subtract)
// natural and de-duplicates automatically.
//
// Conversion to and from the wire shape — a list of
// `{track_id, segment_id, point_indices}` groups — is handled here too,
// so the bridge layer doesn't have to re-implement the grouping in
// either direction.
//
// Platform-agnostic per CONVENTIONS.md.  Foundation only.

import Foundation

/// The set of currently-selected track points, identified positionally
/// (TrackPoints have no UUIDs of their own — see `TrackPoint.swift`).
public struct Selection: Equatable, Sendable {

    /// One leaf identity:  a single point in a single segment in a
    /// single track.  Hashable so Set deduplication works.
    public struct PointReference: Hashable, Sendable {
        public let trackId: UUID
        public let segmentId: UUID
        public let pointIndex: Int

        public init(trackId: UUID, segmentId: UUID, pointIndex: Int) {
            self.trackId = trackId
            self.segmentId = segmentId
            self.pointIndex = pointIndex
        }
    }

    /// The canonical store.  Set so merge operations are O(n) and the
    /// same point can never appear twice.
    public private(set) var points: Set<PointReference>

    /// The selection's "anchor" — the most recent single-point click
    /// that established the current selection's reference frame.  Used
    /// by shift-click range extension (Apple convention):  shift-click
    /// selects every point from `anchor` to the clicked point inclusive,
    /// within the same (track, segment).  Replaced when a single-point
    /// click or toggle commits;  unchanged by range extensions and by
    /// marquee/lasso add/subtract;  cleared on multi-point replace and
    /// on `clear()`.
    ///
    /// Anchor is purely transient view state — same as `points`.  Not
    /// part of the saved document.
    public private(set) var anchor: PointReference?

    public init(points: Set<PointReference> = [], anchor: PointReference? = nil) {
        self.points = points
        self.anchor = anchor
    }

    /// Whether anything is currently selected.  Cheaper to express this
    /// as a property than to make every call site write `.points.isEmpty`.
    public var isEmpty: Bool { points.isEmpty }

    /// Number of selected points across the project.
    public var count: Int { points.count }

    /// The single trackId all selected points belong to, or nil if the
    /// selection spans multiple tracks (or is empty).  Used by track-
    /// scoped operations like Reverse Track that disable themselves
    /// when the selection's scope is ambiguous — an "operate on the
    /// only-track-touched" idiom.
    public var uniqueTrackId: UUID? {
        guard let first = points.first else { return nil }
        let id = first.trackId
        for p in points where p.trackId != id { return nil }
        return id
    }

    /// The single PointReference if the selection contains exactly
    /// one point, otherwise nil.  Used by single-point operations
    /// (Split Track at Point) that need an unambiguous (track,
    /// segment, index) target from the selection — anything other
    /// than a one-point selection disables the operation.
    public var singlePointReference: PointReference? {
        guard points.count == 1 else { return nil }
        return points.first
    }

    // MARK: - Mutations

    /// Replace the selection with a new set.  Plain mouse-click on a
    /// vertex sends a single-point replace;  marquee / lasso plain
    /// commits send a multi-point replace.  Anchor follows the input:
    /// single-point replace sets anchor to that point (so a subsequent
    /// shift-click can range-extend from there);  multi-point replace
    /// (marquee / lasso) clears anchor — the marquee gesture didn't
    /// establish an unambiguous "anchor" point.
    public mutating func replace(with newPoints: [PointReference]) {
        points = Set(newPoints)
        if newPoints.count == 1 {
            anchor = newPoints[0]
        } else {
            anchor = nil
        }
    }

    /// Add to the existing selection.  Marquee / lasso shift-drag sends
    /// this modifier.  Anchor is unchanged — adding to a selection
    /// doesn't redefine the anchor, the user is extending what they
    /// already had.
    public mutating func add(_ newPoints: [PointReference]) {
        for p in newPoints { points.insert(p) }
    }

    /// Remove specific points from the existing selection.  Marquee /
    /// lasso option-drag sends this modifier.  Points not in the
    /// selection are silently skipped — set subtraction semantics, no
    /// error case.  Anchor is unchanged unless the anchor point itself
    /// is being subtracted, in which case it's cleared.
    public mutating func subtract(_ removedPoints: [PointReference]) {
        let removed = Set(removedPoints)
        for p in removedPoints { points.remove(p) }
        if let a = anchor, removed.contains(a) {
            anchor = nil
        }
    }

    /// Toggle membership of a single clicked point — Apple ⌘-click
    /// convention.  If the point is currently selected, remove it;
    /// otherwise add it.  Anchor is set to the clicked point in either
    /// case (it becomes the new range-extension reference for any
    /// subsequent shift-click).
    public mutating func toggle(_ ref: PointReference) {
        if points.contains(ref) {
            points.remove(ref)
        } else {
            points.insert(ref)
        }
        anchor = ref
    }

    /// Extend the selection from the current anchor to the clicked
    /// point inclusive — Apple shift-click convention.  Within the
    /// same (track, segment), selects every index from
    /// `min(anchor.idx, ref.idx)` to `max(...)`.  If anchor is nil OR
    /// in a different (track, segment), falls back to plain replace
    /// semantics (selection becomes just the clicked point, anchor =
    /// clicked) — cross-segment "range" has no natural definition for
    /// points-in-segments and Apple's range gesture is intra-list
    /// anyway.  Anchor is preserved when the range applies cleanly so
    /// repeated shift-clicks all extend from the same origin (which is
    /// the Finder behavior the user expects).
    public mutating func extendRange(to ref: PointReference) {
        guard let anchor = anchor else {
            // No anchor — treat as plain click, set anchor to clicked.
            replace(with: [ref])
            return
        }
        if anchor.trackId != ref.trackId || anchor.segmentId != ref.segmentId {
            // Cross-segment range falls back to plain replace.
            replace(with: [ref])
            return
        }
        let lo = min(anchor.pointIndex, ref.pointIndex)
        let hi = max(anchor.pointIndex, ref.pointIndex)
        var newRefs: Set<PointReference> = []
        for i in lo...hi {
            newRefs.insert(PointReference(
                trackId: ref.trackId,
                segmentId: ref.segmentId,
                pointIndex: i
            ))
        }
        points = newRefs
        // anchor preserved — successive shift-clicks all extend from
        // the same anchor (Apple convention).
    }

    /// Drop everything.  ⇧⌘A (deselect all) takes this path;  Delete
    /// uses it after the deletion completes.  Also clears the anchor.
    public mutating func clear() {
        points.removeAll(keepingCapacity: false)
        anchor = nil
    }

    // MARK: - Wire format conversion

    /// Group the selection by (track, segment) for the wire format.
    /// The bridge protocol expresses selection as
    ///   `[{track_id, segment_id, point_indices: [Int]}]`
    /// — one entry per (track, segment) pair touched by the selection,
    /// each carrying its sorted index list.  Sorting the indices keeps
    /// the wire output deterministic for tests and for diff-friendly
    /// log lines.
    public func grouped() -> [SegmentGroup] {
        var byKey: [SegmentKey: [Int]] = [:]
        for p in points {
            byKey[SegmentKey(trackId: p.trackId, segmentId: p.segmentId), default: []].append(p.pointIndex)
        }
        // Sort the groups by (trackId.uuidString, segmentId.uuidString)
        // for determinism;  callers who need a specific order can resort
        // after the fact.
        return byKey
            .map { (key, indices) in
                SegmentGroup(
                    trackId: key.trackId,
                    segmentId: key.segmentId,
                    pointIndices: indices.sorted()
                )
            }
            .sorted { ($0.trackId.uuidString, $0.segmentId.uuidString)
                       < ($1.trackId.uuidString, $1.segmentId.uuidString) }
    }

    /// Build a Selection from the grouped wire shape.  Used by the
    /// bridge dispatcher when JS sends a `points_selected` message.
    public static func from(groups: [SegmentGroup]) -> Selection {
        var refs: Set<PointReference> = []
        for g in groups {
            for i in g.pointIndices {
                refs.insert(PointReference(trackId: g.trackId, segmentId: g.segmentId, pointIndex: i))
            }
        }
        return Selection(points: refs)
    }

    /// One (track, segment) group with its point indices.  The wire
    /// format is a list of these.
    public struct SegmentGroup: Equatable, Sendable {
        public let trackId: UUID
        public let segmentId: UUID
        public let pointIndices: [Int]

        public init(trackId: UUID, segmentId: UUID, pointIndices: [Int]) {
            self.trackId = trackId
            self.segmentId = segmentId
            self.pointIndices = pointIndices
        }
    }

    /// Internal hashing key for the grouping pass.
    private struct SegmentKey: Hashable {
        let trackId: UUID
        let segmentId: UUID
    }
}
