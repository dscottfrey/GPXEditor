// ElevationService.swift
//
// Async client for OpenTopoData (https://api.opentopodata.org), the
// public elevation-lookup service used by M7's Pin to Ground and
// Snap to Ground features.  Per D-020 the v1 dataset is `mapzen`:
// a global blend of SRTM / ASTER / GMTED2010 / NED / EU-DEM / ETOPO1
// hosted by OpenTopoData under that name.
//
// Why this is a dedicated service rather than inline URLSession calls
// at the call sites:
//   - Per SECURITY.md "Enforcement mechanism" every Swift-side
//     URLSession request must validate against
//     NetworkAllowList.swiftSideEndpoints.  Centralizing the request
//     path here is how we make that enforceable in one place rather
//     than relying on every future call site to remember.
//   - OpenTopoData's public server caps requests at 1 / second and
//     1000 / day.  A per-request rate limiter belongs in the service
//     so callers can fire off "fetch elevations for these N points"
//     without each writing the throttling state themselves.
//   - The service is testable with an injected URLSession backed by
//     a URLProtocol mock — no real network is touched in CI.
//
// Architecture:
//   - Public actor ElevationService — actor isolation protects the
//     "next-allowed-time" rate-limiter state from concurrent reads.
//   - Caller drives batching:  `makeBatches(of:)` is a pure static
//     that splits a query list into chunks of ≤100 (OpenTopoData's
//     per-request cap).  The caller iterates batches and updates UI
//     progress between calls.  Putting batching in the caller keeps
//     the service's I/O surface small and makes progress reporting
//     a caller-side concern (no callback / AsyncStream gymnastics).
//   - Per-batch fetch:  `fetchElevations(for:)` waits if needed to
//     honor the 1-req/sec gap, builds the request, validates the
//     URL host against the allow-list, sends, parses the response,
//     returns parallel optional elevations.  A 429 response with a
//     Retry-After header triggers a single retry after the indicated
//     wait;  any further failure surfaces as an error.
//
// Per CONVENTIONS.md "platform-agnostic data layer":  Foundation
// only, no AppKit / SwiftUI / WebKit.  This file IS still allowed
// because it doesn't import any of those — URLSession is Foundation.

import Foundation
import os

// MARK: - Public surface

/// A single point to look up.  Lat/lon in WGS84 decimal degrees.
public struct ElevationQuery: Sendable, Equatable {
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// Errors surfaced by ElevationService.  Per CONVENTIONS.md "Error
/// messages describe, don't accuse" the LocalizedError descriptions
/// describe what was attempted and what was observed without
/// pronouncing on what the user's network or input "is."
public enum ElevationServiceError: Error, LocalizedError, Sendable {

    /// The request URL's host is not in NetworkAllowList.swiftSideEndpoints.
    /// Should never reach a user under normal use — the service builds
    /// requests from a hardcoded host — but a future code change that
    /// changes the host without updating the allow-list trips this.
    case allowListViolation(host: String)

    /// URLSession reported a transport-layer failure (offline, DNS
    /// failure, TLS error, timeout).  The underlying error carries
    /// the specifics.
    case networkUnavailable(underlying: Error)

    /// HTTP returned a non-2xx status.  Body is included verbatim
    /// when small (≤1KB) for diagnostic visibility — OpenTopoData
    /// surfaces useful error text in the body.
    case httpError(statusCode: Int, bodySnippet: String?)

    /// The response was 2xx but couldn't be decoded against the
    /// expected OpenTopoData response shape.  Surfaces as a bridge-
    /// violation-style error since "service spoke a different
    /// protocol than expected" suggests a service change or a
    /// mid-flight redirect.
    case responseParseError(underlying: Error)

    /// 429 rate-limit response, retry exhausted.  The service retries
    /// once with the server's Retry-After delay;  if the second
    /// attempt also returns 429 (or otherwise fails) the caller sees
    /// this case so they can surface a "service is throttling us,
    /// please try again later" message.
    case rateLimited(retryAfterSeconds: TimeInterval?)

    /// The number of queries in a single batch exceeded the public
    /// service's per-request cap.  Should not occur under normal use
    /// — `makeBatches(of:)` enforces the cap — but defensively
    /// validated so a caller that hand-rolls batching gets a clear
    /// error rather than an opaque 4xx from the server.
    case batchTooLarge(count: Int, max: Int)

    public var errorDescription: String? {
        switch self {
        case .allowListViolation(let host):
            return "Elevation lookup attempted to reach `\(host)`, which is not in the network allow-list.  This is an internal configuration issue;  the request was blocked before going out."
        case .networkUnavailable(let underlying):
            return "Elevation lookup couldn't reach the network.  Underlying error: \(underlying.localizedDescription)."
        case .httpError(let code, let snippet):
            let suffix = snippet.map { " — \($0)" } ?? ""
            return "Elevation service returned HTTP \(code)\(suffix)."
        case .responseParseError(let underlying):
            return "Elevation service returned a response that didn't match the expected shape.  Underlying error: \(underlying.localizedDescription)."
        case .rateLimited(let retryAfter):
            let wait = retryAfter.map { " (server requested a wait of \(Int($0))s)" } ?? ""
            return "Elevation service is rate-limiting requests\(wait).  OpenTopoData's public server caps usage at 1 request per second and 1000 per day."
        case .batchTooLarge(let count, let max):
            return "Elevation request batch of \(count) points exceeds the per-request maximum of \(max).  Use `ElevationService.makeBatches(of:)` to split queries into compliant chunks."
        }
    }
}

/// Async client for OpenTopoData.  Actor-isolated so the rate-limiter
/// state ("when may the next request go?") can't be raced.  One
/// instance per running operation is fine;  a process-wide singleton
/// would also work but isn't necessary at v1's scale (one user, one
/// Pin to Ground operation in flight at a time).
public actor ElevationService {

    // MARK: - Constants

    /// OpenTopoData public-server per-request cap.  Hardcoded because
    /// changing it would require a service-side policy change at
    /// OpenTopoData;  no point making it configurable.  Per
    /// https://www.opentopodata.org/api/ as of D-020.
    public static let maxBatchSize = 100

    /// Minimum gap between outbound requests, in seconds.  OpenTopoData's
    /// public server caps at 1 / second.  Honoring this strictly means
    /// a fast network can still drive long batches at the rated pace —
    /// 5 batches = ~5 seconds plus latency, well within usability for
    /// typical track sizes.
    public static let minimumRequestInterval: TimeInterval = 1.0

    /// OpenTopoData dataset name per D-020 — global Mapzen Terrain
    /// Tiles blend.  Hardcoded;  a Settings-level dataset picker is
    /// in the deferred parking lot.
    public static let dataset = "mapzen"

    /// Host used for allow-list validation.  Must match (one of) the
    /// entries in NetworkAllowList.swiftSideEndpoints.
    public static let host = "api.opentopodata.org"

    // MARK: - Stored state

    private let urlSession: URLSession
    private let logger = Logger(subsystem: "com.gpxeditor.app.ElevationService", category: "elevation")

    /// Earliest wall-clock time the next outbound request may go.
    /// Initialized to .distantPast so the first request goes
    /// immediately;  updated to (now + minimumRequestInterval)
    /// after each request returns.
    private var nextAllowedRequestTime: Date = .distantPast

    // MARK: - Construction

    /// Construct with a custom URLSession (typically for tests, with
    /// a URLProtocol mock).  Default initialiser uses a session
    /// configured with the project-standard User-Agent per
    /// SECURITY.md "Identifying User-Agent."
    public init(urlSession: URLSession? = nil) {
        if let urlSession = urlSession {
            self.urlSession = urlSession
        } else {
            let config = URLSessionConfiguration.default
            // Identifying User-Agent — every Swift-side URLSession
            // call sets this per SECURITY.md.  Tile-server operators
            // and elevation services alike need to know who's calling
            // so they can correlate misbehavior to a specific build.
            config.httpAdditionalHeaders = [
                "User-Agent": Self.userAgentString()
            ]
            // Slightly tighter timeouts than URLSession's default 60s
            // — the public OpenTopoData server is responsive when up
            // and a long hang is more likely "service is wedged" than
            // "response is just slow."  20s leaves room for retry.
            config.timeoutIntervalForRequest = 20
            config.timeoutIntervalForResource = 60
            self.urlSession = URLSession(configuration: config)
        }
    }

    /// Project-standard User-Agent.  Mirrors MapView's userAgentString —
    /// duplicated here because the MapView form is private and the two
    /// concerns (WebView UA vs URLSession UA) are independent enough
    /// that a shared helper is more coupling than it's worth.  If a
    /// third call site emerges, factor out at that point.
    static func userAgentString() -> String {
        let identifier = "\(BuildInfo.gitSHA)\(BuildInfo.isDirty ? "+" : "")"
        return "GPXeditor/\(identifier) (+https://github.com/dscottfrey/GPXEditor)"
    }

    // MARK: - Batching (pure, exposed for the caller's progress loop)

    /// Split a list of queries into batches no larger than
    /// `maxBatchSize`.  Pure;  exposed as a static so callers can
    /// drive a per-batch progress loop with their UI between calls
    /// to `fetchElevations(for:)`.
    public static func makeBatches(of queries: [ElevationQuery]) -> [[ElevationQuery]] {
        guard !queries.isEmpty else { return [] }
        var result: [[ElevationQuery]] = []
        var i = 0
        while i < queries.count {
            let end = min(i + maxBatchSize, queries.count)
            result.append(Array(queries[i..<end]))
            i = end
        }
        return result
    }

    // MARK: - Per-batch fetch

    /// Look up elevations for a single batch.  Returns a parallel
    /// optional-Double array — `nil` at index `i` means "the service
    /// returned no elevation for queries[i]" (typically because the
    /// underlying DEM has no data at that location, e.g. mid-ocean
    /// outside ETOPO1's coverage).
    ///
    /// Throws an `ElevationServiceError` on any failure;  the caller
    /// surfaces a clear error to the user per "describe, don't accuse."
    public func fetchElevations(for queries: [ElevationQuery]) async throws -> [Double?] {

        // Defensive batch-size check — the static `makeBatches(of:)`
        // already enforces this, but a caller that hand-rolled
        // batching shouldn't hit a confusing 4xx from the server.
        guard queries.count <= Self.maxBatchSize else {
            throw ElevationServiceError.batchTooLarge(
                count: queries.count, max: Self.maxBatchSize
            )
        }
        guard !queries.isEmpty else { return [] }

        // Honor the rate-limiter:  sleep until at least
        // `minimumRequestInterval` seconds have passed since the last
        // request returned.
        try await sleepUntilAllowed()

        // Build and validate the request.
        let request = try makeRequest(for: queries)

        // First attempt.
        do {
            let elevations = try await performAndDecode(request: request, queries: queries)
            stampNextAllowedTime()
            return elevations
        } catch ElevationServiceError.rateLimited(let retryAfter) {
            // Single retry on 429 with the server-suggested wait.
            // If the server didn't send Retry-After, default to the
            // configured minimum interval — small and bounded so we
            // don't hang forever on a misbehaving server.
            let wait = retryAfter ?? Self.minimumRequestInterval
            logger.warning("Rate-limited;  retrying after \(wait, privacy: .public)s")
            try await Task.sleep(for: .seconds(wait))
            do {
                let elevations = try await performAndDecode(request: request, queries: queries)
                stampNextAllowedTime()
                return elevations
            } catch ElevationServiceError.rateLimited {
                // Still rate-limited after retry — surface so the
                // caller can show a useful message.
                stampNextAllowedTime()
                throw ElevationServiceError.rateLimited(retryAfterSeconds: retryAfter)
            }
        }
    }

    // MARK: - Internals

    /// Wait until `nextAllowedRequestTime`, if it's in the future.
    /// Threading is implicit:  the actor serializes calls to this
    /// method, so two concurrent `fetchElevations` calls naturally
    /// queue up rather than racing.
    private func sleepUntilAllowed() async throws {
        let now = Date()
        if now < nextAllowedRequestTime {
            let interval = nextAllowedRequestTime.timeIntervalSince(now)
            try await Task.sleep(for: .seconds(interval))
        }
    }

    /// Set the rate-limiter's clock for the next allowed request.
    private func stampNextAllowedTime() {
        nextAllowedRequestTime = Date().addingTimeInterval(Self.minimumRequestInterval)
    }

    /// Construct the URLRequest.  Validates the host against the
    /// allow-list before returning — per SECURITY.md every URLSession
    /// path validates here.
    private func makeRequest(for queries: [ElevationQuery]) throws -> URLRequest {

        // Build the locations string:  "lat,lon|lat,lon|..."  with
        // adequate float precision (10 fractional digits is more
        // than the API needs but well within float64).
        let locations = queries.map {
            "\(formatCoord($0.latitude)),\(formatCoord($0.longitude))"
        }.joined(separator: "|")

        // URL-encode the locations parameter — the `,` and `|`
        // characters are technically reserved and a strict server
        // could reject them.  OpenTopoData accepts both unencoded
        // and percent-encoded;  we encode for safety.
        var components = URLComponents()
        components.scheme = "https"
        components.host = Self.host
        components.path = "/v1/\(Self.dataset)"
        components.queryItems = [URLQueryItem(name: "locations", value: locations)]

        guard let url = components.url else {
            // URLComponents returning nil at this stage would mean a
            // genuinely malformed input — surface as parse error
            // because the caller has no way to act on it (the
            // queries themselves don't reach the wire format).
            throw ElevationServiceError.responseParseError(
                underlying: NSError(
                    domain: "ElevationService",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "URLComponents could not assemble request URL"]
                )
            )
        }

        // Allow-list enforcement — the canonical check that
        // SECURITY.md requires every URLSession-bound request to do.
        // Defensive:  the host is hardcoded above, so this should
        // never fire under normal operation.  But if a future code
        // change broadens the host or accidentally introduces a
        // redirect-following config without updating the allow-list,
        // we'd rather break loudly here than silently widen the
        // network surface.
        guard let host = url.host, NetworkAllowList.swiftSideEndpoints.contains(host) else {
            throw ElevationServiceError.allowListViolation(host: url.host ?? "<no host>")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        // Accept JSON explicitly — OpenTopoData defaults to JSON but
        // declaring it makes any content-negotiation surprises
        // surface clearly.
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// Format a coordinate to a stable string representation.  Uses
    /// `%.10f` and strips trailing zeros so 45.0 → "45" not "45.0000000000",
    /// keeping the URL short and human-diagnosable in logs.  Forces
    /// the C locale so a locale with comma-decimal-separator doesn't
    /// produce a malformed URL.
    private func formatCoord(_ value: Double) -> String {
        let formatted = String(format: "%.10f", locale: Locale(identifier: "en_US_POSIX"), value)
        // Trim trailing zeros and an orphan trailing dot.
        var trimmed = formatted
        while trimmed.last == "0" { trimmed.removeLast() }
        if trimmed.last == "." { trimmed.removeLast() }
        return trimmed
    }

    /// Send the request, parse the response, and return parallel
    /// optional elevations.  Maps URLSession errors and HTTP status
    /// codes to ElevationServiceError;  decoding errors likewise.
    private func performAndDecode(
        request: URLRequest,
        queries: [ElevationQuery]
    ) async throws -> [Double?] {

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw ElevationServiceError.networkUnavailable(underlying: error)
        }

        guard let http = response as? HTTPURLResponse else {
            // URLSession should always return an HTTPURLResponse for
            // an HTTP(S) URL.  If it didn't, treat as a parse error
            // since we have no status to surface.
            throw ElevationServiceError.responseParseError(
                underlying: NSError(
                    domain: "ElevationService",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Non-HTTP response received for HTTP request"]
                )
            )
        }

        // 429 — rate limited.  Read Retry-After and let the caller
        // (the catch in fetchElevations) decide whether to retry.
        if http.statusCode == 429 {
            let retryAfter = (http.value(forHTTPHeaderField: "Retry-After"))
                .flatMap(TimeInterval.init)
            throw ElevationServiceError.rateLimited(retryAfterSeconds: retryAfter)
        }

        guard (200..<300).contains(http.statusCode) else {
            // Non-2xx other than 429 — surface with a small body
            // snippet for diagnosis.  Cap at 1KB so a misbehaving
            // service spewing megabytes doesn't blow up the log.
            let snippet = data.prefix(1024)
            let snippetString = String(data: snippet, encoding: .utf8)
            throw ElevationServiceError.httpError(
                statusCode: http.statusCode,
                bodySnippet: snippetString
            )
        }

        // Decode the OpenTopoData response.
        let decoded: OpenTopoDataResponse
        do {
            decoded = try JSONDecoder().decode(OpenTopoDataResponse.self, from: data)
        } catch {
            throw ElevationServiceError.responseParseError(underlying: error)
        }

        // Per OpenTopoData docs the `results` array is parallel to the
        // request's `locations` order.  If the count doesn't match
        // (server bug or unexpected response), surface as parse error
        // — we have no defensible way to align partial results.
        guard decoded.results.count == queries.count else {
            throw ElevationServiceError.responseParseError(
                underlying: NSError(
                    domain: "ElevationService",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Response result count (\(decoded.results.count)) does not match query count (\(queries.count))"]
                )
            )
        }

        return decoded.results.map(\.elevation)
    }
}

// MARK: - Wire types

/// OpenTopoData JSON response shape.  Documented at
/// https://www.opentopodata.org/api/  — the `results` array is
/// parallel to the request's `locations` parameter, with a `null`
/// elevation when no data exists at that location.  Other fields
/// (`location`, `dataset`, `status`) are present in the response but
/// not used by the client;  declaring them here would just be
/// decoder overhead.
private struct OpenTopoDataResponse: Decodable {
    let results: [Result]

    struct Result: Decodable {
        let elevation: Double?
    }
}
