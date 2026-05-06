// TrimTrackOperationTests.swift
//
// Coverage for TrimTrackOperation — drops points outside a time
// window, preserves untimestamped points, preserves segment
// identity (even when emptied), and provides timestampRange /
// pointsToRemove helpers for the dialog.

import Testing
import Foundation
@testable import GPXEditor

@Suite("TrimTrackOperation")
struct TrimTrackOperationTests {

    private func t(_ epoch: TimeInterval) -> Date {
        Date(timeIntervalSince1970: epoch)
    }

    private func point(lat: Double = 45.0, lon: Double = -120.0, time: Date? = nil) -> TrackPoint {
        TrackPoint(latitude: lat, longitude: lon, elevation: nil, time: time)
    }

    private func makeSession(segments: [Segment]) -> (GPXSession, Track) {
        let track = Track(
            id: UUID(),
            name: "T",
            immutableOriginalBytes: Data(),
            segments: segments
        )
        return (GPXSession(metadata: ProjectMetadata(), tracks: [track]), track)
    }

    @Test("Trim start drops points before the cutoff; cutoff itself stays")
    func trimStart() {
        let seg = Segment(id: UUID(), color: HexColor("#FF0000")!, points: [
            point(lat: 1, time: t(100)),
            point(lat: 2, time: t(200)),
            point(lat: 3, time: t(300)),
            point(lat: 4, time: t(400)),
        ])
        let (s, track) = makeSession(segments: [seg])

        let r = TrimTrackOperation.apply(
            to: s, trackId: track.id,
            trimStartBefore: t(200),
            trimEndAfter: nil
        )
        #expect(r.touched.count == 1)
        // 200 itself stays;  100 dropped.
        #expect(r.session.tracks[0].segments[0].points.map(\.latitude) == [2, 3, 4])
    }

    @Test("Trim end drops points after the cutoff; cutoff itself stays")
    func trimEnd() {
        let seg = Segment(id: UUID(), color: HexColor("#FF0000")!, points: [
            point(lat: 1, time: t(100)),
            point(lat: 2, time: t(200)),
            point(lat: 3, time: t(300)),
            point(lat: 4, time: t(400)),
        ])
        let (s, track) = makeSession(segments: [seg])

        let r = TrimTrackOperation.apply(
            to: s, trackId: track.id,
            trimStartBefore: nil,
            trimEndAfter: t(300)
        )
        // 300 itself stays;  400 dropped.
        #expect(r.session.tracks[0].segments[0].points.map(\.latitude) == [1, 2, 3])
    }

    @Test("Both bounds set: window keeps inclusive endpoints")
    func trimBothEnds() {
        let seg = Segment(id: UUID(), color: HexColor("#FF0000")!, points: [
            point(lat: 1, time: t(100)),
            point(lat: 2, time: t(200)),
            point(lat: 3, time: t(300)),
            point(lat: 4, time: t(400)),
            point(lat: 5, time: t(500)),
        ])
        let (s, track) = makeSession(segments: [seg])

        let r = TrimTrackOperation.apply(
            to: s, trackId: track.id,
            trimStartBefore: t(200),
            trimEndAfter: t(400)
        )
        #expect(r.session.tracks[0].segments[0].points.map(\.latitude) == [2, 3, 4])
    }

    @Test("Untimestamped points always kept")
    func untimestampedKept() {
        let seg = Segment(id: UUID(), color: HexColor("#FF0000")!, points: [
            point(lat: 1, time: t(100)),
            point(lat: 99, time: nil),  // synthesized point with no time
            point(lat: 2, time: t(200)),
            point(lat: 100, time: nil),
            point(lat: 3, time: t(300)),
        ])
        let (s, track) = makeSession(segments: [seg])

        let r = TrimTrackOperation.apply(
            to: s, trackId: track.id,
            trimStartBefore: t(200),
            trimEndAfter: nil
        )
        // Both untimestamped points (99 and 100) survive;  point 1 drops.
        #expect(r.session.tracks[0].segments[0].points.map(\.latitude) == [99, 2, 100, 3])
    }

    @Test("Empty segments preserved (identity for undo)")
    func emptySegmentsPreserved() {
        let seg1 = Segment(id: UUID(), color: HexColor("#FF0000")!, points: [
            point(lat: 1, time: t(100)),
            point(lat: 2, time: t(200)),
        ])
        let seg2 = Segment(id: UUID(), color: HexColor("#00FF00")!, points: [
            point(lat: 3, time: t(300)),
            point(lat: 4, time: t(400)),
        ])
        let (s, track) = makeSession(segments: [seg1, seg2])

        let r = TrimTrackOperation.apply(
            to: s, trackId: track.id,
            trimStartBefore: t(300),
            trimEndAfter: nil
        )
        // seg1 is fully dropped but stays as an empty segment.
        #expect(r.session.tracks[0].segments.count == 2)
        #expect(r.session.tracks[0].segments[0].id == seg1.id)
        #expect(r.session.tracks[0].segments[0].points.isEmpty)
        #expect(r.session.tracks[0].segments[1].id == seg2.id)
        #expect(r.session.tracks[0].segments[1].points.map(\.latitude) == [3, 4])
    }

    @Test("Both bounds nil is a no-op")
    func bothNilNoOp() {
        let seg = Segment(id: UUID(), color: HexColor("#FF0000")!, points: [
            point(lat: 1, time: t(100)),
            point(lat: 2, time: t(200)),
        ])
        let (s, track) = makeSession(segments: [seg])

        let r = TrimTrackOperation.apply(
            to: s, trackId: track.id,
            trimStartBefore: nil,
            trimEndAfter: nil
        )
        #expect(r.touched.isEmpty)
        #expect(r.session == s)
    }

    @Test("Bounds set but nothing falls outside is a no-op")
    func setButNoOp() {
        let seg = Segment(id: UUID(), color: HexColor("#FF0000")!, points: [
            point(lat: 1, time: t(100)),
            point(lat: 2, time: t(200)),
            point(lat: 3, time: t(300)),
        ])
        let (s, track) = makeSession(segments: [seg])

        let r = TrimTrackOperation.apply(
            to: s, trackId: track.id,
            trimStartBefore: t(50),    // earlier than every point
            trimEndAfter: t(400)        // later than every point
        )
        #expect(r.touched.isEmpty)
        #expect(r.session == s)
    }

    @Test("Stale trackId is a no-op")
    func staleTrackId() {
        let seg = Segment(id: UUID(), color: HexColor("#FF0000")!, points: [
            point(lat: 1, time: t(100)),
        ])
        let (s, _) = makeSession(segments: [seg])
        let r = TrimTrackOperation.apply(
            to: s, trackId: UUID(),
            trimStartBefore: t(50),
            trimEndAfter: nil
        )
        #expect(r.touched.isEmpty)
        #expect(r.session == s)
    }

    @Test("timestampRange returns earliest and latest")
    func timestampRangeBasic() {
        let seg = Segment(id: UUID(), color: HexColor("#FF0000")!, points: [
            point(lat: 1, time: t(300)),
            point(lat: 2, time: t(100)),
            point(lat: 3, time: t(500)),
            point(lat: 4, time: t(200)),
        ])
        let (s, track) = makeSession(segments: [seg])

        let range = TrimTrackOperation.timestampRange(of: track.id, in: s)
        #expect(range == t(100)...t(500))
    }

    @Test("timestampRange ignores untimestamped points")
    func timestampRangeMixed() {
        let seg = Segment(id: UUID(), color: HexColor("#FF0000")!, points: [
            point(lat: 1, time: nil),
            point(lat: 2, time: t(200)),
            point(lat: 3, time: nil),
            point(lat: 4, time: t(400)),
        ])
        let (s, track) = makeSession(segments: [seg])
        let range = TrimTrackOperation.timestampRange(of: track.id, in: s)
        #expect(range == t(200)...t(400))
    }

    @Test("timestampRange returns nil when no point has a timestamp")
    func timestampRangeNone() {
        let seg = Segment(id: UUID(), color: HexColor("#FF0000")!, points: [
            point(lat: 1, time: nil),
            point(lat: 2, time: nil),
        ])
        let (s, track) = makeSession(segments: [seg])
        let range = TrimTrackOperation.timestampRange(of: track.id, in: s)
        #expect(range == nil)
    }

    @Test("pointsToRemove preview matches what apply would drop")
    func previewMatchesApply() {
        let seg = Segment(id: UUID(), color: HexColor("#FF0000")!, points: [
            point(lat: 1, time: t(100)),
            point(lat: 2, time: t(200)),
            point(lat: 3, time: t(300)),
            point(lat: 4, time: t(400)),
        ])
        let (s, track) = makeSession(segments: [seg])
        let preview = TrimTrackOperation.pointsToRemove(
            in: s, trackId: track.id,
            trimStartBefore: t(200),
            trimEndAfter: t(300)
        )
        // Indices 0 (time 100) and 3 (time 400) are dropped.
        #expect(preview.count == 1)
        #expect(preview[0].pointIndices == [0, 3])
    }

    @Test("pointsToRemove with both nil returns empty")
    func previewBothNilEmpty() {
        let seg = Segment(id: UUID(), color: HexColor("#FF0000")!, points: [
            point(lat: 1, time: t(100)),
        ])
        let (s, track) = makeSession(segments: [seg])
        let preview = TrimTrackOperation.pointsToRemove(
            in: s, trackId: track.id,
            trimStartBefore: nil,
            trimEndAfter: nil
        )
        #expect(preview.isEmpty)
    }
}
