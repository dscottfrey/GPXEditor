// TrackRole.swift
//
// The role a Track plays in the master/subsidiary editing model (D-011).
// Exactly one Track in a project may be tagged `.master`; any number may be
// tagged `.subsidiary`.  Tracks with no role at all (i.e. `Track.role == nil`)
// are "unaffiliated" — present in the project for display or comparison but
// not part of the master/subsidiary group that the Average brush operates
// on.
//
// We deliberately don't include an `.unaffiliated` enum case.  An optional
// `TrackRole?` of `nil` is the natural representation: it means the Track
// has no role.  Adding a third case would force every consumer to handle
// the "unaffiliated" case explicitly, when in practice "no role" is the
// uniform default that the role-aware code paths can simply ignore.
//
// See D-011 for the master/subsidiary semantics, D-012 for how the master
// is the canonical export source, and D-016 for how the Average brush
// reads from subsidiaries and writes into the master.

import Foundation

/// The role a Track plays in the master/subsidiary editing model.  A
/// Track without a role uses `nil` rather than a third enum case — see
/// file header.
public enum TrackRole: String, Codable, CaseIterable, Sendable {
    /// The canonical reference track for the project.  Exactly one Track
    /// per project carries this role.  D-012 export emits only this track.
    case master

    /// An input track linked to the master.  The Average brush reads from
    /// subsidiaries to refine the master (D-016); subsidiaries are not
    /// consumed by the operation and remain available for further strokes.
    case subsidiary
}
