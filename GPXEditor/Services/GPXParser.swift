// GPXParser.swift
//
// GPX 1.0 / 1.1 parser built on stdlib `XMLParser`.  Public API is a single
// static function; the actual delegate machinery lives in a private class
// inside this file because XMLParserDelegate must be an NSObject subclass
// and we don't want that requirement leaking into the public surface.
//
// Design choices:
//
// - Returns `Result<RawGPX, GPXParseError>` (per CONVENTIONS.md "Errors and
//   Result").  Throws would force callers into a do/catch pattern even when
//   they want to inspect specific failure cases; Result lets the call site
//   `switch` cleanly on the failure.
//
// - Produces `RawGPX` (defined in RawGPX.swift) — the raw shape of the XML.
//   Promotion to a fully-populated `Track` (with UUIDs, palette colors, the
//   D-008 immutable-original-bytes blob) happens in the importer (M1 task
//   #8), not here.  Keeps the parser focused on one job.
//
// - `<extensions>` blocks are deliberately ignored.  Garmin TrackPointExtension,
//   Strava extensions, and other vendor namespaces survive a round-trip via
//   the immutable-original-bytes path (D-008, Q2 in M1 design pass) — the
//   parsed working-state model never sees them, so the writer doesn't have
//   to emit them and the data model stays compact.  The parser walks past
//   them naturally because the parent-context check in `didEndElement`
//   only acts on `<time>`, `<ele>`, `<name>`, etc. when their parent is a
//   recognized container (`metadata`, `trk`, `trkpt`, `wpt`).
//
// - `XMLParser.shouldProcessNamespaces` is left at its default of `false`,
//   so vendor-prefixed elements (`gpxtpx:hr`, `gpxx:Color`, etc.) come
//   through with their prefix intact and naturally don't match any case in
//   our switch.  Plain GPX elements (under the default namespace) come
//   through unprefixed.  This is the conservative choice — turning namespace
//   processing on would strip prefixes from everything, which means a
//   vendor `<gpxx:name>` could accidentally match our `<name>` handler.
//
// - Error reporting:  XMLParser-level errors (malformed XML, encoding
//   problems, mismatched tags) are wrapped into `.invalidXML(message:)`
//   with line/column folded into the message.  Domain-specific errors
//   (unsupported version, malformed coordinate, etc.) are raised by
//   delegate code via the `raise(_:on:)` helper, which records the first
//   error and aborts further parsing — we never silently keep going after
//   a structural problem ("Nothing fails silently" per CONVENTIONS.md).

import Foundation

/// Parses GPX 1.0 / 1.1 XML data into a `RawGPX` value, or returns a
/// structured error describing the first problem encountered.
public enum GPXParser {

    /// Parse `data` as GPX XML.  Returns the parsed `RawGPX` on success or
    /// a `GPXParseError` describing the first failure on the way through.
    public static func parse(_ data: Data) -> Result<RawGPX, GPXParseError> {
        let delegate = ParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate

        // `parser.parse()` returns false either when XMLParser itself
        // raised an error (malformed XML) or when our delegate aborted via
        // `parser.abortParsing()`.  We disambiguate by checking which
        // source raised: delegate errors win, since they're more specific
        // (e.g., we know it was an unsupported version, not just a generic
        // XML problem).
        let parsedOK = parser.parse()

        if let raised = delegate.raisedError {
            return .failure(raised)
        }

        if !parsedOK {
            // No delegate-raised error means XMLParser failed for its own
            // reasons.  Build a useful message with line/column.
            let underlying = parser.parserError as NSError?
            let summary = underlying?.localizedDescription ?? "Unknown XML parse error"
            let message = "\(summary) (line \(parser.lineNumber), column \(parser.columnNumber))"
            return .failure(.invalidXML(message: message))
        }

        return .success(delegate.gpx)
    }
}

// MARK: - Private delegate

/// Internal `XMLParserDelegate`.  Builds up `gpx` incrementally by walking
/// element-start / element-end / character callbacks.  Stack-based: the
/// `elementStack` records the nesting context so that `didEndElement` can
/// inspect the parent of the closing element when deciding what to do with
/// its accumulated text content.
private final class ParserDelegate: NSObject, XMLParserDelegate {

    /// The result accumulator.  Gradually filled in across many delegate
    /// callbacks; returned from the public API on success.
    var gpx = RawGPX()

    /// First error encountered, if any.  Subsequent errors are dropped
    /// (the parser is aborted as soon as one is raised).  `nil` until an
    /// error fires.
    var raisedError: GPXParseError?

    // MARK: Internal state

    /// Stack of currently-open element names, in nesting order.  The
    /// element being closed in `didEndElement` is at the top; its parent
    /// is one below.  Used so the same element name (e.g., `<time>`,
    /// `<name>`) can be routed to different fields depending on its
    /// parent context.
    private var elementStack: [String] = []

    /// Accumulated text content of the current element.  Reset on every
    /// `didStartElement` and consumed (then cleared) in `didEndElement`.
    /// XMLParser may invoke `foundCharacters` multiple times for a single
    /// text run (e.g., across a CDATA boundary), so we accumulate before
    /// processing.
    private var textBuffer: String = ""

    /// In-progress structures.  Each is set when its opening element is
    /// seen and cleared when its closing element is seen, at which point
    /// the completed value is appended to its parent collection.

    private var currentTrack: RawTrack?
    private var currentSegment: RawSegment?
    private var currentPoint: RawPoint?
    private var currentWaypoint: RawWaypoint?

    // MARK: Date parsing

    /// ISO 8601 formatter for the standard "2026-05-04T14:32:00Z" form
    /// without fractional seconds.  GPX recordings overwhelmingly use this
    /// shape, so try it first.
    private let plainISO: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// ISO 8601 formatter for the fractional-second variant
    /// ("2026-05-04T14:32:00.123Z").  Some apps (Strava, fitness watches
    /// with sub-second precision) emit this form; others don't.  Try only
    /// after the plain formatter fails.
    private let fractionalISO: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Parse an ISO 8601 timestamp using the plain form first, falling
    /// back to fractional-second.  Returns nil if neither matches; the
    /// caller raises `.malformedTimestamp` in that case.
    private func parseDate(_ s: String) -> Date? {
        if let d = plainISO.date(from: s) { return d }
        return fractionalISO.date(from: s)
    }

    // MARK: Error helper

    /// Record an error and abort the parser.  Subsequent callbacks are
    /// suppressed — once we've decided the document is broken, we don't
    /// pretend to keep parsing it.
    private func raise(_ err: GPXParseError, on parser: XMLParser) {
        if raisedError == nil {
            raisedError = err
        }
        parser.abortParsing()
    }

    // MARK: XMLParserDelegate — element start

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        // First-element check — a GPX document must have <gpx> as its root.
        // Anything else (HTML, plain XML of a different schema) gets a
        // specific error rather than a confusing partial-parse.
        let isRoot = elementStack.isEmpty
        elementStack.append(elementName)
        textBuffer = ""

        if isRoot && elementName != "gpx" {
            raise(.unexpectedRootElement(found: elementName), on: parser)
            return
        }

        switch elementName {

        case "gpx":
            // Capture version and creator from attributes.  Reject any
            // version we don't support before reading further — there's no
            // point parsing a GPX 0.5 or imaginary 2.0 file with our
            // 1.0/1.1 logic and silently producing garbage.
            gpx.version = attributeDict["version"]
            gpx.creator = attributeDict["creator"]
            if let v = gpx.version, v != "1.0" && v != "1.1" {
                raise(.unsupportedVersion(v), on: parser)
                return
            }

        case "wpt":
            // Document-level <wpt lat="..." lon="...">.  lat and lon are
            // required by the GPX schema; we treat their absence as a
            // structural failure.
            guard let parsed = parseLatLon(elementName: "wpt", attributes: attributeDict, parser: parser) else {
                return  // raise(...) was already called inside the helper
            }
            currentWaypoint = RawWaypoint(latitude: parsed.lat, longitude: parsed.lon)

        case "trk":
            currentTrack = RawTrack()

        case "trkseg":
            currentSegment = RawSegment()

        case "trkpt":
            // <trkpt lat="..." lon="..."> — same coordinate-attribute
            // contract as <wpt>.
            guard let parsed = parseLatLon(elementName: "trkpt", attributes: attributeDict, parser: parser) else {
                return
            }
            currentPoint = RawPoint(latitude: parsed.lat, longitude: parsed.lon)

        default:
            // Other elements (metadata, name, time, ele, sym, desc, extensions,
            // and anything in vendor namespaces) are handled in didEndElement
            // based on their text buffer + parent context.  Many vendor
            // extension elements simply fall through here and never produce
            // any parsed output — that's intentional (D-008 / Q2 design).
            break
        }
    }

    /// Parse the `lat` and `lon` attributes of a `<trkpt>` or `<wpt>`,
    /// raising the appropriate error and returning nil on failure.
    /// Factored out so trkpt and wpt share the same validation logic
    /// without copy-pasting four guard statements each.
    private func parseLatLon(
        elementName: String,
        attributes: [String: String],
        parser: XMLParser
    ) -> (lat: Double, lon: Double)? {
        guard let latStr = attributes["lat"], let lonStr = attributes["lon"] else {
            // Report the missing attribute(s) explicitly.  When both are
            // missing we report "lat or lon" rather than picking one
            // arbitrarily — saves the caller from a follow-up error after
            // fixing only the first.
            let missing: String
            if attributes["lat"] == nil && attributes["lon"] == nil {
                missing = "lat or lon"
            } else if attributes["lat"] == nil {
                missing = "lat"
            } else {
                missing = "lon"
            }
            raise(.missingRequiredAttribute(element: elementName, attribute: missing), on: parser)
            return nil
        }
        guard let lat = Double(latStr) else {
            raise(.malformedCoordinate(element: elementName, attribute: "lat", value: latStr), on: parser)
            return nil
        }
        guard let lon = Double(lonStr) else {
            raise(.malformedCoordinate(element: elementName, attribute: "lon", value: lonStr), on: parser)
            return nil
        }
        return (lat, lon)
    }

    // MARK: XMLParserDelegate — character data

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        // Accumulate.  XMLParser may invoke this multiple times per text
        // run (across CDATA boundaries, internal buffer flushes, etc.);
        // didEndElement is the single point where we look at the result.
        textBuffer += string
    }

    // MARK: XMLParserDelegate — element end

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        // Capture and trim the accumulated text BEFORE popping the stack,
        // so the parent-context lookup below sees the still-current state.
        let trimmed = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        textBuffer = ""

        // The element being closed is at elementStack.last; its parent is
        // one below.  Both can be nil in pathological cases (mismatched
        // tags) — we tolerate that by using safe optional access.
        let parent: String? = elementStack.count >= 2
            ? elementStack[elementStack.count - 2]
            : nil

        switch elementName {

        case "name":
            // <name> appears in <metadata>, <trk>, and <wpt>.  Parent
            // context disambiguates.  Empty string is normalized to nil
            // so the importer's "no name supplied" fallback engages.
            //
            // The "metadata" / "gpx" parents both map to the file-level
            // metadata name:  GPX 1.1 wraps file metadata in <metadata>,
            // but GPX 1.0 places it as direct children of <gpx>.  We
            // honor both placements so a 1.0 file's <name> isn't silently
            // dropped.
            let value = trimmed.isEmpty ? nil : trimmed
            switch parent {
            case "metadata", "gpx": gpx.metadataName = value
            case "trk":             currentTrack?.name = value
            case "wpt":             currentWaypoint?.name = value
            default:                break  // <name> in extensions or unknown context — ignore.
            }

        case "time":
            // <time> appears in <metadata> (1.1) or directly in <gpx> (1.0)
            // for the file-level recording time, plus inside <trkpt> and
            // <wpt> for per-point timestamps.  We only attempt to parse
            // the timestamp when parent is a recognized container — a
            // stray <time> inside <extensions> is ignored rather than
            // raising .malformedTimestamp on something we never intended
            // to consume.
            switch parent {
            case "metadata", "gpx":
                guard let date = parseDate(trimmed) else {
                    raise(.malformedTimestamp(value: trimmed), on: parser)
                    return
                }
                gpx.metadataTime = date
            case "trkpt":
                guard let date = parseDate(trimmed) else {
                    raise(.malformedTimestamp(value: trimmed), on: parser)
                    return
                }
                currentPoint?.time = date
            case "wpt":
                guard let date = parseDate(trimmed) else {
                    raise(.malformedTimestamp(value: trimmed), on: parser)
                    return
                }
                currentWaypoint?.time = date
            default:
                break
            }

        case "ele":
            // <ele> appears in <trkpt> and <wpt>.  Empty/whitespace is
            // treated as "no elevation supplied" — leave the field nil.
            // A non-empty value that fails Double parsing is a structural
            // error: GPX requires <ele> contents to be a number.
            if !trimmed.isEmpty {
                guard let elevation = Double(trimmed) else {
                    raise(.malformedCoordinate(element: parent ?? "?", attribute: "ele", value: trimmed), on: parser)
                    return
                }
                switch parent {
                case "trkpt": currentPoint?.elevation = elevation
                case "wpt":   currentWaypoint?.elevation = elevation
                default:      break
                }
            }

        case "sym":
            // <sym> is waypoint-only.  Empty string normalizes to nil
            // for the same reason as <name>.
            if parent == "wpt" {
                currentWaypoint?.sym = trimmed.isEmpty ? nil : trimmed
            }

        case "desc":
            // GPX <desc> can appear on tracks, waypoints, and routes.  We
            // only capture it on waypoints — the working-state model
            // doesn't currently expose a per-track description, and
            // route support is out of scope for this project.
            if parent == "wpt" {
                currentWaypoint?.description = trimmed.isEmpty ? nil : trimmed
            }

        case "trkpt":
            // Close the in-progress point and append it to its segment.
            // Defensive nil-coalescing: a malformed file with </trkpt>
            // before any <trkpt lat=...> would have set currentPoint = nil
            // (or never set it); silently dropping that case is safer than
            // crashing.
            if let p = currentPoint {
                currentSegment?.points.append(p)
            }
            currentPoint = nil

        case "trkseg":
            if let s = currentSegment {
                currentTrack?.segments.append(s)
            }
            currentSegment = nil

        case "trk":
            if let t = currentTrack {
                gpx.tracks.append(t)
            }
            currentTrack = nil

        case "wpt":
            if let w = currentWaypoint {
                gpx.waypoints.append(w)
            }
            currentWaypoint = nil

        default:
            // Unrecognized closing tag — likely a vendor-extension element
            // or a GPX field we don't currently model (cmt, src, link,
            // route, etc.).  Drop quietly; D-008 / Q2 keep extension
            // round-trip via the immutable-original-bytes path, not via
            // the working-state model.
            break
        }

        // Pop the stack last.  Done after the switch so the parent-context
        // calculation above saw the correct depth.
        if !elementStack.isEmpty {
            elementStack.removeLast()
        }
    }

    // MARK: XMLParserDelegate — bottom-level errors

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        // XMLParser hit a syntactic problem (malformed XML, encoding
        // error, mismatched tags).  Wrap it into our domain error type
        // unless we already raised something more specific from delegate
        // code (e.g., .unsupportedVersion).
        if raisedError == nil {
            let summary = parseError.localizedDescription
            let message = "\(summary) (line \(parser.lineNumber), column \(parser.columnNumber))"
            raisedError = .invalidXML(message: message)
        }
    }
}
