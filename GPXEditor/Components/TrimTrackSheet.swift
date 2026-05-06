// TrimTrackSheet.swift
//
// Modal SwiftUI sheet for D-018's Trim Track dialog.  Two optional
// sections — "Trim start at time" and "Trim end at time" — each
// with a checkbox and a date picker.  Default values are the
// track's actual first and last point times.  As the user adjusts
// any of the four controls (two checkboxes, two pickers) the
// preview overlay on the map updates to show the points that would
// be removed in red.  OK commits;  Cancel discards.
//
// Bound semantics match TrimTrackOperation:
//   - Trim start at <X>:  drop every point whose timestamp is
//     STRICTLY less than X.  X itself stays.
//   - Trim end at <Y>:  drop every point whose timestamp is
//     STRICTLY greater than Y.  Y itself stays.
//
// Validation:
//   - If both checkboxes are off, OK is a no-op (no preview, no
//     undo entry).  We disable OK in this case as a courtesy
//     rather than letting the user click into nothing.
//   - If start > end (when both enabled), every point is dropped.
//     We surface this with an inline note but don't disable OK —
//     "trim everything" is a valid (if drastic) intent and undo
//     recovers if it was a mistake.
//
// The dialog wires preview-clear into onDisappear so closing the
// sheet (any way:  OK, Cancel, dismissal via Escape) tears down
// the preview.

import SwiftUI

struct TrimTrackSheet: View {

    /// Display name for the dialog header.
    let trackName: String

    /// The track's full timestamp range, used to bound the date
    /// pickers and to seed the default values.
    let timestampRange: ClosedRange<Date>

    /// Called whenever any control changes.  The view model wraps
    /// this into a TrimTrackOperation.pointsToRemove call and
    /// publishes the result to drive the live preview.
    let onPreview: (Date?, Date?) -> Void

    /// Called on OK with the user's final bounds.  The sheet
    /// dismisses itself before this fires.
    let onCommit: (Date?, Date?) -> Void

    /// Called on dismissal (any path).  Used to clear the preview
    /// overlay.  Wired via .onDisappear so it fires regardless of
    /// how the sheet closes.
    let onDismiss: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var trimStartEnabled: Bool = false
    @State private var trimEndEnabled: Bool = false
    @State private var startDate: Date
    @State private var endDate: Date

    init(
        trackName: String,
        timestampRange: ClosedRange<Date>,
        onPreview: @escaping (Date?, Date?) -> Void,
        onCommit: @escaping (Date?, Date?) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.trackName = trackName
        self.timestampRange = timestampRange
        self.onPreview = onPreview
        self.onCommit = onCommit
        self.onDismiss = onDismiss
        // Pre-fill with the track's actual first and last point
        // times.  The pickers' .in: range constrains them to stay
        // within the track's bounds.
        _startDate = State(initialValue: timestampRange.lowerBound)
        _endDate = State(initialValue: timestampRange.upperBound)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Trim Track")
                .font(.headline)
            Text(trackName)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Trim start at:", isOn: $trimStartEnabled)
                    DatePicker(
                        "",
                        selection: $startDate,
                        in: timestampRange,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .labelsHidden()
                    .disabled(!trimStartEnabled)
                }
                .padding(8)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Trim end at:", isOn: $trimEndEnabled)
                    DatePicker(
                        "",
                        selection: $endDate,
                        in: timestampRange,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .labelsHidden()
                    .disabled(!trimEndEnabled)
                }
                .padding(8)
            }

            // Direction warning (if start > end with both enabled).
            // Inline note rather than blocking — "trim everything" is
            // a valid intent.
            if trimStartEnabled && trimEndEnabled && startDate > endDate {
                Text("Start is later than end — every point will be removed.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Trim") {
                    dismiss()
                    onCommit(activeStart(), activeEnd())
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!trimStartEnabled && !trimEndEnabled)
            }
        }
        .padding(20)
        .frame(minWidth: 400)
        // Preview is recomputed any time the bound state changes.
        // .onAppear seeds the initial preview (which will be empty
        // because both checkboxes are off);  the .onChange handlers
        // re-fire the preview on any adjustment.
        .onAppear {
            onPreview(activeStart(), activeEnd())
        }
        .onChange(of: trimStartEnabled) { _, _ in onPreview(activeStart(), activeEnd()) }
        .onChange(of: trimEndEnabled)   { _, _ in onPreview(activeStart(), activeEnd()) }
        .onChange(of: startDate)        { _, _ in onPreview(activeStart(), activeEnd()) }
        .onChange(of: endDate)          { _, _ in onPreview(activeStart(), activeEnd()) }
        .onDisappear {
            onDismiss()
        }
    }

    private func activeStart() -> Date? {
        trimStartEnabled ? startDate : nil
    }
    private func activeEnd() -> Date? {
        trimEndEnabled ? endDate : nil
    }
}
