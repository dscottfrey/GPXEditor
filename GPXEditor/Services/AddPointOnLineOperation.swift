// AddPointOnLineOperation.swift
//
// Pure-function "insert a new track point between two existing points"
// — the Swift side of M5's click-on-line behaviour.  JS detects a
// click on a polyline (not on a vertex), figures out which (i, i+1)
// sub-segment the click hit and where on that sub-segment the click
// projection landed, and posts an `add_point_on_line` bridge message
// with `after_index = i` plus the projected lat/lon.  Swift inserts
// the new point at index i+1 (just after the named anchor).
//
// New point's elevation:  D-012 already says exports drop per-point
// time, but in-memory we'd ideally preserve some elevation for the
// new point.  Two choices:  (1) leave elevation nil (genuinely
// unknown), or (2) interpolate between the two anchor points.
// Linear interpolation is the obvious "not making things up" choice
// — the new point sits geographically between the anchors, so its
// expected elevation is the linear average of theirs.  When either
// anchor lacks elevation, the new point gets nil too.  Same for time
// — interpolated when both anchors have a timestamp;  nil otherwise.
//
// Per CONVENTIONS.md "platform-agnostic data layer," Foundation only.

import Foundation

public enum AddPointOnLineOperation {

    /// Insert a new TrackPoint into a segment.  The new point is
    /// inserted at index `afterIndex + 1` (immediately after the named
    /// anchor).  Elevation and timestamp are linearly interpolated
    /// between `points[afterIndex]` and `points[afterIndex + 1]` when
    /// both anchors have those values;  nil otherwise.
    ///
    /// Edge case:  `afterIndex == -1` inserts at the very start of the
    /// segment (per the Docs/02 schema).  In that case the new point
    /// has no "before" anchor — elevation and time are taken from the
    /// first existing point, since there's no second anchor to
    /// interpolate against.  Symmetric edge:  `afterIndex == count - 1`
    /// inserts at the very end;  takes from the last point.
    public static func apply(
        to session: GPXSession,
        trackId: UUID,
        segmentId: UUID,
        afterIndex: Int,
        latitude: Double,
        longitude: Double
    ) -> (session: GPXSession, touched: [TouchedSegment]) {

        guard let trackIndex = session.tracks.firstIndex(where: { $0.id == trackId }) else {
            return (session, [])
        }
        var newSession = session
        var track = newSession.tracks[trackIndex]
        guard let segmentIndex = track.segments.firstIndex(where: { $0.id == segmentId }) else {
            return (session, [])
        }
        var segment = track.segments[segmentIndex]

        // Validate afterIndex.  Acceptable range is [-1, count - 1]
        // inclusive;  -1 means "insert at the very front."
        guard afterIndex >= -1, afterIndex < segment.points.count else {
            return (session, [])
        }
        // We need at least one existing point to interpolate from;  an
        // empty segment can't be inserted-into via this op (the wire
        // format expects a known anchor index).  Empty-segment insert
        // is a M-future affordance if it earns one.
        guard !segment.points.isEmpty else {
            return (session, [])
        }

        let beforeAnchor: TrackPoint? = afterIndex >= 0 ? segment.points[afterIndex] : nil
        let afterAnchor: TrackPoint? = (afterIndex + 1 < segment.points.count)
            ? segment.points[afterIndex + 1]
            : nil

        let newPoint = TrackPoint(
            latitude: latitude,
            longitude: longitude,
            elevation: interpolatedElevation(before: beforeAnchor, after: afterAnchor),
            time: interpolatedTime(before: beforeAnchor, after: afterAnchor)
        )

        let insertionIndex = afterIndex + 1
        segment.points.insert(newPoint, at: insertionIndex)
        track.segments[segmentIndex] = segment
        newSession.tracks[trackIndex] = track

        return (newSession, [TouchedSegment(trackId: trackId, segmentId: segmentId)])
    }

    /// Mid-point linear interpolation when both anchors have elevation.
    /// Falls back to whichever single anchor has it;  nil when neither
    /// does.  We don't fabricate an elevation when the data doesn't
    /// support one — better to leave the field nil than introduce a
    /// fake number that downstream code (Stats, export) could mistake
    /// for a real reading.
    private static func interpolatedElevation(
        before: TrackPoint?,
        after: TrackPoint?
    ) -> Double? {
        switch (before?.elevation, after?.elevation) {
        case let (b?, a?): return (b + a) / 2.0
        case let (b?, nil): return b
        case let (nil, a?): return a
        case (nil, nil):   return nil
        }
    }

    /// Mid-point linear interpolation between two timestamps;  same
    /// fallback rules as elevation.
    private static func interpolatedTime(
        before: TrackPoint?,
        after: TrackPoint?
    ) -> Date? {
        switch (before?.time, after?.time) {
        case let (b?, a?):
            let mid = b.timeIntervalSinceReferenceDate
                + (a.timeIntervalSinceReferenceDate - b.timeIntervalSinceReferenceDate) / 2.0
            return Date(timeIntervalSinceReferenceDate: mid)
        case let (b?, nil): return b
        case let (nil, a?): return a
        case (nil, nil):    return nil
        }
    }

    /// Mirror of the other operations' TouchedSegment.
    public struct TouchedSegment: Equatable, Sendable {
        public let trackId: UUID
        public let segmentId: UUID

        public init(trackId: UUID, segmentId: UUID) {
            self.trackId = trackId
            self.segmentId = segmentId
        }
    }
}
