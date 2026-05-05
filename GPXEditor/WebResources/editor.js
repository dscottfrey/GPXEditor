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
    const EDITOR_VERSION = 'editor.js@2026-05-05-m4';

    // ─── Brush parameters (M4) ───────────────────────────────────────────
    // Fixed for v1 per D-016 — no slider, no per-stroke tuning.  Tunable
    // values are in metres so they match the Swift-side SimplifyBrush
    // contract (the wire format carries radius_meters per sample).
    const BRUSH_RADIUS_METERS = 30;
    // Preview tolerance in lat/lon degrees.  ~9e-5 deg ≈ 10m latitude;
    // matches Swift's defaultToleranceMeters so the preview shows what
    // the canonical commit will produce.  Longitude shrinks with cos(lat)
    // so the effective tolerance shifts slightly with latitude;
    // acceptable because the preview is a UX cue, not the authoritative
    // result.
    const BRUSH_PREVIEW_TOLERANCE_DEGREES = 9e-5;

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
        currentTool: 'point',      // 'point' | 'lasso' | 'brush_simplify' | 'brush_smooth'
        marquee: null,             // active marquee state, see startMarquee
        lasso: null,               // active lasso state, see startLasso
        brush: null,               // active brush state, see startBrush
                                   //   { type: 'simplify'|'smooth', samples, ... }
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
        const knownTools = ['point', 'lasso', 'brush_simplify', 'brush_smooth'];
        if (knownTools.indexOf(payload.tool) === -1) {
            log('error', 'set_tool payload has unknown tool', { tool: payload.tool });
            return;
        }
        // Cancel any in-progress gesture before switching tools — half-
        // finished marquees / lassos / brushes under the new tool would
        // be confusing.
        clearMarquee();
        clearLasso();
        clearBrush();
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

    // ─── Brush gestures (M4) ─────────────────────────────────────────────
    // Brush gesture flow:
    //   mousedown at brush_simplify tool → startBrush, accumulate first sample
    //   mousemove → addBrushSample, recompute live preview
    //   mouseup → commitBrush (one apply_brush per touched track)
    // The brush circle (visualisation of the cursor's reach) is drawn at
    // every cursor sample;  the live preview shows the simplified result
    // for whatever is currently brushed using simplify.js (vendored).
    // Swift's canonical commit re-runs RDP so a stale preview can never
    // commit (Swift-as-source-of-truth invariant).

    function startBrush(e) {
        // Translate the wire tool name into the brush_type string used
        // in the apply_brush wire format.  state.currentTool is the
        // wire tool ("brush_simplify" / "brush_smooth"), brushType is
        // the apply_brush.brush_type discriminator ("simplify" / "smooth").
        const brushType = state.currentTool === 'brush_smooth' ? 'smooth' : 'simplify';
        log('debug', 'Brush gesture started', {
            tool: state.currentTool,
            brush_type: brushType,
            track_count: state.tracksById.size,
        });
        state.brush = {
            type: brushType,
            samples: [{
                lat: e.latlng.lat,
                lng: e.latlng.lng,
                radius_meters: BRUSH_RADIUS_METERS,
            }],
            cursorCircle: L.circle(e.latlng, {
                radius: BRUSH_RADIUS_METERS,
                color: '#3b82f6',
                weight: 1,
                opacity: 0.8,
                fillColor: '#3b82f6',
                fillOpacity: 0.15,
                interactive: false,
            }).addTo(state.map),
            previewLayer: null,
            moved: false,
        };
        state.map.dragging.disable();
        recomputeBrushPreview();
    }

    function addBrushSample(e) {
        if (!state.brush) return;
        state.brush.moved = true;
        state.brush.samples.push({
            lat: e.latlng.lat,
            lng: e.latlng.lng,
            radius_meters: BRUSH_RADIUS_METERS,
        });
        state.brush.cursorCircle.setLatLng(e.latlng);
        recomputeBrushPreview();
    }

    function commitBrush() {
        if (!state.brush) return;
        const moved = state.brush.moved;
        const samples = state.brush.samples;
        const brushType = state.brush.type;
        clearBrush();

        if (!moved || samples.length < 1) {
            // No drag — nothing to commit.
            return;
        }

        // Determine which tracks have points in the brush region.  One
        // apply_brush message per touched track, per the wire format.
        // Swift re-computes the operation authoritatively;  the local
        // preview was just a UX cue.
        const touchedTrackIds = tracksTouchedByStroke(samples);
        log('info', 'Brush committed', {
            brush_type: brushType,
            sample_count: samples.length,
            touched_track_count: touchedTrackIds.length,
        });
        for (const trackId of touchedTrackIds) {
            postToSwift({
                type: 'apply_brush',
                payload: {
                    brush_type: brushType,
                    track_id: trackId,
                    stroke: {
                        kind: 'region',
                        samples: samples.map(s => ({
                            lat: s.lat,
                            lon: s.lng,
                            radius_meters: s.radius_meters,
                        })),
                    },
                },
            });
        }
    }

    function clearBrush() {
        if (state.brush) {
            state.brush.cursorCircle.remove();
            if (state.brush.previewLayer) {
                state.brush.previewLayer.remove();
            }
            state.brush = null;
        }
        state.map.dragging.enable();
    }

    /// Recompute the brush's live preview.  Dispatches on the active
    /// brush type — Simplify renders X markers at points that would
    /// be dropped, Smooth renders the smoothed polyline as an overlay.
    /// Per CONVENTIONS.md "Color is never the only signal," each
    /// preview uses a non-color cue (Simplify:  the X glyph shape;
    /// Smooth:  the line's shape difference from the original) plus
    /// color as a secondary cue.  Rebuilt from scratch each call;  v1
    /// scale is fast enough that the recompute cost is invisible.
    function recomputeBrushPreview() {
        if (!state.brush) return;

        // Tear down the prior preview overlay.
        if (state.brush.previewLayer) {
            state.brush.previewLayer.remove();
            state.brush.previewLayer = null;
        }

        const layerGroup = state.brush.type === 'simplify'
            ? buildSimplifyPreviewLayer(state.brush.samples)
            : buildSmoothPreviewLayer(state.brush.samples);

        if (layerGroup) {
            layerGroup.addTo(state.map);
            state.brush.previewLayer = layerGroup;
        }
    }

    /// Simplify preview:  X glyphs at points that would be dropped.
    /// Returns the layer group, or null if no X would render.
    function buildSimplifyPreviewLayer(samples) {
        const layerGroup = L.layerGroup();
        let removedCount = 0;

        for (const [, trackEntry] of state.tracksById) {
            for (const [, segmentLayers] of trackEntry.segmentLayers) {
                const latlngs = segmentLayers.line.getLatLngs();
                if (latlngs.length < 3) continue;

                const inRegion = new Array(latlngs.length).fill(false);
                for (let i = 0; i < latlngs.length; i++) {
                    if (anySampleTouches(latlngs[i], samples)) {
                        inRegion[i] = true;
                    }
                }

                const ranges = contiguousRanges(inRegion);
                if (ranges.length === 0) continue;

                for (const range of ranges) {
                    const startIdx = Math.max(0, range[0] - 1);
                    const endIdx = Math.min(latlngs.length - 1, range[1] + 1);

                    const slice = [];
                    const sliceOriginalIndices = [];
                    for (let i = startIdx; i <= endIdx; i++) {
                        slice.push({ x: latlngs[i].lng, y: latlngs[i].lat });
                        sliceOriginalIndices.push(i);
                    }

                    const simplified = simplify(slice, BRUSH_PREVIEW_TOLERANCE_DEGREES, true);
                    const keptSet = new Set(simplified);
                    for (let i = 0; i < slice.length; i++) {
                        if (!keptSet.has(slice[i])) {
                            const originalIndex = sliceOriginalIndices[i];
                            const ll = latlngs[originalIndex];
                            const marker = L.marker(ll, {
                                icon: brushPointRemovedIcon,
                                interactive: false,
                                keyboard: false,
                            });
                            marker.addTo(layerGroup);
                            removedCount++;
                        }
                    }
                }
            }
        }

        return removedCount > 0 ? layerGroup : null;
    }

    /// Smooth preview:  for each touched segment, render the smoothed
    /// polyline as an overlay so the user sees the resulting shape.
    /// Smoothing moves every point in the brush region toward the
    /// kernel average — the visible cue is the line getting straighter.
    /// Kernel matches Swift's SmoothBrush (half-width 3, total 7
    /// points uniform-weight average).
    function buildSmoothPreviewLayer(samples) {
        const layerGroup = L.layerGroup();
        let segmentsChanged = 0;

        for (const [, trackEntry] of state.tracksById) {
            for (const [, segmentLayers] of trackEntry.segmentLayers) {
                const latlngs = segmentLayers.line.getLatLngs();
                if (latlngs.length < 3) continue;

                const inRegion = new Array(latlngs.length).fill(false);
                let anyInRegion = false;
                for (let i = 0; i < latlngs.length; i++) {
                    if (anySampleTouches(latlngs[i], samples)) {
                        inRegion[i] = true;
                        anyInRegion = true;
                    }
                }
                if (!anyInRegion) continue;

                // Build the smoothed polyline:  brushed points get
                // their kernel-averaged position;  out-of-region points
                // keep their original position.  This matches Swift's
                // SmoothBrush behaviour exactly so the preview reflects
                // the canonical commit.
                const smoothed = [];
                for (let i = 0; i < latlngs.length; i++) {
                    if (inRegion[i]) {
                        const lower = Math.max(0, i - SMOOTH_KERNEL_HALF_WIDTH);
                        const upper = Math.min(latlngs.length - 1, i + SMOOTH_KERNEL_HALF_WIDTH);
                        let sumLat = 0, sumLng = 0, count = 0;
                        for (let j = lower; j <= upper; j++) {
                            sumLat += latlngs[j].lat;
                            sumLng += latlngs[j].lng;
                            count++;
                        }
                        smoothed.push([sumLat / count, sumLng / count]);
                    } else {
                        smoothed.push([latlngs[i].lat, latlngs[i].lng]);
                    }
                }

                L.polyline(smoothed, {
                    color: '#ff00ff',
                    weight: 4,
                    opacity: 0.95,
                    dashArray: '6 3',
                    interactive: false,
                }).addTo(layerGroup);
                segmentsChanged++;
            }
        }

        return segmentsChanged > 0 ? layerGroup : null;
    }

    // Kernel half-width — must match SmoothBrush.defaultKernelHalfWidth
    // in Swift so the preview reflects the canonical commit.  Tuned to
    // 1 (3-point average) during M4 verification — 3 was too aggressive
    // for typical GPS noise.
    const SMOOTH_KERNEL_HALF_WIDTH = 1;

    /// Static Leaflet divIcon for the "would be removed" X marker.
    /// Defined once — Leaflet's icon system reuses the same divIcon
    /// across many marker instances so per-call construction is
    /// wasteful.  Styling is in editor.css under .brush-removed-glyph.
    const brushPointRemovedIcon = L.divIcon({
        html: '<div class="brush-removed-glyph">&#10005;</div>',
        className: '',  // suppress Leaflet's default leaflet-div-icon styling
        iconSize: [16, 16],
        iconAnchor: [8, 8],
    });

    /// Whether a Leaflet LatLng is within radius_meters of any sample.
    /// Uses Leaflet's distanceTo() which does proper haversine — slower
    /// than the flat-Euclidean approximation Swift uses, but JS is doing
    /// preview, not the canonical commit, so accuracy here matters less
    /// than getting the right answer at any single zoom.
    function anySampleTouches(latlng, samples) {
        for (const s of samples) {
            const sampleLatLng = L.latLng(s.lat, s.lng);
            if (latlng.distanceTo(sampleLatLng) <= s.radius_meters) {
                return true;
            }
        }
        return false;
    }

    /// Find which track ids have any point in the brush region.  Used
    /// at commit time to know which tracks to send apply_brush for.
    function tracksTouchedByStroke(samples) {
        const result = [];
        for (const [trackId, trackEntry] of state.tracksById) {
            let touched = false;
            for (const [, segmentLayers] of trackEntry.segmentLayers) {
                const latlngs = segmentLayers.line.getLatLngs();
                for (const ll of latlngs) {
                    if (anySampleTouches(ll, samples)) {
                        touched = true;
                        break;
                    }
                }
                if (touched) break;
            }
            if (touched) result.push(trackId);
        }
        return result;
    }

    /// Find contiguous runs of `true` in a Bool array.  Returns [start,
    /// end] inclusive pairs.
    function contiguousRanges(flags) {
        const ranges = [];
        let start = -1;
        for (let i = 0; i < flags.length; i++) {
            if (flags[i]) {
                if (start === -1) start = i;
            } else if (start !== -1) {
                ranges.push([start, i - 1]);
                start = -1;
            }
        }
        if (start !== -1) ranges.push([start, flags.length - 1]);
        return ranges;
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
            //
            // Brush dispatch uses a startsWith check so future brush
            // types (brush_average, brush_add_detail at M9) are picked
            // up automatically — the JS-side gesture machinery is the
            // same for every brush;  only the brush_type sent on commit
            // and the preview rendering differ, both of which are
            // already keyed off state.brush.type.
            if (state.currentTool === 'point') {
                startMarquee(e);
            } else if (state.currentTool === 'lasso') {
                startLasso(e);
            } else if (state.currentTool.startsWith('brush_')) {
                startBrush(e);
            }
        });

        state.map.on('mousemove', function (e) {
            if (state.marquee) updateMarquee(e);
            else if (state.lasso) updateLasso(e);
            else if (state.brush) addBrushSample(e);
        });

        state.map.on('mouseup', function () {
            if (state.marquee) commitMarquee();
            else if (state.lasso) commitLasso();
            else if (state.brush) commitBrush();
        });

        // Document-level mouseup safety net.  Leaflet's `mouseup` event
        // fires only when the cursor is over the map element;  if the
        // user releases over a SwiftUI overlay (basemap selector,
        // Leaflet's own zoom control floats) or off-window, Leaflet's
        // mouseup never fires and the gesture would be stranded.
        // The native mouseup listener catches the release wherever it
        // happens and cancels the gesture cleanly — preferable to a
        // mouseout-cancels strategy, which would kill gestures whenever
        // the cursor briefly grazes a control.
        document.addEventListener('mouseup', function () {
            if (state.marquee) commitMarquee();
            else if (state.lasso) commitLasso();
            else if (state.brush) commitBrush();
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
