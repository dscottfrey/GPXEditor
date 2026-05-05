// MessageDispatcher.swift
//
// Routes parsed inbound bridge messages to handlers.  The dispatcher
// itself is small and stateless — it owns the type-to-handler routing
// table and decodes per-message payloads — but it doesn't mutate
// document state directly.  Mutation happens in the closures the
// MapView coordinator passes in, so the dispatcher is fully unit-testable
// with synthesized messages and mock callbacks.
//
// CONVENTIONS.md "platform-agnostic data layer" applies — the dispatcher
// imports Foundation only.  WebKit doesn't appear here.  MapBridge
// instantiates the dispatcher with concrete callbacks at MapView setup
// time.
//
// At M2 the dispatcher handles two inbound types:  `ready` and `log`.
// Subsequent milestones extend the routing table:
//   M3: points_selected, delete_points
//   M4: apply_brush
//   M5: move_point, add_point_on_line
//   M8: place_waypoint, request_segment_stats
//
// Per CONVENTIONS.md "Nothing fails silently" every malformed payload
// or unknown type produces a logged bridge violation;  no partial
// application of state.

import Foundation
import os

/// Routes inbound bridge messages.  Construct with the callbacks the
/// MapView coordinator wires up — `onReady` typically triggers the
/// initial `load_session` send.
public final class MessageDispatcher {

    /// Logger subsystem matches Docs/02_MAP_AND_BRIDGE.md "Bridge
    /// violations and logging."  Filter Console.app to subsystem
    /// `com.gpxeditor.app.MapBridge`, category `bridge`, to see every
    /// inbound bridge log line in one place.
    private let logger = Logger(subsystem: "com.gpxeditor.app.MapBridge", category: "bridge")

    /// Called when JS sends `ready`.  The coordinator's typical action
    /// here is to send `load_session` and `set_basemap` for the active
    /// document.  Closure runs on the main actor (which is where the
    /// dispatcher itself is invoked from MapBridge).
    public var onReady: ((ReadyPayload) -> Void)?

    public init() {}

    /// Dispatch a parsed envelope.  Decodes the payload according to
    /// `raw.type`, then forwards to the corresponding callback.  Unknown
    /// types and decode failures are logged at error level and discarded.
    public func dispatch(_ raw: RawInboundMessage) {
        switch raw.type {

        case "ready":
            decodeAndDispatch(raw, type: ReadyPayload.self) { [weak self] payload in
                self?.logger.info("editor.js ready: \(payload.editorVersion, privacy: .public)")
                self?.onReady?(payload)
            }

        case "log":
            decodeAndDispatch(raw, type: LogPayload.self) { [weak self] payload in
                self?.handleJSLog(payload)
            }

        // Future-milestone types.  Logging at warning level rather than
        // error makes a stray early message visible during development
        // (the dispatcher is reachable;  the operation just isn't wired
        // yet) without conflating with genuine bridge violations.
        case "points_selected", "delete_points",
             "move_point", "add_point_on_line",
             "place_waypoint", "apply_brush", "request_segment_stats":
            logger.warning("Inbound `\(raw.type, privacy: .public)` received but handler not yet implemented")

        default:
            // Unknown type — bridge violation per CONVENTIONS.md.
            logger.error("Bridge violation: unknown inbound message type `\(raw.type, privacy: .public)`")
        }
    }

    /// Common decode-and-dispatch helper.  Decodes `raw.payloadJSON` into
    /// `T`, calls the handler on success, logs an error and discards on
    /// failure.  Generic so the call sites stay terse.
    private func decodeAndDispatch<T: Decodable>(
        _ raw: RawInboundMessage,
        type: T.Type,
        handler: (T) -> Void
    ) {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            let payload = try decoder.decode(T.self, from: raw.payloadJSON)
            handler(payload)
        } catch {
            // Bridge violation:  schema mismatch.  Log with the message
            // type so the offending sender is identifiable in os_log.
            logger.error("Bridge violation: payload decode failed for `\(raw.type, privacy: .public)` — \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Forward a JS-side `log` message to os_log at the requested
    /// severity.  Per CONVENTIONS.md "console.log is not for production"
    /// — every JS log line lands here so it's visible in Console.app
    /// alongside Swift logs.
    private func handleJSLog(_ payload: LogPayload) {
        let contextSuffix: String
        if let context = payload.context {
            contextSuffix = " \(context.compactJSONString())"
        } else {
            contextSuffix = ""
        }
        let line = "[js] \(payload.message)\(contextSuffix)"
        switch payload.level {
        case "debug":   logger.debug("\(line, privacy: .public)")
        case "info":    logger.info("\(line, privacy: .public)")
        case "warning": logger.warning("\(line, privacy: .public)")
        case "error":   logger.error("\(line, privacy: .public)")
        default:
            // Unknown level — log at error severity so a misbehaving
            // sender is loud rather than swallowed.
            logger.error("[js] (unknown level `\(payload.level, privacy: .public)`) \(line, privacy: .public)")
        }
    }
}
