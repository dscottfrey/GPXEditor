// MapBridge.swift
//
// The Swift side of the JS↔Swift bridge.  Owns three responsibilities,
// per Docs/02_MAP_AND_BRIDGE.md:
//
//   1. Inbound:  conform to WKScriptMessageHandler;  parse the envelope
//      via RawInboundMessage.parse(_:);  hand the parsed message to
//      MessageDispatcher.
//   2. Outbound:  serialize an OutboundMessage to JSON, call
//      `webView.evaluateJavaScript("window.gpxEditor.handleMessage(...)")`.
//   3. Lifecycle:  register/unregister the script message handler on the
//      WebView's user content controller.
//
// `MapBridge` is one of the two `Services/` files that imports WebKit
// (the other being ContentRuleListBuilder).  CONVENTIONS.md "platform-
// agnostic data layer" carves out exactly these two — no other Services
// type may import WebKit.
//
// The bridge is `@MainActor`-bound because WKWebView's APIs are
// main-actor-isolated.  All inbound handler calls and outbound
// evaluateJavaScript calls happen on the main actor.

import Foundation
import WebKit
import os

/// The script message handler name.  JS posts via
/// `window.webkit.messageHandlers.gpxBridge.postMessage(...)`.  The name
/// is the only naming contract between Swift and JS;  changing it here
/// requires changing the corresponding postToSwift call in editor.js.
private let kScriptMessageHandlerName = "gpxBridge"

/// The Swift side of the JS↔Swift bridge.  Hold one instance per
/// WKWebView (lifetime tied to the WebView).  The bridge keeps a weak
/// reference to the WebView to break the otherwise-circular ownership
/// (WebView → userContentController → handler → WebView).
@MainActor
public final class MapBridge: NSObject {

    /// Logger subsystem matches Docs/02_MAP_AND_BRIDGE.md "Bridge
    /// violations and logging."
    private let logger = Logger(subsystem: "com.gpxeditor.app.MapBridge", category: "bridge")

    /// Weak reference to the WebView.  Set when MapView attaches the
    /// bridge to a freshly-constructed WebView;  cleared automatically
    /// when the WebView deallocates.
    private weak var webView: WKWebView?

    /// The dispatcher this bridge feeds inbound messages into.  Owned
    /// by the bridge so its lifetime matches.
    public let dispatcher: MessageDispatcher

    /// Construct a bridge.  The dispatcher parameter defaults to nil so
    /// the default-argument expression is a sendable literal (Swift 6
    /// strict-concurrency forbids calling a main-actor-isolated init —
    /// which `MessageDispatcher.init` is, by inference — from the
    /// non-isolated default-argument evaluation context).  When the
    /// caller passes nil (or omits the argument) the dispatcher is
    /// constructed inside `init`, which IS main-actor-isolated, so the
    /// MessageDispatcher() call satisfies the isolation rule.
    public init(dispatcher: MessageDispatcher? = nil) {
        self.dispatcher = dispatcher ?? MessageDispatcher()
        super.init()
    }

    /// Attach to a freshly-constructed WebView.  Adds `self` as the
    /// `gpxBridge` script message handler on the WebView's user content
    /// controller.  Call exactly once per WebView;  re-attaching to a
    /// different WebView would leak the original.
    public func attach(to webView: WKWebView) {
        if self.webView != nil {
            // Defensive — calling attach twice is a programmer bug.
            // Surface it loudly rather than silently re-binding.
            logger.fault("MapBridge.attach called twice;  prior WebView reference will be replaced")
        }
        self.webView = webView
        webView.configuration.userContentController.add(
            ScriptMessageHandlerProxy(target: self),
            name: kScriptMessageHandlerName
        )
    }

    /// Detach from the WebView.  Removes the script message handler.
    /// Called from MapView's dismantleNSView when SwiftUI tears down
    /// the representable.
    public func detach() {
        guard let webView = self.webView else { return }
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: kScriptMessageHandlerName
        )
        self.webView = nil
    }

    /// Send an outbound message to JS.  Encodes the envelope, hands it
    /// to evaluateJavaScript wrapped in the dispatcher entry point JS
    /// expects (`window.gpxEditor.handleMessage(...)`).  Errors during
    /// encoding or evaluation are logged and discarded — they're
    /// programmer bugs, not user-visible failures, and the next message
    /// has no dependency on the previous one's success.
    public func send(_ message: OutboundMessage) {
        guard let webView = self.webView else {
            logger.error("MapBridge.send called with no attached WebView; message dropped: \(message.type, privacy: .public)")
            return
        }
        let json: String
        do {
            let data = try message.encode()
            guard let s = String(data: data, encoding: .utf8) else {
                logger.error("MapBridge: outbound `\(message.type, privacy: .public)` not UTF-8 encodable")
                return
            }
            json = s
        } catch {
            logger.error("MapBridge: outbound `\(message.type, privacy: .public)` encode failed — \(error.localizedDescription, privacy: .public)")
            return
        }

        // The injected expression escapes the JSON safely:  we rely on
        // JSON's syntactic compatibility with JavaScript object
        // literals, so the JSON string is a valid JS expression that
        // produces an object.  Wrapped in `(...)` to disambiguate from
        // a labeled-statement parse if the JSON happened to start with
        // an identifier-like character (which it doesn't, since it
        // starts with `{`, but the parens cost nothing and make the
        // expression unambiguously a value).
        let expression = "window.gpxEditor.handleMessage((\(json)));"
        webView.evaluateJavaScript(expression) { [weak self] _, error in
            if let error = error {
                self?.logger.error("MapBridge: evaluateJavaScript failed for `\(message.type, privacy: .public)` — \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Inbound entry point;  called by `ScriptMessageHandlerProxy` (the
    /// proxy exists to break the WKScriptMessageHandler-as-NSObject
    /// retain cycle).  Parses the envelope, hands the parsed message to
    /// the dispatcher.  Per CONVENTIONS.md "Nothing fails silently" all
    /// errors here are logged at error severity and the message is
    /// discarded.
    fileprivate func receive(_ message: WKScriptMessage) {
        guard message.name == kScriptMessageHandlerName else {
            // Should not occur — we only register one handler — but
            // defend against future expansion that adds more handlers
            // and might wire them to the same target by accident.
            logger.error("MapBridge received message on unexpected handler `\(message.name, privacy: .public)`")
            return
        }
        do {
            let raw = try RawInboundMessage.parse(message.body)
            dispatcher.dispatch(raw)
        } catch {
            logger.error("Bridge violation: envelope parse failed — \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// Proxy that satisfies WKScriptMessageHandler's NSObject conformance
/// without forcing MapBridge to be an @objc-able subclass that would
/// retain the WebView through the user content controller.  The proxy
/// holds a weak reference to MapBridge — when MapBridge deallocates,
/// the proxy still exists (held by WebKit) but quietly drops messages.
/// Detach() should be called before the WebView itself deallocates so
/// this scenario doesn't normally arise.
private final class ScriptMessageHandlerProxy: NSObject, WKScriptMessageHandler {

    private weak var target: MapBridge?

    init(target: MapBridge) {
        self.target = target
        super.init()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        // WKScriptMessageHandler is non-isolated;  WebKit calls us on
        // the main thread but the protocol doesn't express that.
        // MainActor.assumeIsolated bridges the gap without an extra
        // hop;  the implicit assumption (we are on main) is enforced
        // by macOS 14's WebKit and is documented in WKWebView's API.
        MainActor.assumeIsolated {
            target?.receive(message)
        }
    }
}
