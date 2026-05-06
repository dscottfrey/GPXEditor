// MergeTrackPickerSheet.swift
//
// Modal SwiftUI sheet for picking a source track to merge into the
// destination track.  Triggered from the Edit menu's "Merge Track
// Into…" item or the right-click context menu's same item.  The
// destination is established by the selection (the track containing
// the selected point);  this sheet picks the source — the track
// that will be absorbed.
//
// Why a sheet rather than the sidebar:  the sidebar lands at M8.
// Until then, the project has no tree-view UI to drag-and-drop
// from, and a modal picker is the simplest unambiguous path.  Once
// the sidebar lands the merge UX may evolve to a drag-target
// gesture, but the modal-sheet path will likely still be available
// from the menu for keyboard-driven workflows.
//
// Structure:
//   - Header:  "Merge Into <destination name>".
//   - List of candidate sources (every track in the project except
//     the destination), each row showing the track name.  The user
//     selects exactly one.
//   - Cancel / Merge buttons.  Merge runs an NSAlert confirmation
//     (per M6 spec);  on OK the sheet dismisses and the onCommit
//     closure fires.
//
// The confirmation step is a deliberate friction point — merge
// concatenates two tracks irreversibly except via undo, and the
// source track loses its identity entirely (id, name, role,
// recording-bytes).  The alert names both tracks explicitly so
// the user can't accidentally pick the wrong direction.

import SwiftUI
import AppKit

struct MergeTrackPickerSheet: View {

    /// Display name of the destination track (the one that survives).
    /// Used for the header and the confirmation alert text.
    let destinationName: String

    /// Candidate source tracks — every track in the project except
    /// the destination.  Pre-filtered by the caller so this view
    /// doesn't have to reach back into the session.
    let candidates: [MergeTracksRequest.Candidate]

    /// Called on OK (after confirmation) with the chosen source id.
    /// The sheet dismisses itself before this fires;  the caller
    /// doesn't need to drive dismissal independently.
    let onCommit: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var selectedSourceId: UUID? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Merge Into \(destinationName)")
                .font(.headline)

            Text("Choose a track to merge into \(destinationName).  Its segments and waypoints will be appended;  the source track will be removed.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // List with single-selection.  selectedSourceId binds
            // through the row tag.  We use a List rather than a
            // Picker so the candidates are always visible (the user
            // can scan the names without expanding a popup) and so
            // selecting a row visually persists while the user
            // reviews their choice.
            List(candidates, selection: $selectedSourceId) { candidate in
                Text(candidate.name)
                    .tag(Optional(candidate.id))
            }
            .frame(minWidth: 320, minHeight: 200)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Merge") {
                    guard let sourceId = selectedSourceId else { return }
                    guard let candidate = candidates.first(where: { $0.id == sourceId }) else { return }
                    if confirmMerge(sourceName: candidate.name) {
                        dismiss()
                        onCommit(sourceId)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedSourceId == nil)
            }
        }
        .padding(20)
        .frame(minWidth: 360)
    }

    /// Run the confirmation alert.  Returns true if the user
    /// confirmed, false if they cancelled.  The alert spells out the
    /// direction explicitly ("merge X INTO Y, X will be removed") so
    /// the user can catch a wrong-direction pick before committing.
    private func confirmMerge(sourceName: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Merge \(sourceName) into \(destinationName)?"
        alert.informativeText = "\(sourceName) will be removed.  Its segments and waypoints will be appended to \(destinationName).  This can be undone with ⌘Z."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Merge")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
