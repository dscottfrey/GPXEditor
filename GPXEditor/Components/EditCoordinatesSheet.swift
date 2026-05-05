// EditCoordinatesSheet.swift
//
// Modal SwiftUI sheet for editing a single track point's lat / lon
// to precise values.  Triggered from the right-click context menu's
// "Edit Coordinates…" item (M5 follow-up).
//
// On OK, the parent view calls SessionViewModel.applyMovePoint with
// the entered values.  Cancel discards the edit.  We don't track
// elevation or timestamp here — those have separate per-point edit
// affordances on the Inspector at M8;  M5's "Edit Coordinates" is
// scoped to lat/lon as the spec named.
//
// Validation:  parse Double from text fields, range-check against
// WGS84 bounds (lat -90..90, lon -180..180).  Out-of-range values
// disable the OK button and show an inline error.  No silent
// clamping — we make the user fix the input rather than fabricate
// a "close enough" value (the same data-integrity stance
// AddPointOnLineOperation takes when refusing to fabricate
// elevation when neither anchor has it).

import SwiftUI

struct EditCoordinatesSheet: View {

    /// Initial latitude, displayed and pre-filled in the lat field.
    let initialLatitude: Double

    /// Initial longitude, displayed and pre-filled in the lon field.
    let initialLongitude: Double

    /// Called on OK with the parsed (latitude, longitude).  The sheet
    /// dismisses itself before this fires;  the caller doesn't need
    /// to drive dismissal independently.
    let onCommit: (Double, Double) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var latText: String = ""
    @State private var lonText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Coordinates")
                .font(.headline)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Latitude:")
                    TextField("Latitude", text: $latText)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 200)
                }
                GridRow {
                    Text("Longitude:")
                    TextField("Longitude", text: $lonText)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 200)
                }
            }

            // Show a parse / range error inline.  The OK button's
            // .disabled state is the primary cue;  this text is the
            // explanatory secondary cue per CONVENTIONS.md "Error
            // messages describe, don't accuse" — names what was
            // expected, what was found.
            if let error = parseError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("OK") {
                    if let (lat, lon) = parsedCoordinates() {
                        dismiss()
                        onCommit(lat, lon)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(parsedCoordinates() == nil)
            }
        }
        .padding(20)
        .frame(minWidth: 320)
        .onAppear {
            // Pre-fill with the initial values formatted to a sensible
            // precision (~1 cm at the equator with 7 decimal places).
            latText = String(format: "%.7f", initialLatitude)
            lonText = String(format: "%.7f", initialLongitude)
        }
    }

    /// Parse and range-check the lat/lon fields.  Returns nil if
    /// either field fails to parse as a Double, or if the value is
    /// outside WGS84 bounds.  Driving both the OK button enable state
    /// and the inline error message from the same parse pass means
    /// the two cues stay consistent automatically.
    private func parsedCoordinates() -> (Double, Double)? {
        guard let lat = Double(latText), lat >= -90, lat <= 90 else { return nil }
        guard let lon = Double(lonText), lon >= -180, lon <= 180 else { return nil }
        return (lat, lon)
    }

    /// Inline error message if the parse fails.  Nil when both fields
    /// are valid (the OK button enables and no message shows).
    private var parseError: String? {
        if Double(latText) == nil {
            return "Latitude isn't a number — expected a value like 45.123456."
        }
        if let lat = Double(latText), lat < -90 || lat > 90 {
            return "Latitude is out of range — expected a value between -90 and 90."
        }
        if Double(lonText) == nil {
            return "Longitude isn't a number — expected a value like -121.987654."
        }
        if let lon = Double(lonText), lon < -180 || lon > 180 {
            return "Longitude is out of range — expected a value between -180 and 180."
        }
        return nil
    }
}
