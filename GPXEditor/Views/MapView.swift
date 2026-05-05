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

        /// Weak reference to the active SessionViewModel.  Held so the
        /// dispatcher's onPointsSelected callback (registered once at
        /// init time) can route the parsed payload into the
        /// SessionViewModel's selection state regardless of which
        /// updateNSView call is currently in flight.
        private weak var sessionVM: SessionViewModel?

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
        /// and send `update_tracks` for the changed tracks only.  The
        /// snapshot is updated atomically on each call so the next
        /// diff is against the just-sent state.
        ///
        /// Removed-track handling:  M3 has no UI surface for removing
        /// tracks (M8's sidebar adds that), so removal isn't expected
        /// in practice.  When it does arrive we'll need a separate
        /// `remove_tracks` outbound message;  for now `update_tracks`
        /// only handles add and modify.  A removed track would simply
        /// stop being broadcast, leaving its stale rendering in JS
        /// until the next load_session.
        private func applyTracksIfChanged(in document: GPXEditorDocument) {
            let newTracks = document.session.tracks
            let oldByID = Dictionary(uniqueKeysWithValues: lastSentTracks.map { ($0.id, $0) })

            var changed: [Track] = []
            for track in newTracks {
                if oldByID[track.id] != track {
                    changed.append(track)
                }
            }

            if !changed.isEmpty {
                bridge.send(.updateTracks(UpdateTracksPayload(tracks: changed)))
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
        nonisolated func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            let url = navigationAction.request.url
            if url?.isFileURL == true {
                decisionHandler(.allow)
                return
            }
            // Anything else is denied.  Logged in the main-actor
            // logger via a dispatch — the delegate method is
            // nonisolated so we can't call self.logger directly here.
            Task { @MainActor [weak self] in
                self?.logger.warning("Navigation blocked: \(url?.absoluteString ?? "<no url>", privacy: .public)")
            }
            decisionHandler(.cancel)
        }
    }
}
