// GPXEditorTests.swift
//
// Top-level placeholder for the GPXEditor test target.  Holds a single
// trivial smoke test so the test bundle compiles and the test scheme runs
// at M0; real test suites land alongside their subjects starting at M1
// (parser/writer round-trip in GPXEditorTests/Services, model invariants
// in GPXEditorTests/Models, fixtures in GPXEditorTests/Fixtures).

import Testing
@testable import GPXEditor

struct GPXEditorTests {
    @Test func smokeTest() async throws {
        // Sanity check: the test target links against the app module and
        // can run.  Real coverage starts in M1.
        #expect(Bool(true))
    }
}
