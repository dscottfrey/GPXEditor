// ElevationServiceTests.swift
//
// Coverage for ElevationService:  the async OpenTopoData client at
// the heart of M7's Pin to Ground / Snap to Ground features.
//
// Tests don't touch the real network.  A small URLProtocol subclass
// (MockURLProtocol) intercepts every request the service issues and
// returns canned responses set up per test case.  This is the
// standard Apple-blessed pattern for testing URLSession code:
// register the protocol class on a URLSession, inject the session
// into the type under test, and the service can't tell it isn't
// talking to a real server.

import Testing
import Foundation
@testable import GPXEditor

// MARK: - URLProtocol mock

/// Test-only URLProtocol that lets the suite preconfigure the next
/// response (data + status code + headers, or an error).  Stateful
/// across tests by class storage;  reset before each test.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {

    /// Response queue.  Each entry is consumed in FIFO order;  the
    /// last one is reused if the test makes more requests than
    /// responses queued.  Tests should generally enqueue exactly one
    /// response per expected request and verify the request count
    /// via `requestHistory.count`.
    nonisolated(unsafe) static var responseQueue: [Response] = []

    /// History of every request that hit the protocol — captured for
    /// assertions about URL shape, headers, etc.
    nonisolated(unsafe) static var requestHistory: [URLRequest] = []

    enum Response {
        case success(data: Data, statusCode: Int, headers: [String: String])
        case failure(error: Error)
    }

    static func reset() {
        responseQueue = []
        requestHistory = []
    }

    /// Convenience to enqueue a JSON 200 response with the given body.
    static func enqueueJSON(_ jsonString: String, statusCode: Int = 200, headers: [String: String] = [:]) {
        responseQueue.append(.success(
            data: Data(jsonString.utf8),
            statusCode: statusCode,
            headers: headers
        ))
    }

    // MARK: URLProtocol overrides

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestHistory.append(self.request)

        // Drain the queue;  if empty, fall back to a 500 so a missing
        // queue entry surfaces loudly rather than hanging the test.
        let response: Response
        if Self.responseQueue.isEmpty {
            response = .failure(error: NSError(
                domain: "MockURLProtocol", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "No response queued for request to \(self.request.url?.absoluteString ?? "<nil>")"]
            ))
        } else {
            response = Self.responseQueue.removeFirst()
        }

        switch response {
        case .success(let data, let statusCode, let headers):
            let httpResponse = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
            client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)

        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() { /* nothing to clean up */ }
}

// MARK: - Test session helper

private func makeMockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    config.httpAdditionalHeaders = [
        "User-Agent": "GPXeditor/test (+test)"
    ]
    return URLSession(configuration: config)
}

// MARK: - Suite

@Suite("ElevationService", .serialized)
struct ElevationServiceTests {

    // MARK: - Batching (pure)

    @Test("makeBatches splits at the 100-point cap")
    func batchesSplitAtCap() {
        let queries = (0..<250).map {
            ElevationQuery(latitude: Double($0), longitude: 0)
        }
        let batches = ElevationService.makeBatches(of: queries)
        #expect(batches.count == 3)
        #expect(batches[0].count == 100)
        #expect(batches[1].count == 100)
        #expect(batches[2].count == 50)
    }

    @Test("makeBatches preserves order across the split")
    func batchesPreserveOrder() {
        let queries = (0..<150).map {
            ElevationQuery(latitude: Double($0), longitude: Double($0))
        }
        let batches = ElevationService.makeBatches(of: queries)
        let flat = batches.flatMap { $0 }
        #expect(flat == queries)
    }

    @Test("makeBatches on empty input returns empty array")
    func batchesEmpty() {
        #expect(ElevationService.makeBatches(of: []).isEmpty)
    }

    @Test("makeBatches under the cap returns a single batch")
    func batchesUnderCap() {
        let queries = (0..<10).map { _ in
            ElevationQuery(latitude: 0, longitude: 0)
        }
        let batches = ElevationService.makeBatches(of: queries)
        #expect(batches.count == 1)
        #expect(batches[0].count == 10)
    }

    // MARK: - URL construction

    @Test("Built URL targets api.opentopodata.org/v1/mapzen with locations parameter")
    func urlConstruction() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.enqueueJSON(#"{"results":[{"elevation":1234.5}]}"#)

        let service = ElevationService(urlSession: makeMockSession())
        _ = try await service.fetchElevations(for: [
            ElevationQuery(latitude: 45.0, longitude: -120.5)
        ])

        #expect(MockURLProtocol.requestHistory.count == 1)
        let url = try #require(MockURLProtocol.requestHistory.first?.url)
        #expect(url.host == "api.opentopodata.org")
        #expect(url.path == "/v1/mapzen")
        // Locations parameter contains the lat/lon (URL-encoded);
        // a substring check is sufficient — exact format may vary
        // by URLComponents quirks but the data must be present.
        let urlString = url.absoluteString
        #expect(urlString.contains("locations="))
        #expect(urlString.contains("45") && urlString.contains("120.5"))
    }

    @Test("Multi-point batch encodes locations separated by `|`")
    func urlMultiPoint() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.enqueueJSON(#"{"results":[{"elevation":100},{"elevation":200},{"elevation":300}]}"#)

        let service = ElevationService(urlSession: makeMockSession())
        _ = try await service.fetchElevations(for: [
            ElevationQuery(latitude: 45.0, longitude: -120.0),
            ElevationQuery(latitude: 46.0, longitude: -121.0),
            ElevationQuery(latitude: 47.0, longitude: -122.0),
        ])
        let url = try #require(MockURLProtocol.requestHistory.first?.url)
        // The `|` may be URL-encoded as %7C — accept either form.
        let raw = url.absoluteString.removingPercentEncoding ?? url.absoluteString
        #expect(raw.contains("45,-120") && raw.contains("46,-121") && raw.contains("47,-122"))
        #expect(raw.contains("|"))
    }

    // MARK: - Response parsing

    @Test("Parses parallel elevation array, preserving null entries as nil")
    func responseParsing() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.enqueueJSON(#"{"results":[{"elevation":1234.5},{"elevation":null},{"elevation":987.2}]}"#)

        let service = ElevationService(urlSession: makeMockSession())
        let result = try await service.fetchElevations(for: [
            ElevationQuery(latitude: 1, longitude: 2),
            ElevationQuery(latitude: 3, longitude: 4),
            ElevationQuery(latitude: 5, longitude: 6),
        ])
        #expect(result.count == 3)
        #expect(result[0] == 1234.5)
        #expect(result[1] == nil)
        #expect(result[2] == 987.2)
    }

    @Test("Mismatched result count surfaces as responseParseError")
    func responseCountMismatch() async throws {
        MockURLProtocol.reset()
        // Server returns 1 result but we asked for 2.
        MockURLProtocol.enqueueJSON(#"{"results":[{"elevation":100}]}"#)

        let service = ElevationService(urlSession: makeMockSession())
        await #expect(throws: ElevationServiceError.self) {
            _ = try await service.fetchElevations(for: [
                ElevationQuery(latitude: 1, longitude: 2),
                ElevationQuery(latitude: 3, longitude: 4),
            ])
        }
    }

    // MARK: - HTTP error handling

    @Test("HTTP 500 surfaces as httpError carrying status code")
    func http500() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.responseQueue.append(.success(
            data: Data("server is sad".utf8),
            statusCode: 500,
            headers: [:]
        ))
        let service = ElevationService(urlSession: makeMockSession())
        do {
            _ = try await service.fetchElevations(for: [
                ElevationQuery(latitude: 1, longitude: 2)
            ])
            Issue.record("Expected throw")
        } catch let ElevationServiceError.httpError(code, snippet) {
            #expect(code == 500)
            #expect(snippet?.contains("server is sad") == true)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("HTTP 429 with Retry-After is retried, then succeeds on second attempt")
    func http429RetriesOnce() async throws {
        MockURLProtocol.reset()
        // First response: 429, retry-after 0 (so the retry sleeps minimally).
        MockURLProtocol.responseQueue.append(.success(
            data: Data(),
            statusCode: 429,
            headers: ["Retry-After": "0"]
        ))
        // Second response: 200 with valid body.
        MockURLProtocol.enqueueJSON(#"{"results":[{"elevation":42}]}"#)

        let service = ElevationService(urlSession: makeMockSession())
        let result = try await service.fetchElevations(for: [
            ElevationQuery(latitude: 1, longitude: 2)
        ])
        #expect(result == [42])
        #expect(MockURLProtocol.requestHistory.count == 2)
    }

    @Test("HTTP 429 twice surfaces as rateLimited")
    func http429TwiceSurfaces() async throws {
        MockURLProtocol.reset()
        for _ in 0..<2 {
            MockURLProtocol.responseQueue.append(.success(
                data: Data(),
                statusCode: 429,
                headers: ["Retry-After": "0"]
            ))
        }
        let service = ElevationService(urlSession: makeMockSession())
        do {
            _ = try await service.fetchElevations(for: [
                ElevationQuery(latitude: 1, longitude: 2)
            ])
            Issue.record("Expected throw")
        } catch ElevationServiceError.rateLimited {
            // OK
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    // MARK: - Defensive checks

    @Test("Batch larger than 100 throws batchTooLarge before any network call")
    func oversizedBatch() async throws {
        MockURLProtocol.reset()
        let service = ElevationService(urlSession: makeMockSession())
        let queries = (0..<101).map { _ in
            ElevationQuery(latitude: 0, longitude: 0)
        }
        do {
            _ = try await service.fetchElevations(for: queries)
            Issue.record("Expected throw")
        } catch let ElevationServiceError.batchTooLarge(count, max) {
            #expect(count == 101)
            #expect(max == 100)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        // No network call should have been made.
        #expect(MockURLProtocol.requestHistory.isEmpty)
    }

    @Test("Empty batch returns empty result without a network call")
    func emptyBatch() async throws {
        MockURLProtocol.reset()
        let service = ElevationService(urlSession: makeMockSession())
        let result = try await service.fetchElevations(for: [])
        #expect(result.isEmpty)
        #expect(MockURLProtocol.requestHistory.isEmpty)
    }

    // MARK: - Allow-list (regression guard)

    @Test("Service host is in NetworkAllowList.swiftSideEndpoints")
    func hostIsAllowListed() {
        // This test would have caught the M7 mistake of "service URL
        // doesn't match the allow-list" — it ties the two together
        // so a future code change that changes one without the other
        // breaks the test loudly.
        #expect(NetworkAllowList.swiftSideEndpoints.contains(ElevationService.host))
    }
}
