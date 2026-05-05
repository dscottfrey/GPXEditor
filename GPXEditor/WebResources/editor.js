/*
    editor.js — GPXeditor's JavaScript editing layer on top of Leaflet.

    Architecture:  Swift owns the data model;  this file is the presentation
    layer (CONVENTIONS.md "Swift is the source of truth; JavaScript is the
    presentation layer").  Edits originate from JS gestures, are marshaled
    to Swift via the bridge, and only become canonical when Swift sends
    back an updated track payload.  This file never holds authoritative
    document state.

    Bridge protocol:  see Docs/02_MAP_AND_BRIDGE.md.  Every message in
    either direction has the form { type, id?, payload }.  Strict
    validation on receive — unknown types and malformed payloads are
    logged via the `log` message and discarded, never silently applied.

    What lives here at M2:
      - Leaflet map initialization
      - Tile-layer management driven by `set_basemap`
      - Track polyline rendering driven by `load_session` (M2 baseline)
      - The bridge dispatcher (window.gpxEditor.handleMessage) and the
        outbound postMessage helpers
      - Structured logging back to Swift via the `log` message
      - Auto-zoom-to-fit on initial session load when no viewport is saved

    What's a future-milestone hook (declared in the dispatcher with a
    `not yet implemented` log so a stray message surfaces visibly rather
    than silently no-ops):
      - update_tracks (M3+)
      - render_brush_preview / clear_brush_preview (M4)
      - highlight_selection (M3)
      - and the JS-originated messages (selection, gestures, brush apply)
        that come online from M3 onward.

    Style:  modern ES2020+ targeted at WKWebView on macOS 14 (D-006), no
    transpilation, no module bundler, no third-party JS framework.  This
    is intentional per CONVENTIONS.md "Modern syntax, no transpilation"
    and "Avoid framework patterns."
*/

(function () {
    'use strict';

    // ─── Build identification ────────────────────────────────────────────
    // Sent to Swift with the `ready` message so a Swift/JS schema mismatch
    // (e.g. botched vendored-asset update, partial editor.js update) is
    // visible in os_log alongside the version of the running native binary.
    // Bumped manually when this file's bridge contract changes.
    const EDITOR_VERSION = 'editor.js@2026-05-05';

    // ─── State ───────────────────────────────────────────────────────────
    // The `state` object holds everything JS needs to render the current
    // session.  None of it is authoritative — every field is replaced when
    // Swift sends a fresh `load_session` or `update_tracks`.
    const state = {
        map: null,                   // Leaflet L.map instance
        tileLayer: null,             // Currently-active basemap L.tileLayer
        tracksById: new Map(),       // track_id -> { name, role, segmentLayers: Map }
        // segmentLayers is a Map<segment_id, { halo: L.polyline, line: L.polyline }>
    };

    // ─── Bridge — outbound (JS -> Swift) ─────────────────────────────────
    // Send a structured message to Swift.  The envelope shape is enforced
    // by CONVENTIONS.md and Docs/02_MAP_AND_BRIDGE.md.  The bridge handler
    // name is `gpxBridge` (registered Swift-side in MapBridge).  If the
    // handler is missing for any reason (e.g., this file loaded outside a
    // GPXeditor WebView during development), we log to console — that is
    // the one place console.log is acceptable, because there is no Swift
    // bridge to log to.
    function postToSwift(message) {
        const handler = window.webkit
            && window.webkit.messageHandlers
            && window.webkit.messageHandlers.gpxBridge;
        if (!handler) {
            // Swift bridge missing.  Don't crash;  just trace.
            console.warn('[GPXeditor] gpxBridge handler missing; message dropped:', message);
            return;
        }
        handler.postMessage(message);
    }

    // Convenience wrapper for the `log` message type.  Use this in place
    // of console.log throughout editor.js (CONVENTIONS.md "console.log is
    // not for production"); the message goes into Swift's os_log with
    // matching severity and lands in Console.app alongside Swift logs.
    function log(level, message, context) {
        postToSwift({
            type: 'log',
            payload: {
                level: level,
                message: message,
                context: context || null,
            },
        });
    }

    // ─── Bridge — inbound (Swift -> JS) ──────────────────────────────────
    // Swift calls window.gpxEditor.handleMessage(msg) via evaluateJavaScript.
    // Strict validation:  unknown type, missing payload, or a payload that
    // doesn't match the expected shape is logged via the `log` message at
    // error severity and discarded — never partially applied.
    function handleMessage(message) {
        if (!message || typeof message !== 'object') {
            log('error', 'Bridge violation: non-object inbound message', { received: typeof message });
            return;
        }
        const type = message.type;
        const payload = message.payload;
        if (typeof type !== 'string') {
            log('error', 'Bridge violation: missing or non-string `type`', { message: message });
            return;
        }
        const handler = inboundHandlers[type];
        if (!handler) {
            log('error', 'Bridge violation: unknown inbound message type', { type: type });
            return;
        }
        // Each handler validates its own payload shape and returns silently;
        // an exception thrown here would mean a programmer bug in editor.js
        // itself, so we let it propagate to the WKWebView's own JS error
        // surface (and it will show up in Web Inspector during development).
        handler(payload, message.id);
    }

    // Dispatch table.  Each entry is a (payload, id?) handler.  Adding a
    // new inbound message type:  add a Docs/02_MAP_AND_BRIDGE.md schema
    // entry, add a handler here, document any new state in the `state`
    // object above.
    const inboundHandlers = {
        load_session: handleLoadSession,
        set_basemap: handleSetBasemap,
        // Future-milestone stubs.  Logging at warning level (rather than
        // silently dispatching) makes a stray early message visible during
        // development without crashing.
        update_tracks: function (payload) {
            log('warning', 'update_tracks not yet implemented (M3)', { payload: payload });
        },
        highlight_selection: function (payload) {
            log('warning', 'highlight_selection not yet implemented (M3)', { payload: payload });
        },
        render_brush_preview: function (payload) {
            log('warning', 'render_brush_preview not yet implemented (M4)', { payload: payload });
        },
        clear_brush_preview: function () {
            log('warning', 'clear_brush_preview not yet implemented (M4)');
        },
    };

    // ─── load_session handler ────────────────────────────────────────────
    // Replace the entire visible state with a fresh project payload.  Used
    // on initial load and whenever the document changes wholesale (project
    // open / new / Reset to Original on master).
    function handleLoadSession(payload) {
        if (!payload || !Array.isArray(payload.tracks)) {
            log('error', 'load_session payload missing tracks array', { payload: payload });
            return;
        }

        // Tear down any existing track layers from a previous load.
        for (const trackEntry of state.tracksById.values()) {
            for (const segmentLayers of trackEntry.segmentLayers.values()) {
                segmentLayers.halo.remove();
                segmentLayers.line.remove();
            }
        }
        state.tracksById.clear();

        // Build new layers.  Two polylines per segment (halo + colored
        // line) per the D-013 accessibility requirement.
        const allLatLngs = [];
        for (const track of payload.tracks) {
            const segmentLayers = new Map();
            if (!Array.isArray(track.segments)) continue;
            for (const segment of track.segments) {
                if (!Array.isArray(segment.points) || segment.points.length === 0) continue;
                const latlngs = segment.points
                    .filter(p => typeof p.lat === 'number' && typeof p.lon === 'number')
                    .map(p => [p.lat, p.lon]);
                if (latlngs.length === 0) continue;

                // Halo first (under) then colored line (over).
                const halo = L.polyline(latlngs, {
                    className: 'track-halo',
                    interactive: false,
                }).addTo(state.map);
                const line = L.polyline(latlngs, {
                    color: segment.color || '#3388ff',
                    weight: 3,
                    interactive: true,
                }).addTo(state.map);

                segmentLayers.set(segment.segment_id, { halo: halo, line: line });
                for (const ll of latlngs) allLatLngs.push(ll);
            }
            state.tracksById.set(track.track_id, {
                name: track.name,
                role: track.role,
                segmentLayers: segmentLayers,
            });
        }

        // Viewport: prefer the saved one if present, else fit to whatever
        // we just drew, else leave the map at its current view (e.g.,
        // empty session).
        if (payload.viewport
            && typeof payload.viewport.center_lat === 'number'
            && typeof payload.viewport.center_lon === 'number'
            && typeof payload.viewport.zoom === 'number') {
            state.map.setView(
                [payload.viewport.center_lat, payload.viewport.center_lon],
                payload.viewport.zoom
            );
        } else if (allLatLngs.length > 0) {
            state.map.fitBounds(L.latLngBounds(allLatLngs), { padding: [40, 40] });
        }

        log('info', 'Session loaded', {
            track_count: payload.tracks.length,
            had_viewport: !!payload.viewport,
        });
    }

    // ─── set_basemap handler ─────────────────────────────────────────────
    // Swap the active tile layer.  Sent on app launch with the active
    // basemap from the document, and again whenever the user picks a
    // different basemap from the SwiftUI selector.
    function handleSetBasemap(payload) {
        if (!payload
            || typeof payload.tile_url_template !== 'string'
            || typeof payload.attribution !== 'string'
            || typeof payload.max_zoom !== 'number') {
            log('error', 'set_basemap payload malformed', { payload: payload });
            return;
        }

        const newLayer = L.tileLayer(payload.tile_url_template, {
            attribution: payload.attribution,
            maxZoom: payload.max_zoom,
            // {s} subdomains rotation:  Leaflet's default is 'abc' which
            // matches the convention used by tile.openstreetmap.org and
            // *.tile-cyclosm.openstreetmap.fr.  Tile sources that don't
            // use {s} simply ignore this option.
            subdomains: 'abc',
        });

        if (state.tileLayer) {
            state.map.removeLayer(state.tileLayer);
        }
        newLayer.addTo(state.map);
        state.tileLayer = newLayer;

        log('info', 'Basemap set', { basemap_id: payload.basemap_id });
    }

    // ─── Initialization ──────────────────────────────────────────────────
    // Construct the Leaflet map, register the bridge entry point, and
    // notify Swift we're ready.  The map is created with no tile layer;
    // Swift's first set_basemap (sent in response to `ready`) attaches one.
    function init() {
        // Sensible default view — Null Island.  Replaced immediately by
        // load_session.viewport or fit-to-bounds.  Without an initial
        // setView Leaflet will refuse to render anything.
        state.map = L.map('map', {
            zoomControl: true,
            attributionControl: true,
        }).setView([0, 0], 2);

        // Mount the inbound dispatcher on a stable global path.  Swift's
        // evaluateJavaScript uses `window.gpxEditor.handleMessage(...)`.
        window.gpxEditor = {
            handleMessage: handleMessage,
        };

        // Tell Swift we're alive and ready for load_session.  This MUST
        // be the last thing init() does so that any handler Swift triggers
        // synchronously by responding to `ready` finds the dispatcher
        // already mounted.
        postToSwift({
            type: 'ready',
            payload: { editor_version: EDITOR_VERSION },
        });
    }

    // DOMContentLoaded has already fired by the time editor.js executes
    // (it's the last <script> in <body>, loaded synchronously), so init
    // immediately rather than waiting for an event.
    init();
})();
