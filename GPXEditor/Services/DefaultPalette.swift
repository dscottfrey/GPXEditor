// DefaultPalette.swift
//
// The default colorblind-safe palette used to auto-assign colors to
// imported track segments.  Lives in `Services/` because it's static
// data that the importer consumes; not in `Models/` because the data
// layer should stay free of "behavior-adjacent" lookup tables.
//
// Per D-013, the default palette is Okabe-Ito — a widely-published
// colorblind-safe palette designed by Masataka Okabe and Kei Ito.  Eight
// colors that remain distinguishable across all major forms of color-
// vision deficiency (deuteranopia, protanopia, tritanopia).
//
// The palette is fully editable in the app's Settings (D-013 again);
// what's defined here is the FACTORY DEFAULT.  Once the Settings UI
// lands (M8/M10), users can override individual slots and "Restore
// Defaults" reads from this constant.
//
// Color matching is per-segment in the data model (D-013) and stored
// as hex strings (HexColor.swift); this constant returns those hex
// values directly.  No NSColor / SwiftUI Color here — Services/ stays
// platform-agnostic per CONVENTIONS.md.

import Foundation

/// The factory-default colorblind-safe palette (Okabe-Ito).  Used by
/// `TrackImporter` to assign colors to segments at import time, and by
/// the Settings UI's "Restore Defaults" affordance.
public enum DefaultPalette {

    /// The palette's eight colors in their canonical order.  Order
    /// matters because the importer cycles through them as new tracks
    /// are added — track 0 gets slot 0, track 1 gets slot 1, etc.
    /// Names in the comments below are Okabe-Ito's published labels.
    public static let colors: [HexColor] = [
        HexColor("#000000")!,  // black           (slot 0)
        HexColor("#E69F00")!,  // orange          (slot 1)
        HexColor("#56B4E9")!,  // sky blue        (slot 2)
        HexColor("#009E73")!,  // bluish green    (slot 3)
        HexColor("#F0E442")!,  // yellow          (slot 4)
        HexColor("#0072B2")!,  // blue            (slot 5)
        HexColor("#D55E00")!,  // vermillion      (slot 6)
        HexColor("#CC79A7")!,  // reddish purple  (slot 7)
    ]

    /// Return the palette color for an unbounded slot index.  Wraps
    /// around modulo `colors.count` so a project with a hundred tracks
    /// keeps producing valid colors (just repeating the palette every
    /// eight tracks).
    public static func color(at index: Int) -> HexColor {
        // Swift's % operator can return negative values for negative
        // operands; normalize to a non-negative slot via the
        // remainder-then-add-and-remainder pattern.
        let count = colors.count
        let slot = ((index % count) + count) % count
        return colors[slot]
    }
}
