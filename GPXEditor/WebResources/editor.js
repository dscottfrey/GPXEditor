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

    What lives here at M3:
      - Leaflet map initialization
      - Tile-layer management (set_basemap)
      - Track polyline rendering (load_session, update_tracks)
      - Selection-highlight overlay rendering (highlight_selection)
      - Tool switching (set_tool)
      - Marquee selection (Point Tool, drag-in-empty-space)
      - Lasso selection (Lasso Tool, free-form polygon)
      - Click-empty-space-to-deselect
      - Modifier keys for selection (shift = add, alt = subtract)
      - The bridge dispatcher (window.gpxEditor.handleMessage) and the
        outbound postMessage helpers
      - Structured logging back to Swift via the `log` message

    What's a future-milestone hook:
      - render_brush_preview / clear_brush_preview (M4)
      - move_point / add_point_on_line / right-click context menu (M5)
      - place_waypoint (M8)
      - apply_brush (M4 / M9)

    Style:  modern ES2020+ targeted at WKWebView on macOS 14 (D-006), no
    transpilation, no module bundler, no third-party JS framework.
*/

(function () {
    'use strict';

    // ─── Build identification ────────────────────────────────────────────
    // Sent to Swift with the `ready` message so a Swift/JS schema mismatch
    // is visible in os_log alongside the version of the running native
    // binary.  Bumped manually when this file's bridge contract changes.
    const EDITOR_VERSION = 'editor.js@2026-05-05-m3';

    // ─── State ───────────────────────────────────────────────────────────
    // None of `state` is authoritative — every field is replaced when
    // Swift sends a fresh `load_session`, `update_tracks`,
    // `highlight_selection`, or `set_tool`.
    const state = {
        map: null,                 // Leaflet L.map instance
        tileLayer: null,           // Currently-active basemap L.tileLayer
        tracksById: new Map(),     // track_id -> {name, role, segmentLayers: Map}
                                   //   segmentLayers: Map<segment_id, {halo, line}>
        selectionLayer: null,      // L.LayerGroup of CircleMarker for selected points
        currentTool: 'point',      // 'point' | 'lasso'
        marquee: null,             // active marquee state, see startMarquee
        lasso: null,               // active lasso state, see startLasso
    };

    // ─── Bridge — outbound (JS -> Swift) ─────────────────────────────────
    function postToSwift(message) {
        const handler = window.webkit
            && window.webkit.messageHandlers
            && window.webkit.messageHandlers.gpxBridge;
        if (!handler) {
            console.warn('[GPXeditor] gpxBridge handler missing; message dropped:', message);
            return;
        }
        handler.postMessage(message);
    }

    // Convenience wrapper for the `log` message type.  Use this in place
    // of console.log throughout editor.js (CONVENTIONS.md "console.log is
    // not for production").
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
        handler(payload, message.id);
    }

    const inboundHandlers = {
        load_session: handleLoadSession,
        update_tracks: handleUpdateTracks,
        set_basemap: handleSetBasemap,
        highlight_selection: handleHighlightSelection,
        set_tool: handleSetTool,
        // Future-milestone stubs.  Logging at warning level (rather than
        // silently dispatching) makes a stray early message visible during
        // development without crashing.
        render_brush_preview: function (payload) {
            log('warning', 'render_brush_preview not yet implemented (M4)', { payload: payload });
        },
        clear_brush_preview: function () {
            log('warning', 'clear_brush_preview not yet implemented (M4)');
        },
    };

    // ─── load_session handler ────────────────────────────────────────────
    function handleLoadSession(payload) {
        if (!payload || !Array.isArray(payload.tracks)) {
            log('error', 'load_session payload missing tracks array', { payload: payload });
            return;
        }

        // Tear down any existing track layers.
        for (const trackEntry of state.tracksById.values()) {
            for (const segmentLayers of trackEntry.segmentLayers.values()) {
                segmentLayers.halo.remove();
                segmentLayers.line.remove();
            }
        }
        state.tracksById.clear();

        // Tear down any active gesture artifacts.
        clearMarquee();
        clearLasso();
        clearSelectionHighlight();

        // Build new layers.
        const allLatLngs = [];
        for (const track of payload.tracks) {
            renderTrack(track);
            for (const segment of track.segments || []) {
                if (!Array.isArray(segment.points)) continue;
                for (const p of segment.points) {
                    if (typeof p.lat === 'number' && typeof p.lon === 'number') {
                        allLatLngs.push([p.lat, p.lon]);
                    }
                }
            }
        }

        // Viewport: prefer the saved one, else fit to whatever we drew.
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

    // ─── update_tracks handler ───────────────────────────────────────────
    // Replace specific tracks' rendering without touching others.  Used
    // when Swift mutates one or a few tracks (Import GPX appending, Delete
    // operating on a few segments) and wants to push the result without
    // a full session reload.
    function handleUpdateTracks(payload) {
        if (!payload || !Array.isArray(payload.tracks)) {
            log('error', 'update_tracks payload missing tracks array', { payload: payload });
            return;
        }

        for (const track of payload.tracks) {
            // Tear down the prior layers for this track id, if any.
            const existing = state.tracksById.get(track.track_id);
            if (existing) {
                for (const segmentLayers of existing.segmentLayers.values()) {
                    segmentLayers.halo.remove();
                    segmentLayers.line.remove();
                }
            }
            // Render fresh.  Replaces the entry in state.tracksById.
            renderTrack(track);
        }

        log('info', 'Tracks updated', { track_count: payload.tracks.length });
    }

    // Render a single track's polylines into Leaflet, registering the
    // layer references in state.tracksById.  Replaces any prior entry
    // for the same track_id.
    function renderTrack(track) {
        const segmentLayers = new Map();
        for (const segment of track.segments || []) {
            if (!Array.isArray(segment.points) || segment.points.length === 0) continue;
            const latlngs = segment.points
                .filter(p => typeof p.lat === 'number' && typeof p.lon === 'number')
                .map(p => [p.lat, p.lon]);
            if (latlngs.length === 0) continue;

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
        }
        state.tracksById.set(track.track_id, {
            name: track.name,
            role: track.role,
            segmentLayers: segmentLayers,
        });
    }

    // ─── set_basemap handler ─────────────────────────────────────────────
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
            subdomains: 'abc',
        });

        if (state.tileLayer) {
            state.map.removeLayer(state.tileLayer);
        }
        newLayer.addTo(state.map);
        state.tileLayer = newLayer;

        log('info', 'Basemap set', { basemap_id: payload.basemap_id });
    }

    // ─── highlight_selection handler ─────────────────────────────────────
    // Render the canonical selection as small CircleMarkers on top of
    // the polylines.  Empty selection clears the highlight.
    function handleHighlightSelection(payload) {
        if (!payload || !Array.isArray(payload.selection)) {
            log('error', 'highlight_selection payload missing selection array', { payload: payload });
            return;
        }
        clearSelectionHighlight();

        const groups = payload.selection;
        if (groups.length === 0) return;

        // Track skipped counts so we can warn if highlights silently drop
        // (typically caused by an id mismatch between Swift and JS — the
        // exact bug that caused the M3 first-cut "marquee selects but no
        // markers appear" diagnosis).  Only log if any were skipped;  the
        // success path is silent.
        const layerGroup = L.layerGroup();
        let skippedNoTrack = 0;
        let skippedNoSegment = 0;
        let skippedOOB = 0;

        for (const group of groups) {
            const trackEntry = state.tracksById.get(group.track_id);
            if (!trackEntry) { skippedNoTrack++; continue; }
            const segmentLayers = trackEntry.segmentLayers.get(group.segment_id);
            if (!segmentLayers) { skippedNoSegment++; continue; }
            const latlngs = segmentLayers.line.getLatLngs();

            for (const idx of group.point_indices) {
                if (idx < 0 || idx >= latlngs.length) { skippedOOB++; continue; }
                const ll = latlngs[idx];
                const marker = L.circleMarker(ll, {
                    radius: 5,
                    color: '#ffffff',
                    weight: 2,
                    fillColor: '#3b82f6',
                    fillOpacity: 1.0,
                    interactive: false,
                });
                marker.addTo(layerGroup);
            }
        }
        layerGroup.addTo(state.map);
        state.selectionLayer = layerGroup;

        if (skippedNoTrack > 0 || skippedNoSegment > 0 || skippedOOB > 0) {
            log('warning', 'highlight_selection skipped points', {
                skipped_no_track: skippedNoTrack,
                skipped_no_segment: skippedNoSegment,
                skipped_oob: skippedOOB,
            });
        }
    }

    function clearSelectionHighlight() {
        if (state.selectionLayer) {
            state.selectionLayer.remove();
            state.selectionLayer = null;
        }
    }

    // ─── set_tool handler ────────────────────────────────────────────────
    // Update the active tool.  Future drags use the corresponding gesture.
    function handleSetTool(payload) {
        if (!payload || typeof payload.tool !== 'string') {
            log('error', 'set_tool payload missing tool string', { payload: payload });
            return;
        }
        if (payload.tool !== 'point' && payload.tool !== 'lasso') {
            log('error', 'set_tool payload has unknown tool', { tool: payload.tool });
            return;
        }
        // Cancel any in-progress gesture before switching tools — half-
        // finished marquees / lassos under the new tool would be confusing.
        clearMarquee();
        clearLasso();
        state.currentTool = payload.tool;
        log('info', 'Tool set', { tool: payload.tool });
    }

    // ─── Selection gestures ──────────────────────────────────────────────
    // Both marquee (point tool) and lasso (lasso tool) start on map
    // mousedown in empty space and commit on mouseup.  During the gesture
    // we disable Leaflet's drag-to-pan so the gesture is unambiguous;
    // re-enable on commit / cancel.

    function startMarquee(e) {
        state.marquee = {
            startLatLng: e.latlng,
            modifierKey: getModifierKey(e.originalEvent),
            rectangle: L.rectangle([e.latlng, e.latlng], {
                color: '#3b82f6',
                weight: 1,
                opacity: 0.8,
                fillOpacity: 0.1,
                interactive: false,
                dashArray: '4 3',
            }).addTo(state.map),
            moved: false,
        };
        state.map.dragging.disable();
    }

    function updateMarquee(e) {
        if (!state.marquee) return;
        state.marquee.moved = true;
        state.marquee.rectangle.setBounds(L.latLngBounds(state.marquee.startLatLng, e.latlng));
    }

    function commitMarquee() {
        if (!state.marquee) return;
        const moved = state.marquee.moved;
        const bounds = state.marquee.rectangle.getBounds();
        const modifierKey = state.marquee.modifierKey;
        clearMarquee();

        if (!moved) {
            // No drag — treat as click in empty space.  Replace selection
            // with empty (i.e., deselect all), unless modifier was held
            // (in which case do nothing — modifier-click on empty space
            // is meaningless and shouldn't accidentally clear).
            if (modifierKey === 'replace') {
                postToSwift({
                    type: 'points_selected',
                    payload: { modifier: 'replace', selection: [] },
                });
            }
            return;
        }

        const selection = pointsInBounds(bounds);
        postToSwift({
            type: 'points_selected',
            payload: { modifier: modifierKey, selection: selection },
        });
    }

    function clearMarquee() {
        if (state.marquee) {
            state.marquee.rectangle.remove();
            state.marquee = null;
        }
        state.map.dragging.enable();
    }

    function startLasso(e) {
        state.lasso = {
            modifierKey: getModifierKey(e.originalEvent),
            latlngs: [e.latlng],
            polyline: L.polyline([e.latlng], {
                color: '#3b82f6',
                weight: 2,
                opacity: 0.9,
                interactive: false,
                dashArray: '4 3',
            }).addTo(state.map),
            moved: false,
        };
        state.map.dragging.disable();
    }

    function updateLasso(e) {
        if (!state.lasso) return;
        state.lasso.moved = true;
        state.lasso.latlngs.push(e.latlng);
        state.lasso.polyline.setLatLngs(state.lasso.latlngs);
    }

    function commitLasso() {
        if (!state.lasso) return;
        const moved = state.lasso.moved;
        const polygon = state.lasso.latlngs.slice();  // copy
        const modifierKey = state.lasso.modifierKey;
        clearLasso();

        if (!moved || polygon.length < 3) {
            // A real lasso needs at least 3 vertices;  a non-drag is a
            // click-to-deselect (same convention as marquee).
            if (modifierKey === 'replace') {
                postToSwift({
                    type: 'points_selected',
                    payload: { modifier: 'replace', selection: [] },
                });
            }
            return;
        }

        const selection = pointsInPolygon(polygon);
        postToSwift({
            type: 'points_selected',
            payload: { modifier: modifierKey, selection: selection },
        });
    }

    function clearLasso() {
        if (state.lasso) {
            state.lasso.polyline.remove();
            state.lasso = null;
        }
        state.map.dragging.enable();
    }

    function getModifierKey(originalEvent) {
        // Shift = add to existing selection.
        // Alt/Option = subtract from existing selection.
        // Neither = replace.
        // (Cmd is reserved for menu shortcuts and isn't a selection
        // modifier here — Photoshop convention.)
        if (originalEvent.shiftKey) return 'add';
        if (originalEvent.altKey) return 'subtract';
        return 'replace';
    }

    // ─── Hit-testing ─────────────────────────────────────────────────────
    // Walk every rendered segment, collect indices whose latlng falls
    // inside the gesture's region.  Emits the wire shape directly:
    //   [{track_id, segment_id, point_indices: [int]}]

    function pointsInBounds(bounds) {
        const result = [];
        for (const [trackId, trackEntry] of state.tracksById) {
            for (const [segmentId, segmentLayers] of trackEntry.segmentLayers) {
                const latlngs = segmentLayers.line.getLatLngs();
                const indices = [];
                for (let i = 0; i < latlngs.length; i++) {
                    if (bounds.contains(latlngs[i])) {
                        indices.push(i);
                    }
                }
                if (indices.length > 0) {
                    result.push({
                        track_id: trackId,
                        segment_id: segmentId,
                        point_indices: indices,
                    });
                }
            }
        }
        return result;
    }

    function pointsInPolygon(polygonLatlngs) {
        const result = [];
        for (const [trackId, trackEntry] of state.tracksById) {
            for (const [segmentId, segmentLayers] of trackEntry.segmentLayers) {
                const latlngs = segmentLayers.line.getLatLngs();
                const indices = [];
                for (let i = 0; i < latlngs.length; i++) {
                    if (latLngInPolygon(latlngs[i], polygonLatlngs)) {
                        indices.push(i);
                    }
                }
                if (indices.length > 0) {
                    result.push({
                        track_id: trackId,
                        segment_id: segmentId,
                        point_indices: indices,
                    });
                }
            }
        }
        return result;
    }

    // Standard ray-casting point-in-polygon test.  Operates on (lng, lat)
    // because that maps to the (x, y) the algorithm assumes;  the polygon
    // is closed implicitly between latlngs[N-1] and latlngs[0].
    function latLngInPolygon(latlng, polygon) {
        let inside = false;
        const x = latlng.lng, y = latlng.lat;
        for (let i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
            const xi = polygon[i].lng, yi = polygon[i].lat;
            const xj = polygon[j].lng, yj = polygon[j].lat;
            const intersect = ((yi > y) !== (yj > y))
                && (x < (xj - xi) * (y - yi) / (yj - yi) + xi);
            if (intersect) inside = !inside;
        }
        return inside;
    }

    // ─── Map event wiring ────────────────────────────────────────────────
    function attachMapHandlers() {
        state.map.on('mousedown', function (e) {
            // If the mousedown was inside a polyline's draw area,
            // Leaflet's polyline-click handlers fire separately;  the
            // map-level handler still fires too because the polyline
            // sits *on* the map.  For M3 we accept "drag started on a
            // polyline → starts a selection gesture from that point" —
            // M5's polyline drag-to-move handling will refine this with
            // a hit-test against the polyline.
            if (state.currentTool === 'point') {
                startMarquee(e);
            } else if (state.currentTool === 'lasso') {
                startLasso(e);
            }
        });

        state.map.on('mousemove', function (e) {
            if (state.marquee) updateMarquee(e);
            else if (state.lasso) updateLasso(e);
        });

        state.map.on('mouseup', function () {
            if (state.marquee) commitMarquee();
            else if (state.lasso) commitLasso();
        });

        // Document-level mouseup safety net.  Leaflet's `mouseup` event
        // fires only when the cursor is over the map element;  if the
        // user releases over a SwiftUI overlay (basemap selector,
        // Leaflet's own zoom control floats) or off-window, Leaflet's
        // mouseup never fires and the marquee/lasso would be stranded.
        // The native mouseup listener catches the release wherever it
        // happens and cancels the gesture cleanly — preferable to a
        // mouseout-cancels strategy, which would kill gestures whenever
        // the cursor briefly grazes a control.
        document.addEventListener('mouseup', function () {
            if (state.marquee) commitMarquee();
            else if (state.lasso) commitLasso();
        });
    }

    // ─── Initialization ──────────────────────────────────────────────────
    function init() {
        state.map = L.map('map', {
            zoomControl: true,
            attributionControl: true,
        }).setView([0, 0], 2);

        attachMapHandlers();

        window.gpxEditor = {
            handleMessage: handleMessage,
        };

        postToSwift({
            type: 'ready',
            payload: { editor_version: EDITOR_VERSION },
        });
    }

    init();
})();
