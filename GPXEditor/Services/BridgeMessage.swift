// BridgeMessage.swift
//
// JS↔Swift bridge envelope types.  The protocol is documented in
// CONVENTIONS.md "JavaScript ↔ Swift bridge protocol" and the message
// catalog in Docs/02_MAP_AND_BRIDGE.md.  Every message in either
// direction has the form { type, id?, payload }.
//
// Two-step decoding strategy for inbound messages:  the top-level
// envelope is parsed first to extract `type` and the raw payload bytes;
// then the per-type handler in MessageDispatcher decodes the payload
// into its concrete struct.  This keeps the dispatcher decoupled from
// the proliferating set of payload types — adding a new inbound type is
// a new payload struct in BridgePayloads.swift plus a new case in the
// dispatcher's switch, no changes here.
//
// Outbound messages take the symmetric path:  encode an OutboundMessage
// (a tagged union of typed payloads) into the envelope JSON, hand the
// JSON to MapBridge for evaluateJavaScript injection.
//
// Per CONVENTIONS.md "platform-agnostic data layer," this file is
// platform-agnostic — Foundation only, no WebKit.  The WebKit-bound
// consumer is MapBridge.

import Foundation

// MARK: - Inbound (JS → Swift)

/// First-stage decode of an inbound bridge message:  the envelope without
/// the typed payload.  The dispatcher reads `type`, looks up the
/// corresponding handler, and that handler decodes the payload into its
/// own concrete struct.
public struct RawInboundMessage {

    /// The message type discriminator, snake_case per the protocol.
    public let type: String

    /// Optional correlation id.  Echoed back in a response message for
    /// query-style messages (`request_segment_stats` and so on).
    public let id: String?

    /// The encoded payload as JSON bytes.  The handler decodes this into
    /// its concrete payload struct.  Always present — an empty payload
    /// is encoded as `{}`, never as a missing field.
    public let payloadJSON: Data

    /// Parse an envelope from a raw JSON object as delivered by
    /// WKScriptMessage.body.  WKScriptMessage hands us the message
    /// already deserialized to a Foundation object graph;  we re-encode
    /// the payload subtree to bytes so the per-type handler can decode
    /// with `JSONDecoder` (the canonical path for typed Codable structs).
    ///
    /// Throws BridgeEnvelopeError on malformed input.  Per CONVENTIONS.md
    /// "Nothing fails silently" the caller logs the error and discards;
    /// no partial decode is ever applied.
    public static func parse(_ messageBody: Any) throws -> RawInboundMessage {
        guard let dict = messageBody as? [String: Any] else {
            throw BridgeEnvelopeError.notAnObject
        }
        guard let type = dict["type"] as? String, !type.isEmpty else {
            throw BridgeEnvelopeError.missingType
        }
        let id = dict["id"] as? String  // optional;  may be absent or non-string
        // Treat missing payload as empty object — keeps every handler's
        // decode path uniform.
        let payloadObject = dict["payload"] ?? [String: Any]()
        // JSONSerialization is the right tool here:  the inbound was
        // already deserialized by WebKit, so we go object → bytes for
        // re-decoding via JSONDecoder.  fragmentsAllowed is on because
        // an inbound payload could in principle be a primitive (e.g.,
        // a bare number for a hypothetical message), though every
        // documented payload is an object.
        let bytes: Data
        do {
            bytes = try JSONSerialization.data(
                withJSONObject: payloadObject,
                options: [.fragmentsAllowed]
            )
        } catch {
            throw BridgeEnvelopeError.payloadNotJSONEncodable(underlying: error)
        }
        return RawInboundMessage(type: type, id: id, payloadJSON: bytes)
    }
}

/// Errors raised during envelope parsing.  These are bridge violations
/// — every inbound message that fails this stage is logged and discarded.
public enum BridgeEnvelopeError: Error, LocalizedError {

    /// The raw `WKScriptMessage.body` was not a dictionary.  Either
    /// `editor.js` posted a non-object (a string, number, etc.) or
    /// something is corrupt.
    case notAnObject

    /// The `type` field was missing, empty, or not a string.
    case missingType

    /// JSONSerialization couldn't re-encode the payload subtree.  Should
    /// not occur in normal use because WebKit only delivers JSON-derived
    /// values, but kept here so callers can distinguish this failure
    /// from the typed-payload decode that comes later.
    case payloadNotJSONEncodable(underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .notAnObject:
            return "Bridge violation: inbound message body is not an object."
        case .missingType:
            return "Bridge violation: inbound message has no `type` field."
        case .payloadNotJSONEncodable(let underlying):
            return "Bridge violation: inbound message payload could not be re-encoded — \(underlying.localizedDescription)"
        }
    }
}

// MARK: - Outbound (Swift → JS)

/// A typed outbound message.  Each case wraps a payload type that
/// conforms to `Encodable` with the snake_case key strategy applied at
/// encode time.  Adding a new outbound type:  add a payload struct in
/// BridgePayloads.swift, add a case here, document the schema in
/// Docs/02_MAP_AND_BRIDGE.md.
public enum OutboundMessage {

    case loadSession(LoadSessionPayload)
    case setBasemap(SetBasemapPayload)
    case updateTracks(UpdateTracksPayload)              // M3
    case removeTracks(RemoveTracksPayload)              // M6 — track removal (Merge)
    case highlightSelection(HighlightSelectionPayload)  // M3
    case setTool(SetToolPayload)                        // M3 — tool switch from menu
    case previewTrim(PreviewTrimPayload)                // M6 — Trim Track live preview
    case clearTrimPreview(ClearTrimPreviewPayload)      // M6 — Trim Track dialog dismissal
    case zoomToBounds(ZoomToBoundsPayload)              // M7.5 — sidebar "Zoom to Fit"
    // Future-milestone cases (declared here as they come online):
    // case renderBrushPreview(RenderBrushPreviewPayload)  // M4
    // case clearBrushPreview                              // M4

    /// Discriminator string sent on the wire (snake_case).  Matches the
    /// dispatch table in `editor.js`'s inboundHandlers.
    public var type: String {
        switch self {
        case .loadSession: return "load_session"
        case .setBasemap: return "set_basemap"
        case .updateTracks: return "update_tracks"
        case .removeTracks: return "remove_tracks"
        case .highlightSelection: return "highlight_selection"
        case .setTool: return "set_tool"
        case .previewTrim: return "preview_trim"
        case .clearTrimPreview: return "clear_trim_preview"
        case .zoomToBounds: return "zoom_to_bounds"
        }
    }

    /// Encode to the envelope JSON expected by `editor.js`.  MapBridge
    /// passes the result into `evaluateJavaScript("window.gpxEditor.handleMessage(\(json))")`.
    public func encode() throws -> Data {
        // Build an envelope by encoding the payload first, parsing back
        // to a Foundation object, and reassembling.  This preserves the
        // payload's snake_case key conversion under JSONEncoder.
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        // Stable key ordering simplifies any text-diff debugging of bridge
        // traffic;  not strictly required by editor.js.
        encoder.outputFormatting = [.sortedKeys]
        // Default date strategy is fine — but our payloads encode dates
        // as preformatted ISO 8601 strings (per Docs/02_MAP_AND_BRIDGE.md
        // "time" convention) so the encoder never sees a Date directly.

        let payloadData: Data
        switch self {
        case .loadSession(let p): payloadData = try encoder.encode(p)
        case .setBasemap(let p): payloadData = try encoder.encode(p)
        case .updateTracks(let p): payloadData = try encoder.encode(p)
        case .removeTracks(let p): payloadData = try encoder.encode(p)
        case .highlightSelection(let p): payloadData = try encoder.encode(p)
        case .setTool(let p): payloadData = try encoder.encode(p)
        case .previewTrim(let p): payloadData = try encoder.encode(p)
        case .clearTrimPreview(let p): payloadData = try encoder.encode(p)
        case .zoomToBounds(let p): payloadData = try encoder.encode(p)
        }

        // Round-trip the payload through JSONSerialization so we can
        // re-embed it into the envelope as a JSON value (not a string).
        let payloadObject = try JSONSerialization.jsonObject(
            with: payloadData,
            options: [.fragmentsAllowed]
        )
        let envelope: [String: Any] = [
            "type": self.type,
            "payload": payloadObject,
        ]
        return try JSONSerialization.data(
            withJSONObject: envelope,
            options: [.sortedKeys]
        )
    }
}
