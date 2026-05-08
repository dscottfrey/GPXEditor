// PinToGroundSheet.swift
//
// Modal SwiftUI sheet for M7's Pin to Ground operation.  Two-phase:
//
//   1. Ready — describe the scope ("Pin N points selected" or "Pin
//      every point of <track>") and offer Pin / Cancel buttons.  No
//      network traffic until the user clicks Pin.
//   2. Running — progress bar updates as each batch returns.  Cancel
//      button cancels the in-flight Task;  ElevationService's
//      throttled batch loop unwinds at the next await.
//
// On success the sheet dismisses and calls back into
// SessionViewModel.applyPinToGround with the parallel elevations.
// On error the sheet stays open in an "error" state with a clear
// message and a Close button.  On Cancel the sheet dismisses without
// applying anything.
//
// Per CONVENTIONS.md "Direct manipulation, minimal modal dialogs":
// the dialog earns its place because Pin to Ground takes ≥1 second
// per ≤100-point batch and the user wants visible progress + the
// option to cancel.  D-018-style "do it and undo if wrong" doesn't
// fit when the operation is rate-limited and slow.
//
// The sheet runs the async ElevationService loop in-place — progress
// state is sheet-local, and threading through SessionViewModel would
// add coupling without simplifying anything.  The view model is the
// commit point only;  the network-driven work lives here.

import SwiftUI

struct PinToGroundSheet: View {

    // MARK: - Inputs

    /// The request that triggered the sheet.  Carries the scope
    /// description and the per-point query payload.
    let request: PinToGroundRequest

    /// Called on success with the parallel optional elevations.
    /// SessionViewModel.applyPinToGround handles the commit + undo.
    /// The sheet dismisses itself before this fires.
    let onCommit: ([Selection.PointReference], [Double?]) -> Void

    @Environment(\.dismiss) private var dismiss

    // MARK: - State

    @State private var phase: Phase = .ready
    @State private var progressCompleted: Int = 0
    @State private var errorMessage: String? = nil
    @State private var fetchTask: Task<Void, Never>? = nil

    /// Sheet phase machine.  `ready` → user clicks Pin → `running` →
    /// either success (dismiss + onCommit) or error (linger in
    /// `error` for the user to read the message).
    private enum Phase {
        case ready
        case running
        case error
    }

    // MARK: - View

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Pin to Ground")
                .font(.headline)

            Text(scopeDescription)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("Replaces each point's recorded elevation with the DEM elevation from OpenTopoData's mapzen dataset.  Lat / lon and timestamps are preserved.  ⌘Z reverts the operation.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            switch phase {
            case .ready:
                readyControls
            case .running:
                runningControls
            case .error:
                errorControls
            }
        }
        .padding(20)
        .frame(minWidth: 420)
        .onDisappear {
            // Defensive — if the sheet dismisses for any reason
            // (Escape, parent unmounting), make sure the in-flight
            // Task is cancelled so we don't leak network traffic.
            fetchTask?.cancel()
        }
    }

    // MARK: - Phase-specific subviews

    @ViewBuilder
    private var readyControls: some View {
        HStack {
            Spacer()
            Button("Cancel", role: .cancel) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Button("Pin to Ground") {
                start()
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    @ViewBuilder
    private var runningControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProgressView(
                value: Double(progressCompleted),
                total: Double(request.queries.count)
            )
            Text("\(progressCompleted) of \(request.queries.count) points pinned")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") {
                    fetchTask?.cancel()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
    }

    @ViewBuilder
    private var errorControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(errorMessage ?? "Pin to Ground could not complete.")
                .font(.callout)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - Computed copy

    /// Human-readable scope description used as the sheet's
    /// subheadline.  Localizes the user's actual situation:  "247
    /// selected points" vs "every point of 'Morning Hike'."
    private var scopeDescription: String {
        switch request.scope {
        case .selection(let count):
            return "\(count) selected point\(count == 1 ? "" : "s")"
        case .wholeTrack(let name, let count):
            return "Every point (\(count)) of track '\(name)'"
        }
    }

    // MARK: - Async driver

    /// Kick off the ElevationService loop.  Runs as a Task captured
    /// in `fetchTask` so the user's Cancel button can cancel it;  the
    /// Task itself is structured concurrency, so cancellation
    /// propagates through every `await`.
    private func start() {
        phase = .running
        progressCompleted = 0

        let queries = request.queries.map {
            ElevationQuery(latitude: $0.latitude, longitude: $0.longitude)
        }
        let references = request.queries.map(\.reference)
        let onCommit = self.onCommit  // capture before the Task closes over self

        fetchTask = Task {
            // ElevationService is an actor;  one shared instance is
            // fine for the whole loop (the rate-limiter state lives
            // there, so subsequent batches throttle correctly).
            let service = ElevationService()
            let batches = ElevationService.makeBatches(of: queries)
            var collected: [Double?] = []
            collected.reserveCapacity(queries.count)

            do {
                for batch in batches {
                    // Cancellation check at the boundary so a Cancel
                    // tap during a sleep stops the next batch from
                    // even starting.
                    try Task.checkCancellation()
                    let batchResult = try await service.fetchElevations(for: batch)
                    collected.append(contentsOf: batchResult)
                    // Update UI on the main actor.  This is the only
                    // hop required — SwiftUI @State is main-actor.
                    await MainActor.run {
                        progressCompleted = collected.count
                    }
                }
            } catch is CancellationError {
                // User-initiated cancel.  Dismiss without committing.
                await MainActor.run {
                    dismiss()
                }
                return
            } catch {
                // Real failure — surface as an error phase.
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    phase = .error
                }
                return
            }

            // All batches completed successfully.  Commit on the
            // main actor and dismiss.
            await MainActor.run {
                onCommit(references, collected)
                dismiss()
            }
        }
    }
}
