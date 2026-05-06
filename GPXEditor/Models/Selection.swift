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

    public init(points: Set<PointReference> = []) {
        self.points = points
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

    /// Replace the selection with a new set.  Plain mouse-click on the
    /// map sends this modifier;  it discards any previous selection.
    public mutating func replace(with newPoints: [PointReference]) {
        points = Set(newPoints)
    }

    /// Add to the existing selection.  Shift-click sends this modifier.
    public mutating func add(_ newPoints: [PointReference]) {
        for p in newPoints { points.insert(p) }
    }

    /// Remove specific points from the existing selection.  Option-click
    /// sends this modifier.  Points not in the selection are silently
    /// skipped — set subtraction semantics, no error case.
    public mutating func subtract(_ removedPoints: [PointReference]) {
        for p in removedPoints { points.remove(p) }
    }

    /// Drop everything.  ⇧⌘A (deselect all) takes this path;  Delete
    /// uses it after the deletion completes.
    public mutating func clear() {
        points.removeAll(keepingCapacity: false)
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
