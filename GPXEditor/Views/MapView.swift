// MapView.swift
//
// SwiftUI NSViewRepresentable wrapping the WKWebView that hosts Leaflet
// and editor.js.  The map view is the primary editing surface — every
// brush stroke, every selection, every direct-manipulation gesture
// happens inside this WebView.
//
// Configuration applied to the WebView is dictated by Docs/02_MAP_AND_BRIDGE.md
// "WKWebView setup" — every non-default setting there is reproduced here
// with the rationale visible at the call site.  When that doc and this
// file disagree, this file is wrong;  realign rather than re-litigate.
//
// MapBridge ownership lives in the Coordinator.  SwiftUI calls
// `makeCoordinator()` once per representable instance;  the coordinator
// holds the bridge and the cached "last applied" snapshot of document
// state so `updateNSView(_:context:)` can decide whether to send fresh
// `set_basemap` / `load_session` messages.
//
// At M2 the view reads the document binding for `selectedBasemapId` and
// the tracks list;  it does not yet write back to it (the basemap
// selector mutates the binding directly via SwiftUI's standard pattern,
// and viewport-write-back is M8 territory).  The coordinator's job is
// to translate document changes into bridge messages.

import SwiftUI
import WebKit
import os

/// The Leaflet-based map editor surface.  Embedded in ContentView (M2)
/// and eventually in the split-view layout (M8).  The Binding to the
/// document is two-way because future milestones write back through it
/// (basemap selection persists to the document).
struct MapView: NSViewRepresentable {

    /// Two-way binding to the document so the coordinator can react to
    /// document changes (basemap-id changed externally, tracks added)
    /// and write back when the user picks a basemap from the selector.
    @Binding var document: GPXEditorDocument

    /// Per-window editing-state holder.  M3 introduces this:  the
    /// selection and active tool live here, observed by SwiftUI so
    /// updates flow through updateNSView and into the bridge as
    /// `highlight_selection` and `set_tool` messages.
    @ObservedObject var sessionVM: SessionViewModel

    func makeCoordinator() -> Coordinator {
        Coordinator(documentBinding: $document)
    }

    func makeNSView(context: Context) -> WKWebView {
        // Construct configuration first so we can attach the rule list
        // and the script message handler before the WebView loads.
        let configuration = WKWebViewConfiguration()

        // JavaScript on, no auto-window-opening.  The deprecated
        // WKPreferences.javaScriptEnabled is replaced on macOS 14+ by
        // defaultWebpagePreferences.allowsContentJavaScript;  D-006 pins
        // us to that floor so we use the modern API directly.
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false

        // Attach the bridge:  it adds itself as the gpxBridge script
        // message handler on the configuration's user content controller
        // so JS->Swift messages flow as soon as editor.js sends them.
        let bridge = context.coordinator.bridge
        // Hold a reference to the configuration's UCC so attach can use
        // it when it gets the WebView reference back.
        // Actually:  bridge.attach takes the WebView — we'll call it
        // after constructing the WebView, but the script message handler
        // must be registered before the WebView loads any content.
        // Workaround:  register the proxy here directly, and have
        // MapBridge.attach do the WebView reference binding only.
        // Simpler:  construct the WebView first, then attach.

        // Construct the WebView with this configuration.  Note no
        // back-forward gestures, no link preview — see Docs/02 for why.
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false

        // App-identifying User-Agent per SECURITY.md "Identifying
        // User-Agent."  Tile-server operators (especially the OSMF
        // tile usage policy that governs OSM, OpenTopoMap, and CyclOSM)
        // require an identifying string — Safari's default UA conceals
        // us from operators.
        webView.customUserAgent = userAgentString()

        // Developer Tools (Inspect Element + Web Inspector) only in
        // Debug builds.  Release ships with developer tools off because
        // they are an unnecessary surface in shipped software.
        #if DEBUG
        webView.configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        #endif

        // Navigation guard:  allow the initial file:// load of
        // index.html, deny everything else.  Prevents misbehaving JS
        // from navigating away from the editor.
        webView.navigationDelegate = context.coordinator

        // Now that the WebView exists, attach the bridge.  This
        // registers the script message handler on the WebView's
        // configuration's user content controller.
        bridge.attach(to: webView)

        // Hold a weak reference on the coordinator so the context-menu
        // handler (M5 follow-up) can call NSMenu.popUp(in: webView)
        // without re-fetching the WebView from the bridge.
        context.coordinator.webView = webView

        // Apply the compiled WKContentRuleList asynchronously.  The
        // rule list compile is fast (cached after first build) but is
        // an async API;  we kick it off and have the completion attach
        // the rule list before initiating the index.html load, so the
        // first tile fetch can't escape the rule list.
        Task { @MainActor in
            do {
                let ruleList = try await ContentRuleListBuilder.compile()
                webView.configuration.userContentController.add(ruleList)
                // Now safe to load index.html — the rule list is in
                // place, so any tile fetch from editor.js's first
                // set_basemap will be matched against the allow-list.
                loadIndexHTML(into: webView, coordinator: context.coordinator)
            } catch {
                // Compilation failed.  Per CONVENTIONS.md "Nothing
                // fails silently," surface this as an alert — without
                // the rule list the network allow-list is unenforced
                // at the WebKit layer, which violates SECURITY.md.
                context.coordinator.reportRuleListFailure(error: error)
            }
        }

        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        // SwiftUI calls this whenever the surrounding state may have
        // changed.  The coordinator owns the diff state — for each kind
        // of state (basemap, tracks, selection, tool) it tracks the
        // last-applied value and sends a bridge message only when the
        // current value differs.  This keeps updateNSView idempotent
        // even when SwiftUI re-runs it for unrelated reasons.
        context.coordinator.documentChanged(to: document, sessionVM: sessionVM)
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        // Called when SwiftUI tears down the representable.  Detach the
        // bridge so the WebView/handler retain cycle is broken;  WebKit
        // does not auto-clean script message handlers.
        coordinator.bridge.detach()
    }

    // MARK: - Helpers

    /// Construct the User-Agent per SECURITY.md "Identifying User-Agent".
    /// Form:  GPXeditor/<version> (+<repository URL>).  Version comes
    /// from BuildInfo.  Repo URL is the project's GitHub URL — fixed in
    /// code rather than fetched at runtime so it ships unambiguously.
    private func userAgentString() -> String {
        // BuildInfo.displayString is "<timestamp> · <sha>+/-".  For the
        // UA we want a more conventional version-ish string;  the SHA
        // suffix is fine because it tells the operator which build
        // they're talking to.
        let identifier = "\(BuildInfo.gitSHA)\(BuildInfo.isDirty ? "+" : "")"
        return "GPXeditor/\(identifier) (+https://github.com/dscottfrey/GPXEditor)"
    }

    /// Load the bundled `index.html`.  Tries the WebResources/ subdirectory
    /// first (folder-reference layout) then falls back to flat (synchronized
    /// group default).  See Docs/02_MAP_AND_BRIDGE.md "WKWebView setup" for
    /// the access-scope reasoning.
    private func loadIndexHTML(into webView: WKWebView, coordinator: Coordinator) {
        let bundle = Bundle.main
        let indexURL: URL? = bundle.url(
            forResource: "index",
            withExtension: "html",
            subdirectory: "WebResources"
        ) ?? bundle.url(forResource: "index", withExtension: "html")

        guard let indexURL = indexURL else {
            coordinator.reportIndexHTMLMissing()
            return
        }

        // Access scope is the parent of index.html — in the
        // folder-reference layout that's WebResources/; in the flat
        // layout it's Contents/Resources/.  Either way we don't grant
        // read access outside the bundle, so a misbehaving editor.js
        // cannot reach the rest of the filesystem.
        let accessScope = indexURL.deletingLastPathComponent()
        webView.loadFileURL(indexURL, allowingReadAccessTo: accessScope)
    }
}

// MARK: - Coordinator

extension MapView {

    /// SwiftUI Coordinator.  Owns the bridge, the navigation delegate
    /// behavior, and the cached snapshot of last-applied document state
    /// for diffing.  Reference type because it must be shared across
    /// `makeNSView`, `updateNSView`, and `dismantleNSView` calls.
    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {

        private let logger = Logger(subsystem: "com.gpxeditor.app.MapBridge", category: "mapview")

        let bridge: MapBridge

        /// Two-way binding to the document.  Held so the coordinator
        /// can write back basemap-selection changes (and viewport,
        /// later milestones).
        private let documentBinding: Binding<GPXEditorDocument>

        /// The basemap id we last sent to JS.  Used to skip redundant
        /// `set_basemap` messages when SwiftUI re-runs updateNSView for
        /// unrelated reasons.
        private var lastAppliedBasemapId: String?

        /// Snapshot of tracks last sent to JS.  Used to detect what
        /// changed between updateNSView calls so update_tracks only
        /// includes tracks whose contents actually shifted.  The full
        /// initial set is sent via load_session;  subsequent diffs go
        /// through update_tracks.
        private var lastSentTracks: [Track] = []

        /// The selection last sent via `highlight_selection`.  A
        /// selection equal to this is not re-broadcast.
        private var lastSentSelection: Selection = Selection()

        /// The tool last sent via `set_tool`.  Same gating rule.
        private var lastSentTool: EditingTool?

        /// The trim preview state last sent.  Tracks whether the prior
        /// broadcast was a preview_trim (with the Equatable groups
        /// payload) or a clear_trim_preview, so transitions don't
        /// double-send.  nil = last broadcast was clear (or nothing
        /// was ever sent).
        private var lastSentTrimPreview: [TrimTrackOperation.PreviewGroup]?

        /// The id of the last zoom_to_bounds we dispatched (M7.5).
        /// SessionViewModel mints a fresh UUID per `zoomToTrack` call,
        /// so a never-seen-before id means "user just requested another
        /// zoom" and we send it through the bridge.  nil = we've never
        /// dispatched a zoom yet.
        private var lastSentZoomBoundsId: UUID?

        /// Weak reference to the active SessionViewModel.  Held so the
        /// dispatcher's onPointsSelected callback (registered once at
        /// init time) can route the parsed payload into the
        /// SessionViewModel's selection state regardless of which
        /// updateNSView call is currently in flight.
        private weak var sessionVM: SessionViewModel?

        /// Weak reference to the WebView the coordinator is bound to.
        /// Set during makeNSView after the WebView is constructed.
        /// The right-click context-menu handler (M5 follow-up) needs
        /// the WebView reference to anchor `NSMenu.popUp(in:)` to it.
        weak var webView: WKWebView?

        /// Whether the JS side has reported `ready`.  Until then,
        /// outbound messages are buffered (coordinator holds a snapshot
        /// of the latest desired state and sends it once ready arrives).
        private var jsReady: Bool = false

        init(documentBinding: Binding<GPXEditorDocument>) {
            self.documentBinding = documentBinding
            self.bridge = MapBridge()
            super.init()
            // Wire up dispatcher callbacks once.  The bridge stays for
            // the coordinator's lifetime;  callbacks reference self
            // weakly so the dispatcher's retained closures don't form
            // a cycle with the coordinator.
            self.bridge.dispatcher.onReady = { [weak self] _ in
                self?.handleJSReady()
            }
            self.bridge.dispatcher.onPointsSelected = { [weak self] payload in
                self?.handlePointsSelected(payload)
            }
            self.bridge.dispatcher.onApplyBrush = { [weak self] payload in
                self?.handleApplyBrush(payload)
            }
            self.bridge.dispatcher.onMovePoint = { [weak self] payload in
                self?.handleMovePoint(payload)
            }
            self.bridge.dispatcher.onAddPointOnLine = { [weak self] payload in
                self?.handleAddPointOnLine(payload)
            }
            self.bridge.dispatcher.onRequestContextMenu = { [weak self] payload in
                self?.handleRequestContextMenu(payload)
            }
        }

        /// Called by MapView.updateNSView when SwiftUI propagates a
        /// document or session-VM change.  We diff against last-applied
        /// state and send only the messages whose subject changed.
        func documentChanged(to newDocument: GPXEditorDocument, sessionVM: SessionViewModel) {
            // Hold onto the sessionVM so dispatcher callbacks can find
            // it.  Weak ref — ownership is the SwiftUI view tree.
            self.sessionVM = sessionVM

            // If JS isn't ready yet, defer — handleJSReady will pick up
            // the latest state and send everything in one go.
            guard jsReady else { return }

            applyBasemapIfChanged(in: newDocument)
            applyTracksIfChanged(in: newDocument)
            applySelectionIfChanged(sessionVM.selection)
            applyToolIfChanged(sessionVM.activeTool)
            applyTrimPreviewIfChanged(sessionVM.trimPreviewGroups)
            applyZoomTriggerIfChanged(sessionVM.zoomBoundsTrigger)
        }

        /// Called by the bridge's dispatcher when JS sends `ready`.
        /// Sends the initial `set_basemap`, `load_session`, and `set_tool`
        /// so the WebView paints the document state with the right tool
        /// active.
        private func handleJSReady() {
            jsReady = true
            let document = documentBinding.wrappedValue
            applyBasemapIfChanged(in: document)
            sendLoadSession(document: document)
            // After load_session, the lastSentTracks snapshot is the
            // full list — subsequent updates flow through update_tracks.
            lastSentTracks = document.session.tracks

            // Sync tool + selection with whatever the session VM holds.
            if let sessionVM = sessionVM {
                applyToolIfChanged(sessionVM.activeTool)
                applySelectionIfChanged(sessionVM.selection)
            }
        }

        /// Send `set_basemap` if the document's `selectedBasemapId`
        /// differs from the last value we sent.  Falls back to the
        /// catalog default if the persisted id doesn't match any entry
        /// (graceful per GPXSession.swift's contract).
        private func applyBasemapIfChanged(in document: GPXEditorDocument) {
            let desiredId = document.session.selectedBasemapId
            if desiredId == lastAppliedBasemapId { return }

            let basemap = BasemapCatalog.basemap(forId: desiredId)
                ?? BasemapCatalog.defaultBasemap
            if basemap.id != desiredId {
                logger.warning("Persisted basemap id `\(desiredId, privacy: .public)` not in catalog; falling back to default `\(basemap.id, privacy: .public)`")
            }

            bridge.send(.setBasemap(SetBasemapPayload(from: basemap)))
            lastAppliedBasemapId = basemap.id
        }

        private func sendLoadSession(document: GPXEditorDocument) {
            let payload = LoadSessionPayload(session: document.session)
            bridge.send(.loadSession(payload))
        }

        /// Detect track-level changes since the last applied snapshot
        /// and send `update_tracks` for adds/modifies plus
        /// `remove_tracks` for departed tracks.  The snapshot is
        /// updated atomically on each call so the next diff is
        /// against the just-sent state.
        ///
        /// Wired at M3 for add/modify;  M6 added the removal path
        /// alongside Merge Tracks (the first operation that removes a
        /// track from the session).  Without removal handling, JS
        /// would keep stale layers around for the merge's source
        /// track until the next load_session — visually invisible
        /// when the source and destination overlap, confusing when
        /// they don't.
        private func applyTracksIfChanged(in document: GPXEditorDocument) {
            let newTracks = document.session.tracks
            let oldByID = Dictionary(uniqueKeysWithValues: lastSentTracks.map { ($0.id, $0) })
            let newIDs = Set(newTracks.map { $0.id })

            var changed: [Track] = []
            for track in newTracks {
                if oldByID[track.id] != track {
                    changed.append(track)
                }
            }
            let removedIDs = lastSentTracks
                .map { $0.id }
                .filter { !newIDs.contains($0) }

            if !changed.isEmpty {
                bridge.send(.updateTracks(UpdateTracksPayload(tracks: changed)))
            }
            if !removedIDs.isEmpty {
                bridge.send(.removeTracks(RemoveTracksPayload(trackIds: removedIDs)))
            }
            lastSentTracks = newTracks
        }

        /// Send `highlight_selection` if the canonical selection
        /// differs from the last value broadcast.  Empty selection is
        /// sent like any other — JS treats an empty array as "clear
        /// the highlight."
        private func applySelectionIfChanged(_ selection: Selection) {
            if selection == lastSentSelection { return }
            bridge.send(.highlightSelection(HighlightSelectionPayload(selection: selection)))
            lastSentSelection = selection
        }

        /// Send `set_tool` if the active tool differs from the last
        /// value broadcast.
        private func applyToolIfChanged(_ tool: EditingTool) {
            if tool == lastSentTool { return }
            bridge.send(.setTool(SetToolPayload(tool: tool)))
            lastSentTool = tool
        }

        /// Send preview_trim or clear_trim_preview if the trim
        /// preview state differs from what JS last received.  nil
        /// means "no active preview" (clear);  non-nil means render
        /// the named groups.  Both transitions and value-changes
        /// produce a single bridge message;  redundant updates are
        /// suppressed by the equality check.
        private func applyTrimPreviewIfChanged(_ groups: [TrimTrackOperation.PreviewGroup]?) {
            if groups == lastSentTrimPreview { return }
            switch (groups, lastSentTrimPreview) {
            case (nil, _):
                bridge.send(.clearTrimPreview(ClearTrimPreviewPayload()))
            case (let g?, _):
                bridge.send(.previewTrim(PreviewTrimPayload(groups: g)))
            }
            lastSentTrimPreview = groups
        }

        /// Send `zoom_to_bounds` if the trigger's id is one we
        /// haven't dispatched yet.  Per SessionViewModel.zoomToTrack
        /// each call mints a fresh UUID, so two requests for the
        /// SAME bounds still trigger a re-fit on the JS side.  No-op
        /// when the trigger is nil (no zoom requested) or when the
        /// id matches the last one we sent (already dispatched).
        private func applyZoomTriggerIfChanged(_ trigger: ZoomBoundsTrigger?) {
            guard let trigger = trigger else { return }
            if trigger.id == lastSentZoomBoundsId { return }
            bridge.send(.zoomToBounds(ZoomToBoundsPayload(
                northLat: trigger.bounds.north,
                southLat: trigger.bounds.south,
                eastLon: trigger.bounds.east,
                westLon: trigger.bounds.west
            )))
            lastSentZoomBoundsId = trigger.id
        }

        // MARK: - Inbound message handling

        /// Update the canonical selection in response to a JS-side
        /// gesture.  The modifier dictates whether the new points
        /// replace, add to, or subtract from the existing selection.
        /// SwiftUI observes SessionViewModel.selection (via @Published)
        /// so the change automatically triggers an updateNSView, where
        /// `applySelectionIfChanged` round-trips a `highlight_selection`
        /// back to JS — Swift-as-source-of-truth, JS only renders what
        /// Swift says.
        private func handlePointsSelected(_ payload: PointsSelectedPayload) {
            guard let sessionVM = sessionVM else {
                logger.warning("points_selected received but no SessionViewModel attached")
                return
            }

            // Flatten the wire groups into individual point references.
            // toModelGroup() returns nil for wire-malformed UUID strings;
            // that's a bridge violation the dispatcher should have caught
            // already, but defensive guard prevents a malformed group from
            // crashing or contaminating the selection.
            var refs: [Selection.PointReference] = []
            var malformedGroups = 0
            for wireGroup in payload.selection {
                guard let group = wireGroup.toModelGroup() else {
                    malformedGroups += 1
                    continue
                }
                for index in group.pointIndices {
                    refs.append(Selection.PointReference(
                        trackId: group.trackId,
                        segmentId: group.segmentId,
                        pointIndex: index
                    ))
                }
            }
            if malformedGroups > 0 {
                logger.error("handlePointsSelected: \(malformedGroups, privacy: .public) wire groups had malformed UUID strings")
            }

            switch payload.modifier {
            case .replace: sessionVM.selection.replace(with: refs)
            case .add: sessionVM.selection.add(refs)
            case .subtract: sessionVM.selection.subtract(refs)
            }
        }

        /// Apply a brush stroke from JS.  Currently the only brush wired
        /// is Simplify (M4);  Smooth / Average / AddDetail land at later
        /// milestones with new branches in this switch.  An unknown
        /// brush_type is logged as a bridge violation and dropped — the
        /// dispatcher already validated the envelope, so an unknown
        /// brush type at this layer is a Swift/JS schema mismatch.
        private func handleApplyBrush(_ payload: ApplyBrushPayload) {
            guard let sessionVM = sessionVM else {
                logger.warning("apply_brush received but no SessionViewModel attached")
                return
            }
            logger.info("handleApplyBrush: brush=\(payload.brushType, privacy: .public) track=\(payload.trackId.uuidString.prefix(8), privacy: .public) samples=\(payload.stroke.samples.count, privacy: .public)")

            switch payload.brushType {
            case "simplify":
                let samples = payload.stroke.samples.map {
                    SimplifyBrush.StrokeSample(
                        latitude: $0.lat,
                        longitude: $0.lon,
                        radiusMeters: $0.radiusMeters
                    )
                }
                sessionVM.applySimplifyBrush(trackId: payload.trackId, stroke: samples)
            case "smooth":
                let samples = payload.stroke.samples.map {
                    SmoothBrush.StrokeSample(
                        latitude: $0.lat,
                        longitude: $0.lon,
                        radiusMeters: $0.radiusMeters
                    )
                }
                sessionVM.applySmoothBrush(trackId: payload.trackId, stroke: samples)
            default:
                logger.error("apply_brush unknown brush_type: \(payload.brushType, privacy: .public)")
            }
        }

        /// Apply a vertex-drag commit from JS (M5).
        private func handleMovePoint(_ payload: MovePointPayload) {
            guard let sessionVM = sessionVM else {
                logger.warning("move_point received but no SessionViewModel attached")
                return
            }
            sessionVM.applyMovePoint(
                trackId: payload.trackId,
                segmentId: payload.segmentId,
                pointIndex: payload.pointIndex,
                latitude: payload.lat,
                longitude: payload.lon
            )
        }

        /// Apply a click-on-line insertion from JS (M5).
        private func handleAddPointOnLine(_ payload: AddPointOnLinePayload) {
            guard let sessionVM = sessionVM else {
                logger.warning("add_point_on_line received but no SessionViewModel attached")
                return
            }
            sessionVM.applyAddPointOnLine(
                trackId: payload.trackId,
                segmentId: payload.segmentId,
                afterIndex: payload.afterIndex,
                latitude: payload.lat,
                longitude: payload.lon
            )
        }

        /// Show a native NSMenu in response to a right-click in the
        /// WebView (M5 follow-up).  Items differ by target — point
        /// vs empty space.  Each item carries a closure that routes
        /// to the corresponding SessionViewModel method;  the
        /// ClosureMenuItem helper bridges between AppKit's selector-
        /// based action API and Swift closures.
        private func handleRequestContextMenu(_ payload: RequestContextMenuPayload) {
            guard let sessionVM = sessionVM, let webView = webView else {
                logger.warning("request_context_menu received but no SessionViewModel / WebView attached")
                return
            }
            let menu = NSMenu()

            switch payload.target {
            case .point(let trackId, let segmentId, let pointIndex):
                menu.addItem(ClosureMenuItem(title: "Delete this Point") { [weak sessionVM] in
                    sessionVM?.deleteSinglePoint(trackId: trackId, segmentId: segmentId, pointIndex: pointIndex)
                })
                menu.addItem(ClosureMenuItem(title: "Edit Coordinates…") { [weak sessionVM] in
                    sessionVM?.requestEditCoordinates(trackId: trackId, segmentId: segmentId, pointIndex: pointIndex)
                })
                menu.addItem(.separator())
                // M7:  Snap to Ground — single-point DEM elevation
                // correction via OpenTopoData.  Async (the Task runs
                // inside applySnapToGround), so the menu dismisses
                // immediately and the user sees the result land
                // (or an alert) when the network round-trip completes.
                menu.addItem(ClosureMenuItem(title: "Snap to Ground") { [weak sessionVM] in
                    sessionVM?.applySnapToGround(trackId: trackId, segmentId: segmentId, pointIndex: pointIndex)
                })
                menu.addItem(.separator())
                menu.addItem(ClosureMenuItem(title: "Promote to Waypoint") { [weak sessionVM] in
                    sessionVM?.applyPromoteToWaypoint(trackId: trackId, segmentId: segmentId, pointIndex: pointIndex)
                })
                menu.addItem(ClosureMenuItem(title: "Set as Segment Boundary") { [weak sessionVM] in
                    sessionVM?.applySetSegmentBoundary(trackId: trackId, segmentId: segmentId, pointIndex: pointIndex)
                })
                menu.addItem(.separator())
                menu.addItem(ClosureMenuItem(title: "Select Entire Segment") { [weak sessionVM] in
                    sessionVM?.selectEntireSegment(trackId: trackId, segmentId: segmentId)
                })
                // Track-scoped operations.  Right-clicking on a point
                // unambiguously names the containing track, so the
                // track-scoped roster (Reverse, Split, Merge, Trim as
                // they land) lives here in addition to the Edit menu.
                menu.addItem(.separator())
                menu.addItem(ClosureMenuItem(title: "Split Track Here") { [weak sessionVM] in
                    sessionVM?.applySplitTrack(trackId: trackId, segmentId: segmentId, pointIndex: pointIndex)
                })
                menu.addItem(ClosureMenuItem(title: "Reverse Track") { [weak sessionVM] in
                    sessionVM?.applyReverseTrack(trackId: trackId)
                })
                // Merge Track Into… — disabled if the project has
                // only one track (no candidate sources).  Setting
                // .isEnabled directly on the NSMenuItem is the
                // AppKit equivalent of SwiftUI's .disabled() and
                // works even though ClosureMenuItem doesn't override
                // validation logic.
                let mergeItem = ClosureMenuItem(title: "Merge Track Into…") { [weak sessionVM] in
                    sessionVM?.requestMergeTracks(destinationId: trackId)
                }
                let trackCount = sessionVM.documentBinding?.wrappedValue.session.tracks.count ?? 0
                mergeItem.isEnabled = trackCount >= 2
                menu.addItem(mergeItem)
                menu.addItem(ClosureMenuItem(title: "Trim Track…") { [weak sessionVM] in
                    sessionVM?.requestTrimTrack(trackId: trackId)
                })

            case .empty(let lat, let lon):
                menu.addItem(ClosureMenuItem(title: "Place Waypoint Here") { [weak sessionVM] in
                    _ = sessionVM?.applyPlaceWaypoint(latitude: lat, longitude: lon)
                })
                menu.addItem(.separator())
                // M7:  Properties of This Location — looks up DEM
                // elevation for the empty-space click position and
                // surfaces lat/lon/elevation in an informational
                // NSAlert.  Async because of the network call.
                menu.addItem(ClosureMenuItem(title: "Properties of This Location") { [weak sessionVM] in
                    sessionVM?.showPropertiesOfLocation(latitude: lat, longitude: lon)
                })
            }

            // JS sent click coords in container-pixel space (top-left
            // origin, y-down).  WKWebView is a flipped:true NSView on
            // macOS, so the same coordinates are valid for popUp(at:in:).
            let point = NSPoint(x: payload.clickX, y: payload.clickY)
            menu.popUp(positioning: nil, at: point, in: webView)
        }

        /// Called by MapView when `WKContentRuleListStore` compilation
        /// fails.  Per SECURITY.md, this is a serious error — without
        /// the rule list the WebView can issue arbitrary requests.  We
        /// surface as an alert via NSAlert so the user knows the map
        /// is unsafe to use, and we leave the WebView empty (we never
        /// loaded index.html) so no requests can be issued.
        func reportRuleListFailure(error: Error) {
            logger.fault("WKContentRuleList compilation failed: \(error.localizedDescription, privacy: .public)")
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Map view could not start safely."
            alert.informativeText = "The network allow-list could not be installed.  GPXeditor declines to load the map until this is fixed.\n\n\(error.localizedDescription)"
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }

        /// Called by MapView when `index.html` cannot be located in the
        /// app bundle.  This is a build-time configuration error — the
        /// vendored WebResources files weren't copied into the bundle.
        func reportIndexHTMLMissing() {
            logger.fault("index.html not found in app bundle; map cannot load")
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Map view could not start."
            alert.informativeText = "The bundled web resources are missing — index.html was not found in the app bundle.  This is a build-configuration issue;  the vendored WebResources files may not be included in the target's Copy Bundle Resources phase."
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }

        // MARK: WKNavigationDelegate

        /// Allow the initial file:// load of index.html;  deny every
        /// other navigation request.  See Docs/02_MAP_AND_BRIDGE.md
        /// "WKWebView setup" — the editor is a single-page surface and
        /// has no business navigating anywhere else.
        ///
        /// Inherits MainActor isolation from the enclosing Coordinator
        /// (no `nonisolated` here).  WebKit calls navigation delegates
        /// on the main thread, and Xcode 16's SDK marks
        /// `WKNavigationAction.request` as main-actor-required, so the
        /// previously-nonisolated form would now fail to access
        /// `request` directly.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            let url = navigationAction.request.url
            if url?.isFileURL == true {
                decisionHandler(.allow)
                return
            }
            logger.warning("Navigation blocked: \(url?.absoluteString ?? "<no url>", privacy: .public)")
            decisionHandler(.cancel)
        }
    }
}

// MARK: - ClosureMenuItem
//
// NSMenuItem subclass that holds a closure instead of forcing every
// caller to define @objc selectors.  AppKit natively wires menu items
// via target/selector;  for the M5 follow-up's context menu we have
// per-item closures capturing the (track, segment, index) triple
// each item operates on, and selector-and-representedObject
// indirection would obscure intent without much benefit.

private final class ClosureMenuItem: NSMenuItem {

    private let closureAction: () -> Void

    init(title: String, closureAction: @escaping () -> Void) {
        self.closureAction = closureAction
        super.init(title: title, action: nil, keyEquivalent: "")
        self.target = self
        self.action = #selector(invoke)
    }

    required init(coder: NSCoder) { fatalError("ClosureMenuItem doesn't support archiving") }

    @objc private func invoke() { closureAction() }
}
