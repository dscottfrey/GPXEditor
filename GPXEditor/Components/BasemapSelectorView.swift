// BasemapSelectorView.swift
//
// SwiftUI overlay control for picking a basemap.  Sits on top of the
// MapView (typically pinned to a corner) — it is a Component, not a
// screen, per CONVENTIONS.md "File organization."
//
// The control is a small button showing the active basemap's display
// name;  tapping it opens a popover with the full catalog as a list,
// the active item checkmarked.  Selecting an item updates the
// document's `selectedBasemapId`, which propagates through SwiftUI's
// observation system to MapView.Coordinator, which emits a
// `set_basemap` bridge message.
//
// No thumbnails in v1 (D-016 / Occam's Razor: thumbnails would require
// pre-rendered tile images, an entire image pipeline, and offline
// storage for what is fundamentally a one-time selection).  Display
// name plus attribution preview is enough for the user to recognise
// each entry.

import SwiftUI

/// Compact basemap-picker control.  Designed to be placed as a SwiftUI
/// overlay above the MapView (typically top-right) using `.overlay(...)`.
struct BasemapSelectorView: View {

    /// Two-way binding to the document.  Writing
    /// `document.session.selectedBasemapId` triggers SwiftUI's autosave
    /// machinery (FileDocument's contract) and propagates the change to
    /// MapView via the document binding it shares.
    @Binding var document: GPXEditorDocument

    /// Whether the popover is open.  Local to this view since the open
    /// state has no meaning outside the picker.
    @State private var isPopoverPresented: Bool = false

    var body: some View {
        Button {
            isPopoverPresented.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "map")
                Text(activeBasemapDisplayName)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            // Translucent material so the basemap shows through subtly
            // while remaining legible — applied as a backstop in case
            // the surrounding MapView is showing a dark satellite tile.
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPopoverPresented, arrowEdge: .top) {
            popoverContents
                .padding(.vertical, 4)
        }
    }

    /// The popover body — a list of catalog entries, each a button that
    /// updates the active basemap and dismisses the popover.
    private var popoverContents: some View {
        // Frame width is fixed so the popover doesn't jitter as
        // attribution strings of different lengths render.  Height
        // grows with the catalog; v1's catalog is small enough not to
        // need scrolling.
        VStack(alignment: .leading, spacing: 0) {
            ForEach(BasemapCatalog.all) { basemap in
                Button {
                    document.session.selectedBasemapId = basemap.id
                    isPopoverPresented = false
                } label: {
                    basemapRow(for: basemap)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: 280)
    }

    /// One row in the popover.  Two-line layout:  display name + a
    /// muted attribution preview.  Active basemap shows a checkmark.
    private func basemapRow(for basemap: Basemap) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(basemap.displayName)
                    .font(.body)
                Text(basemap.attribution)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            if basemap.id == document.session.selectedBasemapId {
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        // Hover highlight is applied via .contentShape so the whole
        // row is the click target, not just the text.
        .contentShape(Rectangle())
    }

    /// Display name of the currently-active basemap.  Falls back to
    /// the catalog default's name if the persisted id doesn't match
    /// any catalog entry — matches MapView.Coordinator's fallback so
    /// the UI shows the same "what's actually being rendered" answer.
    private var activeBasemapDisplayName: String {
        let id = document.session.selectedBasemapId
        return BasemapCatalog.basemap(forId: id)?.displayName
            ?? BasemapCatalog.defaultBasemap.displayName
    }
}
