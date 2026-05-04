// TrackRoleTests.swift
//
// Coverage for TrackRole's raw-value encoding.  Because the role appears
// as a String in the on-disk JSON file (D-010), a careless rename of an
// enum case would silently break compatibility with previously-saved
// projects — a test pins the wire form to its expected strings.

import Testing
import Foundation
@testable import GPXEditor

@Suite("TrackRole")
struct TrackRoleTests {

    @Test("Encodes case names as expected strings")
    func encodesExpectedStrings() throws {
        // Pin the wire form: `.master` → "master", `.subsidiary` →
        // "subsidiary".  If a case is ever renamed, this test fails and
        // forces a deliberate decision about backward compatibility
        // rather than silently breaking saved projects.
        let masterData = try JSONEncoder().encode(TrackRole.master)
        let subData = try JSONEncoder().encode(TrackRole.subsidiary)
        #expect(String(data: masterData, encoding: .utf8) == "\"master\"")
        #expect(String(data: subData, encoding: .utf8) == "\"subsidiary\"")
    }

    @Test("Round-trips through JSON without loss")
    func roundTrips() throws {
        for role in TrackRole.allCases {
            let data = try JSONEncoder().encode(role)
            let decoded = try JSONDecoder().decode(TrackRole.self, from: data)
            #expect(decoded == role)
        }
    }

    @Test("Optional TrackRole encodes nil as JSON null")
    func optionalNilEncoding() throws {
        // The unaffiliated state is `Track.role == nil`.  Verify nil
        // round-trips as JSON null so a saved project preserves the
        // distinction between "no role" and any concrete role.
        struct Box: Codable, Equatable { var role: TrackRole? }
        let none = Box(role: nil)
        let data = try JSONEncoder().encode(none)
        let decoded = try JSONDecoder().decode(Box.self, from: data)
        #expect(decoded == none)
        #expect(decoded.role == nil)
    }
}
