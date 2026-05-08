// PinToGroundOperationTests.swift
//
// Coverage for PinToGroundOperation — replaces named points'
// elevations with new values, preserving lat / lon / time.  The
// operation is pure;  tests do not touch the network.

import Testing
import Foundation
@testable import GPXEditor

@Suite("PinToGroundOperation")
struct PinToGroundOperationTests {

    // MARK: - Fixtures

    private func point(lat: Double, lon: Double, ele: Double? = nil, time: Date? = nil) -> TrackPoint {
        TrackPoint(latitude: lat, longitude: lon, elevation: ele, time: time)
    }

    /// Two-segment, single-track session with predictable elevations so
    /// "did the right point get rewritten" assertions are trivial.
    private func makeFixture() -> (session: GPXSession, trackId: UUID, segIds: [UUID]) {
        let s1id = UUID()
        let s2id = UUID()
        let s1 = Segment(id: s1id, color: HexColor("#FF0000")!, points: [
            point(lat: 45.0, lon: -120.0, ele: 100, time: Date(timeIntervalSince1970: 1_700_000_000)),
            point(lat: 45.001, lon: -120.0, ele: 110, time: Date(timeIntervalSince1970: 1_700_000_010)),
            point(lat: 45.002, lon: -120.0, ele: 120, time: Date(timeIntervalSince1970: 1_700_000_020)),
        ])
        let s2 = Segment(id: s2id, color: HexColor("#00FF00")!, points: [
            point(lat: 46.0, lon: -119.0, ele: 200),
            point(lat: 46.001, lon: -119.0, ele: 210),
        ])
        let track = Track(id: UUID(), name: "T", immutableOriginalBytes: Data(), segments: [s1, s2])
        return (GPXSession(metadata: ProjectMetadata(), tracks: [track]), track.id, [s1id, s2id])
    }

    private func ref(_ trackId: UUID, _ segId: UUID, _ idx: Int) -> Selection.PointReference {
        Selection.PointReference(trackId: trackId, segmentId: segId, pointIndex: idx)
    }

    // MARK: - Basic apply

    @Test("Replaces named points' elevations with the supplied values")
    func basicApply() {
        let (s, t, segs) = makeFixture()
        let refs = [
            ref(t, segs[0], 0),
            ref(t, segs[0], 2),
            ref(t, segs[1], 1),
        ]
        let newEles: [Double?] = [555, 666, 777]
        let result = PinToGroundOperation.apply(to: s, references: refs, newElevations: newEles)

        #expect(result.session.tracks[0].segments[0].points[0].elevation == 555)
        #expect(result.session.tracks[0].segments[0].points[1].elevation == 110)  // untouched
        #expect(result.session.tracks[0].segments[0].points[2].elevation == 666)
        #expect(result.session.tracks[0].segments[1].points[0].elevation == 200)  // untouched
        #expect(result.session.tracks[0].segments[1].points[1].elevation == 777)
    }

    @Test("Preserves lat / lon / time on every updated point")
    func preservesNonElevationFields() {
        let (s, t, segs) = makeFixture()
        let refs = [ref(t, segs[0], 1)]
        let result = PinToGroundOperation.apply(to: s, references: refs, newElevations: [999])
        let updated = result.session.tracks[0].segments[0].points[1]
        let original = s.tracks[0].segments[0].points[1]
        #expect(updated.latitude == original.latitude)
        #expect(updated.longitude == original.longitude)
        #expect(updated.time == original.time)
        #expect(updated.elevation == 999)
    }

    @Test("Touched list dedupes by (track, segment) and is deterministic")
    func touchedListShape() {
        let (s, t, segs) = makeFixture()
        // Three updates in segment 0, one in segment 1 — touched should
        // be exactly two entries even though four points were touched.
        let refs = [
            ref(t, segs[0], 0),
            ref(t, segs[0], 1),
            ref(t, segs[0], 2),
            ref(t, segs[1], 0),
        ]
        let result = PinToGroundOperation.apply(
            to: s, references: refs,
            newElevations: [1, 2, 3, 4]
        )
        #expect(result.touched.count == 2)
        let touchedSegIds = Set(result.touched.map(\.segmentId))
        #expect(touchedSegIds == Set([segs[0], segs[1]]))
    }

    // MARK: - Skip-on-nil

    @Test("Nil entries in newElevations skip the corresponding reference")
    func nilEntrySkipped() {
        let (s, t, segs) = makeFixture()
        let refs = [ref(t, segs[0], 0), ref(t, segs[0], 1)]
        let result = PinToGroundOperation.apply(
            to: s, references: refs,
            newElevations: [nil, 222]
        )
        // Index 0 elevation unchanged because newElevations[0] was nil.
        #expect(result.session.tracks[0].segments[0].points[0].elevation == 100)
        #expect(result.session.tracks[0].segments[0].points[1].elevation == 222)
        // Touched contains only the segment that actually changed.
        #expect(result.touched.count == 1)
    }

    @Test("All-nil newElevations is a complete no-op")
    func allNilNoOp() {
        let (s, t, segs) = makeFixture()
        let refs = [ref(t, segs[0], 0), ref(t, segs[0], 1), ref(t, segs[1], 0)]
        let result = PinToGroundOperation.apply(
            to: s, references: refs,
            newElevations: [nil, nil, nil]
        )
        #expect(result.session == s)
        #expect(result.touched.isEmpty)
    }

    // MARK: - Stale-reference tolerance

    @Test("Stale track id silently ignored")
    func staleTrack() {
        let (s, _, segs) = makeFixture()
        let refs = [ref(UUID(), segs[0], 0)]  // track id doesn't exist
        let result = PinToGroundOperation.apply(to: s, references: refs, newElevations: [555])
        #expect(result.session == s)
        #expect(result.touched.isEmpty)
    }

    @Test("Stale segment id silently ignored")
    func staleSegment() {
        let (s, t, _) = makeFixture()
        let refs = [ref(t, UUID(), 0)]  // segment id doesn't exist
        let result = PinToGroundOperation.apply(to: s, references: refs, newElevations: [555])
        #expect(result.session == s)
        #expect(result.touched.isEmpty)
    }

    @Test("Out-of-range point index silently ignored")
    func staleIndex() {
        let (s, t, segs) = makeFixture()
        let refs = [ref(t, segs[0], 99), ref(t, segs[0], -1)]
        let result = PinToGroundOperation.apply(to: s, references: refs, newElevations: [555, 666])
        #expect(result.session == s)
        #expect(result.touched.isEmpty)
    }

    @Test("Mix of valid and stale refs only applies the valid ones")
    func mixedStale() {
        let (s, t, segs) = makeFixture()
        let refs = [
            ref(t, segs[0], 0),       // valid
            ref(UUID(), segs[0], 1),  // stale track
            ref(t, segs[0], 2),       // valid
        ]
        let result = PinToGroundOperation.apply(
            to: s, references: refs,
            newElevations: [111, 222, 333]
        )
        #expect(result.session.tracks[0].segments[0].points[0].elevation == 111)
        #expect(result.session.tracks[0].segments[0].points[1].elevation == 110)  // untouched
        #expect(result.session.tracks[0].segments[0].points[2].elevation == 333)
        #expect(result.touched.count == 1)  // one segment, even though two refs were valid
    }

    // MARK: - Length-mismatch tolerance

    @Test("Shorter elevations array truncates to its length")
    func shorterElevations() {
        let (s, t, segs) = makeFixture()
        let refs = [ref(t, segs[0], 0), ref(t, segs[0], 1), ref(t, segs[0], 2)]
        let result = PinToGroundOperation.apply(
            to: s, references: refs,
            newElevations: [111, 222]  // missing the third entry
        )
        #expect(result.session.tracks[0].segments[0].points[0].elevation == 111)
        #expect(result.session.tracks[0].segments[0].points[1].elevation == 222)
        #expect(result.session.tracks[0].segments[0].points[2].elevation == 120)  // untouched
    }

    @Test("Longer elevations array ignores the trailing extras")
    func longerElevations() {
        let (s, t, segs) = makeFixture()
        let refs = [ref(t, segs[0], 0)]
        let result = PinToGroundOperation.apply(
            to: s, references: refs,
            newElevations: [111, 222, 333]  // two extras get silently dropped
        )
        #expect(result.session.tracks[0].segments[0].points[0].elevation == 111)
        #expect(result.session.tracks[0].segments[0].points[1].elevation == 110)  // untouched
        #expect(result.touched.count == 1)
    }

    // MARK: - Same-value no-op

    @Test("Same elevation value doesn't produce a touched entry")
    func sameValueNoOp() {
        let (s, t, segs) = makeFixture()
        let originalEle = s.tracks[0].segments[0].points[1].elevation!  // 110
        let refs = [ref(t, segs[0], 1)]
        let result = PinToGroundOperation.apply(
            to: s, references: refs,
            newElevations: [originalEle]
        )
        #expect(result.session == s)
        #expect(result.touched.isEmpty)
    }

    @Test("Setting elevation on a previously-nil point is not a no-op")
    func nilToValueIsAChange() {
        // Build a session with a point that has no elevation.
        let segId = UUID()
        let segment = Segment(
            id: segId,
            color: HexColor("#FF0000")!,
            points: [point(lat: 1, lon: 2, ele: nil)]
        )
        let track = Track(id: UUID(), name: "T", immutableOriginalBytes: Data(), segments: [segment])
        let session = GPXSession(metadata: ProjectMetadata(), tracks: [track])

        let refs = [ref(track.id, segId, 0)]
        let result = PinToGroundOperation.apply(to: session, references: refs, newElevations: [42])
        #expect(result.session.tracks[0].segments[0].points[0].elevation == 42)
        #expect(result.touched.count == 1)
    }
}
