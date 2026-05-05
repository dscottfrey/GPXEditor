// PlaceWaypointOperationTests.swift
//
// Coverage for PlaceWaypointOperation — adds a new Waypoint at a
// click location.  Track-ownership rules:  master track if one is
// designated, else the first track in the session, else no-op.

import Testing
import Foundation
@testable import GPXEditor

@Suite("PlaceWaypointOperation")
struct PlaceWaypointOperationTests {

    private func makeTrack(name: String = "T", role: TrackRole? = nil, waypoints: [Waypoint] = []) -> Track {
        let segment = Segment(
            id: UUID(),
            color: HexColor("#FF0000")!,
            points: [TrackPoint(latitude: 0, longitude: 0)]
        )
        return Track(
            id: UUID(),
            name: name,
            immutableOriginalBytes: Data(),
            segments: [segment],
            waypoints: waypoints,
            role: role
        )
    }

    @Test("Empty session returns nil host (no-op)")
    func emptySession() {
        let s = GPXSession(metadata: ProjectMetadata(), tracks: [])
        let result = PlaceWaypointOperation.apply(to: s, latitude: 45, longitude: -120)
        #expect(result.hostTrackId == nil)
        #expect(result.session == s)
    }

    @Test("Single track in session receives the waypoint")
    func singleTrack() {
        let track = makeTrack()
        let s = GPXSession(metadata: ProjectMetadata(), tracks: [track])

        let result = PlaceWaypointOperation.apply(to: s, latitude: 45, longitude: -120)
        #expect(result.hostTrackId == track.id)
        #expect(result.session.tracks[0].waypoints.count == 1)
        #expect(result.session.tracks[0].waypoints[0].latitude == 45)
        #expect(result.session.tracks[0].waypoints[0].longitude == -120)
    }

    @Test("Master track is preferred over the first track")
    func mastersWin() {
        let firstTrack = makeTrack(name: "first")
        let masterTrack = makeTrack(name: "master", role: .master)
        let s = GPXSession(metadata: ProjectMetadata(), tracks: [firstTrack, masterTrack])

        let result = PlaceWaypointOperation.apply(to: s, latitude: 45, longitude: -120)
        #expect(result.hostTrackId == masterTrack.id)
        #expect(result.session.tracks[0].waypoints.isEmpty)
        #expect(result.session.tracks[1].waypoints.count == 1)
    }

    @Test("Falls back to first track when no master is designated")
    func fallbackToFirst() {
        let firstTrack = makeTrack(name: "first")
        let secondTrack = makeTrack(name: "second")
        let s = GPXSession(metadata: ProjectMetadata(), tracks: [firstTrack, secondTrack])

        let result = PlaceWaypointOperation.apply(to: s, latitude: 45, longitude: -120)
        #expect(result.hostTrackId == firstTrack.id)
        #expect(result.session.tracks[0].waypoints.count == 1)
        #expect(result.session.tracks[1].waypoints.isEmpty)
    }

    @Test("New waypoint has nil elevation and time, default sym 'Generic'")
    func waypointDefaults() {
        let track = makeTrack()
        let s = GPXSession(metadata: ProjectMetadata(), tracks: [track])
        let result = PlaceWaypointOperation.apply(to: s, latitude: 45, longitude: -120)
        let wp = result.session.tracks[0].waypoints[0]
        #expect(wp.elevation == nil)
        #expect(wp.time == nil)
        #expect(wp.sym == "Generic")
        #expect(wp.name == "")
    }
}
