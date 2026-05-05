// SelectionTests.swift
//
// Coverage for the window-scoped selection model:  set-style modifier
// merges, wire-format grouping/ungrouping, identity preservation across
// round-trips.  These tests anchor M3's selection invariant — that the
// canonical selection is the Set the model holds, and every wire-shape
// transformation is lossless.

import Testing
import Foundation
@testable import GPXEditor

@Suite("Selection")
struct SelectionTests {

    // Helper:  build a few stable test references.
    private let trackA = UUID()
    private let trackB = UUID()
    private let segA1 = UUID()
    private let segA2 = UUID()
    private let segB1 = UUID()

    private func ref(_ trackId: UUID, _ segmentId: UUID, _ index: Int) -> Selection.PointReference {
        Selection.PointReference(trackId: trackId, segmentId: segmentId, pointIndex: index)
    }

    // MARK: - Construction and basics

    @Test("Empty selection has no points and reports isEmpty")
    func emptySelection() {
        let s = Selection()
        #expect(s.isEmpty)
        #expect(s.count == 0)
    }

    @Test("Constructed-with-points selection reflects the input")
    func constructedSelection() {
        let s = Selection(points: [ref(trackA, segA1, 0), ref(trackA, segA1, 1)])
        #expect(!s.isEmpty)
        #expect(s.count == 2)
    }

    // MARK: - Modifier merges

    @Test("Replace discards the prior selection")
    func replace() {
        var s = Selection(points: [ref(trackA, segA1, 0), ref(trackA, segA1, 1)])
        s.replace(with: [ref(trackB, segB1, 5)])
        #expect(s.count == 1)
        #expect(s.points.contains(ref(trackB, segB1, 5)))
        #expect(!s.points.contains(ref(trackA, segA1, 0)))
    }

    @Test("Add unions new points into the existing selection")
    func add() {
        var s = Selection(points: [ref(trackA, segA1, 0)])
        s.add([ref(trackA, segA1, 1), ref(trackB, segB1, 2)])
        #expect(s.count == 3)
    }

    @Test("Add of an already-present point is idempotent (Set semantics)")
    func addDeduplicates() {
        var s = Selection(points: [ref(trackA, segA1, 0)])
        s.add([ref(trackA, segA1, 0), ref(trackA, segA1, 1)])
        #expect(s.count == 2)
    }

    @Test("Subtract removes named points and silently skips absent ones")
    func subtract() {
        var s = Selection(points: [
            ref(trackA, segA1, 0),
            ref(trackA, segA1, 1),
            ref(trackB, segB1, 5),
        ])
        s.subtract([
            ref(trackA, segA1, 1),
            ref(trackB, segB1, 99),  // absent — silently skipped
        ])
        #expect(s.count == 2)
        #expect(s.points.contains(ref(trackA, segA1, 0)))
        #expect(s.points.contains(ref(trackB, segB1, 5)))
        #expect(!s.points.contains(ref(trackA, segA1, 1)))
    }

    @Test("Clear empties the selection")
    func clear() {
        var s = Selection(points: [ref(trackA, segA1, 0)])
        s.clear()
        #expect(s.isEmpty)
    }

    // MARK: - Wire-format conversion

    @Test("grouped() collects points by (track, segment) with sorted indices")
    func groupedSorts() {
        let s = Selection(points: [
            ref(trackA, segA1, 5),
            ref(trackA, segA1, 1),
            ref(trackA, segA1, 3),
        ])
        let groups = s.grouped()
        #expect(groups.count == 1)
        #expect(groups[0].pointIndices == [1, 3, 5])
    }

    @Test("grouped() emits one entry per touched (track, segment) pair")
    func groupedSeparatesSegments() {
        let s = Selection(points: [
            ref(trackA, segA1, 0),
            ref(trackA, segA2, 0),  // same track, different segment
            ref(trackB, segB1, 0),
        ])
        let groups = s.grouped()
        #expect(groups.count == 3)
    }

    @Test("from(groups:) reconstructs the same selection (round-trip)")
    func roundTripThroughWire() {
        let original = Selection(points: [
            ref(trackA, segA1, 0),
            ref(trackA, segA1, 5),
            ref(trackA, segA2, 2),
            ref(trackB, segB1, 1),
        ])
        let groups = original.grouped()
        let rebuilt = Selection.from(groups: groups)
        #expect(rebuilt == original)
    }

    @Test("Empty selection groups to an empty array (no spurious entry)")
    func emptyGrouped() {
        let s = Selection()
        #expect(s.grouped().isEmpty)
    }
}
