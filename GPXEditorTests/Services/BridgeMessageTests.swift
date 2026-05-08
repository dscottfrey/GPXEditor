// BridgeMessageTests.swift
//
// Coverage for `RawInboundMessage.parse` — the JS→Swift envelope
// parser that's the entry point for every inbound bridge message.
// Validates the documented happy paths (type-only, type+id,
// type+payload, full envelope, payload survives round-trip) and each
// `BridgeEnvelopeError` case.  The dispatcher's per-type Codable
// decoders are tested separately;  this file exclusively covers the
// envelope layer.
//
// The bridge has been bitten by quiet-failure bugs before (M3 UUID
// case round-trip — silent disaster, no test caught it).  Hardening
// the envelope with explicit tests is the kind of scaffolding that
// pays for itself the next time someone touches the bridge.

import Testing
import Foundation
@testable import GPXEditor

@Suite("RawInboundMessage envelope parser")
struct BridgeMessageTests {

    // MARK: - Happy paths

    @Test("Full envelope: type + id + payload object")
    func fullEnvelope() throws {
        let body: [String: Any] = [
            "type": "ready",
            "id": "abc-123",
            "payload": ["editor_version": "1.0.0"],
        ]
        let raw = try RawInboundMessage.parse(body)
        #expect(raw.type == "ready")
        #expect(raw.id == "abc-123")
        // payloadJSON must round-trip back to the same object so the
        // per-type Codable decoder downstream has valid input.
        let decoded = try JSONSerialization.jsonObject(with: raw.payloadJSON) as? [String: String]
        #expect(decoded == ["editor_version": "1.0.0"])
    }

    @Test("Type + payload, no id")
    func noId() throws {
        let body: [String: Any] = [
            "type": "log",
            "payload": ["level": "info", "message": "hi"],
        ]
        let raw = try RawInboundMessage.parse(body)
        #expect(raw.type == "log")
        #expect(raw.id == nil)
    }

    @Test("Type only — missing payload defaults to empty object")
    func noPayloadIsEmptyObject() throws {
        let body: [String: Any] = ["type": "ready"]
        let raw = try RawInboundMessage.parse(body)
        #expect(raw.type == "ready")
        // Per BridgeMessage.swift's documented behaviour — a missing
        // payload field produces `{}` bytes so every handler's decode
        // path is uniform regardless of whether the sender omitted
        // the field.
        let decoded = try JSONSerialization.jsonObject(with: raw.payloadJSON) as? [String: Any]
        #expect(decoded != nil)
        #expect(decoded?.isEmpty == true)
    }

    @Test("Type + id, no payload")
    func typeAndIdNoPayload() throws {
        let body: [String: Any] = [
            "type": "query_segment_stats",
            "id": "req-42",
        ]
        let raw = try RawInboundMessage.parse(body)
        #expect(raw.type == "query_segment_stats")
        #expect(raw.id == "req-42")
    }

    @Test("Non-string id is silently dropped (treated as nil, not an error)")
    func nonStringIdIsNil() throws {
        // The comment in BridgeMessage.swift documents this:  the id
        // is "optional;  may be absent or non-string."  A number
        // where a string was expected becomes nil rather than an
        // error — id is a correlation aid, never load-bearing.
        let body: [String: Any] = [
            "type": "log",
            "id": 42,
            "payload": [:] as [String: Any],
        ]
        let raw = try RawInboundMessage.parse(body)
        #expect(raw.id == nil)
    }

    @Test("Nested payload object survives round-trip")
    func nestedPayload() throws {
        let body: [String: Any] = [
            "type": "points_selected",
            "payload": [
                "modifier": "replace",
                "selection": [
                    [
                        "track_id": "abc",
                        "segment_id": "def",
                        "point_indices": [1, 2, 3],
                    ]
                ],
            ],
        ]
        let raw = try RawInboundMessage.parse(body)
        #expect(raw.type == "points_selected")
        let decoded = try JSONSerialization.jsonObject(with: raw.payloadJSON) as? [String: Any]
        #expect(decoded?["modifier"] as? String == "replace")
        let selection = decoded?["selection"] as? [[String: Any]]
        #expect(selection?.first?["track_id"] as? String == "abc")
        #expect(selection?.first?["point_indices"] as? [Int] == [1, 2, 3])
    }

    @Test("Non-object payload (number) is preserved via fragmentsAllowed")
    func payloadIsPrimitive() throws {
        // The implementation passes `[.fragmentsAllowed]` to
        // JSONSerialization, so a payload that's a primitive (number,
        // string, bool) doesn't trip the parser.  Nothing in the
        // documented protocol uses primitive payloads — every
        // catalogued message has an object payload — but the
        // permissive shape is part of the parser's contract and worth
        // pinning so a future tightening surfaces as a test failure
        // rather than a silent regression.
        let body: [String: Any] = ["type": "test", "payload": 42]
        let raw = try RawInboundMessage.parse(body)
        let decoded = try JSONSerialization.jsonObject(with: raw.payloadJSON, options: [.fragmentsAllowed])
        #expect(decoded as? Int == 42)
    }

    // MARK: - Error cases

    @Test("Body is a string — notAnObject")
    func bodyIsString() {
        #expect(throws: BridgeEnvelopeError.self) {
            try RawInboundMessage.parse("hello")
        }
    }

    @Test("Body is a number — notAnObject")
    func bodyIsNumber() {
        #expect(throws: BridgeEnvelopeError.self) {
            try RawInboundMessage.parse(42)
        }
    }

    @Test("Body is an array — notAnObject")
    func bodyIsArray() {
        #expect(throws: BridgeEnvelopeError.self) {
            try RawInboundMessage.parse([1, 2, 3] as [Int])
        }
    }

    @Test("Type field absent — missingType")
    func typeMissing() {
        let body: [String: Any] = [
            "id": "abc",
            "payload": [:] as [String: Any],
        ]
        #expect(throws: BridgeEnvelopeError.self) {
            try RawInboundMessage.parse(body)
        }
    }

    @Test("Type is empty string — missingType")
    func typeEmpty() {
        let body: [String: Any] = ["type": ""]
        #expect(throws: BridgeEnvelopeError.self) {
            try RawInboundMessage.parse(body)
        }
    }

    @Test("Type is non-string (number) — missingType")
    func typeNonString() {
        let body: [String: Any] = ["type": 42]
        #expect(throws: BridgeEnvelopeError.self) {
            try RawInboundMessage.parse(body)
        }
    }

    // Note: `BridgeEnvelopeError.payloadNotJSONEncodable` has no
    // companion test in this suite.  It's a defensive case wrapping
    // any error thrown by JSONSerialization.data(withJSONObject:),
    // and reliably triggering that throw across macOS SDK versions
    // turned out to be fragile — Date, NaN, and bare NSObject
    // subclasses are all tolerated by JSONSerialization in newer SDK
    // versions via Foundation bridging that wasn't documented when
    // the parser was first written.  Since WKScriptMessage.body
    // delivers only JSON-derived types in production, the error case
    // exists as belt-and-suspenders rather than a code path
    // production traffic exercises.  If a deterministic trigger is
    // identified later (or this code path becomes load-bearing for
    // some future feature), add the test then.

    // MARK: - Error descriptions

    @Test("Each BridgeEnvelopeError case provides a non-empty description")
    func errorDescriptions() {
        // LocalizedError conformance is what makes errors readable in
        // os_log lines — empty descriptions would render as blank in
        // diagnostics.  Pin the contract:  every case has something
        // human-readable.
        let errors: [BridgeEnvelopeError] = [
            .notAnObject,
            .missingType,
            .payloadNotJSONEncodable(underlying: NSError(domain: "test", code: 1)),
        ]
        for err in errors {
            #expect(err.errorDescription != nil)
            #expect(err.errorDescription?.isEmpty == false)
        }
    }
}
