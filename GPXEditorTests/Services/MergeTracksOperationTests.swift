// MergeTracksOperationTests.swift
//
// Coverage for MergeTracksOperation — appends a source track's
// segments and waypoints to a destination track, then removes the
// source.  Destination keeps its identity (id, name, role, bytes,
// recordedDate);  source's identity dissolves.

import Testing
import Foundation
@testable import GPXEditor

@Suite("MergeTracksOperation")
struct MergeTracksOperationTests {

    private func point(lat: Double, lon: Double) -> TrackPoint {
        TrackPoint(latitude: lat, longitude: lon)
    }

    private func makeTrack(
        name: String,
        segments: [Segment] = [],
        waypoints: [Waypoint] = [],
        role: TrackRole? = nil,
        bytes: Data = Data(),
        recordedDate: Date? = nil
    ) -> Track {
        Track(
            id: UUID(),
            name: name,
            immutableOriginalBytes: bytes,
            segments: segments,
            waypoints: waypoints,
            role: role,
            recordedDate: recordedDate
        )
    }

    private func session(_ tracks: [Track]) -> GPXSession {
        GPXSession(metadata: ProjectMetadata(), tracks: tracks)
    }

    @Test("Source segments append to destination's segment list (in order)")
    func segmentsAppend() {
        let dstSeg = Segment(id: UUID(), color: HexColor("#FF0000")!, points: [
            point(lat: 45.0, lon: -120.0),
            point(lat: 45.001, lon: -120.0),
        ])
        let srcSeg1 = Segment(id: UUID(), color: HexColor("#00FF00")!, points: [
            point(lat: 46.0, lon: -120.0),
        ])
        let srcSeg2 = Segment(id: UUID(), color: HexColor("#0000FF")!, points: [
            point(lat: 47.0, lon: -120.0),
            point(lat: 47.001, lon: -120.0),
        ])
        let dst = makeTrack(name: "Destination", segments: [dstSeg])
        let src = makeTrack(name: "Source", segments: [srcSeg1, srcSeg2])
        let s = session([dst, src])

        let result = MergeTracksOperation.apply(
            to: s, sourceTrackId: src.id, destinationTrackId: dst.id
        )
        // One track left.
        #expect(result.session.tracks.count == 1)
        let merged = result.session.tracks[0]
        #expect(merged.id == dst.id)
        #expect(merged.segments.count == 3)
        #expect(merged.segments[0].id == dstSeg.id)
        #expect(merged.segments[1].id == srcSeg1.id)
        #expect(merged.segments[2].id == srcSeg2.id)
    }

    @Test("Waypoints from both tracks land on the destination")
    func waypointsAppend() {
        let dstWp = Waypoint(latitude: 45.0, longitude: -120.0, elevation: nil, time: nil, name: "DstStart", sym: "Trailhead", description: nil)
        let srcWp = Waypoint(latitude: 46.0, longitude: -120.0, elevation: nil, time: nil, name: "SrcStart", sym: "Trailhead", description: nil)
        let dst = makeTrack(name: "Dst", segments: [
            Segment(id: UUID(), color: HexColor("#FF0000")!, points: [point(lat: 45.0, lon: -120.0)])
        ], waypoints: [dstWp])
        let src = makeTrack(name: "Src", segments: [
            Segment(id: UUID(), color: HexColor("#00FF00")!, points: [point(lat: 46.0, lon: -120.0)])
        ], waypoints: [srcWp])
        let s = session([dst, src])

        let result = MergeTracksOperation.apply(
            to: s, sourceTrackId: src.id, destinationTrackId: dst.id
        )
        let merged = result.session.tracks[0]
        #expect(merged.waypoints.count == 2)
        #expect(merged.waypoints.contains(where: { $0.id == dstWp.id }))
        #expect(merged.waypoints.contains(where: { $0.id == srcWp.id }))
    }

    @Test("Source track is removed from session")
    func sourceRemoved() {
        let dst = makeTrack(name: "Dst", segments: [
            Segment(id: UUID(), color: HexColor("#FF0000")!, points: [point(lat: 45.0, lon: -120.0)])
        ])
        let src = makeTrack(name: "Src", segments: [
            Segment(id: UUID(), color: HexColor("#00FF00")!, points: [point(lat: 46.0, lon: -120.0)])
        ])
        let s = session([dst, src])

        let result = MergeTracksOperation.apply(
            to: s, sourceTrackId: src.id, destinationTrackId: dst.id
        )
        #expect(!result.session.tracks.contains(where: { $0.id == src.id }))
    }

    @Test("Destination identity (id, name, role, bytes, recordedDate) preserved")
    func destinationIdentityPreserved() {
        let dstBytes = Data([0xAA, 0xBB])
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let dst = makeTrack(
            name: "Destination Name",
            segments: [Segment(id: UUID(), color: HexColor("#FF0000")!, points: [point(lat: 45.0, lon: -120.0)])],
            role: .master,
            bytes: dstBytes,
            recordedDate: date
        )
        let src = makeTrack(name: "Source Name", segments: [
            Segment(id: UUID(), color: HexColor("#00FF00")!, points: [point(lat: 46.0, lon: -120.0)])
        ], role: .subsidiary, bytes: Data([0xCC]), recordedDate: Date(timeIntervalSince1970: 1_800_000_000))
        let s = session([dst, src])

        let result = MergeTracksOperation.apply(
            to: s, sourceTrackId: src.id, destinationTrackId: dst.id
        )
        let merged = result.session.tracks[0]
        #expect(merged.id == dst.id)
        #expect(merged.name == "Destination Name")
        #expect(merged.role == .master)
        #expect(merged.immutableOriginalBytes == dstBytes)
        #expect(merged.recordedDate == date)
    }

    @Test("Source segment ids and colors preserved on append")
    func sourceSegmentDataPreserved() {
        let srcSeg = Segment(id: UUID(), name: "SrcSeg", color: HexColor("#ABCDEF")!, points: [
            point(lat: 46.0, lon: -120.0),
            point(lat: 46.001, lon: -120.0),
        ])
        let dst = makeTrack(name: "Dst", segments: [
            Segment(id: UUID(), color: HexColor("#FF0000")!, points: [point(lat: 45.0, lon: -120.0)])
        ])
        let src = makeTrack(name: "Src", segments: [srcSeg])
        let s = session([dst, src])

        let result = MergeTracksOperation.apply(
            to: s, sourceTrackId: src.id, destinationTrackId: dst.id
        )
        let appended = result.session.tracks[0].segments[1]
        #expect(appended.id == srcSeg.id)
        #expect(appended.name == "SrcSeg")
        #expect(appended.color == HexColor("#ABCDEF")!)
        #expect(appended.points.count == 2)
    }

    @Test("Touched list reports the destination only")
    func touchedList() {
        let dst = makeTrack(name: "Dst", segments: [
            Segment(id: UUID(), color: HexColor("#FF0000")!, points: [point(lat: 45.0, lon: -120.0)])
        ])
        let src = makeTrack(name: "Src", segments: [
            Segment(id: UUID(), color: HexColor("#00FF00")!, points: [point(lat: 46.0, lon: -120.0)])
        ])
        let s = session([dst, src])

        let result = MergeTracksOperation.apply(
            to: s, sourceTrackId: src.id, destinationTrackId: dst.id
        )
        #expect(result.touched == [MergeTracksOperation.TouchedTrack(trackId: dst.id)])
    }

    @Test("Self-merge is a no-op")
    func selfMergeNoOp() {
        let t = makeTrack(name: "T", segments: [
            Segment(id: UUID(), color: HexColor("#FF0000")!, points: [point(lat: 45.0, lon: -120.0)])
        ])
        let s = session([t])

        let result = MergeTracksOperation.apply(
            to: s, sourceTrackId: t.id, destinationTrackId: t.id
        )
        #expect(result.touched.isEmpty)
        #expect(result.session == s)
    }

    @Test("Stale source id is a no-op")
    func staleSourceId() {
        let dst = makeTrack(name: "Dst", segments: [
            Segment(id: UUID(), color: HexColor("#FF0000")!, points: [point(lat: 45.0, lon: -120.0)])
        ])
        let s = session([dst])

        let result = MergeTracksOperation.apply(
            to: s, sourceTrackId: UUID(), destinationTrackId: dst.id
        )
        #expect(result.touched.isEmpty)
        #expect(result.session == s)
    }

    @Test("Stale destination id is a no-op")
    func staleDestinationId() {
        let src = makeTrack(name: "Src", segments: [
            Segment(id: UUID(), color: HexColor("#00FF00")!, points: [point(lat: 46.0, lon: -120.0)])
        ])
        let s = session([src])

        let result = MergeTracksOperation.apply(
            to: s, sourceTrackId: src.id, destinationTrackId: UUID()
        )
        #expect(result.touched.isEmpty)
        #expect(result.session == s)
    }

    @Test("Source ordered before destination still merges correctly")
    func sourceBeforeDestination() {
        // Stress the index-shifting concern called out in the
        // operation's comment:  if source comes first in the array,
        // removing it after the destination's index is captured
        // would shift the destination's index down.  The operation
        // re-finds by id;  this test verifies that.
        let srcSeg = Segment(id: UUID(), color: HexColor("#00FF00")!, points: [
            point(lat: 46.0, lon: -120.0),
        ])
        let dstSeg = Segment(id: UUID(), color: HexColor("#FF0000")!, points: [
            point(lat: 45.0, lon: -120.0),
        ])
        let src = makeTrack(name: "Src", segments: [srcSeg])
        let dst = makeTrack(name: "Dst", segments: [dstSeg])
        let s = session([src, dst])  // src ordered first

        let result = MergeTracksOperation.apply(
            to: s, sourceTrackId: src.id, destinationTrackId: dst.id
        )
        #expect(result.session.tracks.count == 1)
        let merged = result.session.tracks[0]
        #expect(merged.id == dst.id)
        #expect(merged.segments.count == 2)
        #expect(merged.segments[0].id == dstSeg.id)
        #expect(merged.segments[1].id == srcSeg.id)
    }
}
