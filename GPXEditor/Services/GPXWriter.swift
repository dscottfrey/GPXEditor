// GPXWriter.swift
//
// GPX 1.1 emitter.  Pure "RawGPX -> XML" transform; D-012's export semantics
// (only the master track, drop per-point timestamps, no vendor color
// extensions) live in the export-action layer (M1 task #8) which builds
// the input RawGPX with those constraints already applied.  This separation
// keeps the writer testable in isolation:  parse(write(parsed)) round-trips
// exactly (modulo the version field — see below).
//
// Always emits GPX version 1.1 per D-012, regardless of input.  A RawGPX
// parsed from a 1.0 source round-trips through write-then-parse with
// version flipping from "1.0" to "1.1"; round-trip tests normalize for
// that one field.
//
// Fractional-second timestamps are preserved when present:  the writer
// detects sub-second precision in a Date and uses ISO8601DateFormatter's
// .withFractionalSeconds option only when needed.  Whole-second times
// emit the cleaner "2026-01-01T00:00:00Z" form most GPX files use.
//
// Implementation is direct string assembly rather than NSXMLDocument or a
// streaming writer.  GPX is small and structurally simple; a 50-line
// emitter is easier to read and modify than the framework alternatives,
// and it lets us control the exact output formatting (indentation,
// self-closing tags, attribute order) which matters for human-readable
// diffs and for matching the shape of our hand-written test fixtures.

import Foundation

/// Encode a `RawGPX` value to GPX 1.1 XML as UTF-8 bytes.
public enum GPXWriter {

    /// Emit `raw` as a complete GPX 1.1 document, returning UTF-8 bytes
    /// suitable for writing to a file or comparing against a fixture.
    /// The output is well-formed and parses cleanly through `GPXParser`.
    public static func write(_ raw: RawGPX) -> Data {
        var out = ""
        out.reserveCapacity(estimatedSize(raw))

        // XML declaration and root element open.  We always emit
        // version="1.1" regardless of the input's `version` field per
        // D-012; consumers that care about the source version should
        // read it from RawGPX before writing.
        out += "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        out += "<gpx version=\"1.1\""
        let creator = raw.creator ?? "GPXeditor"
        out += " creator=\"" + escapeAttribute(creator) + "\""
        out += " xmlns=\"http://www.topografix.com/GPX/1/1\">\n"

        // <metadata> wrapper, emitted only when at least one of its
        // children is present.  GPX 1.1 makes <metadata> itself optional;
        // a file with no metadata fields just doesn't include it rather
        // than having an empty <metadata/>.
        if raw.metadataName != nil || raw.metadataTime != nil {
            out += "  <metadata>\n"
            if let name = raw.metadataName {
                out += "    <name>" + escapeText(name) + "</name>\n"
            }
            if let time = raw.metadataTime {
                out += "    <time>" + formatDate(time) + "</time>\n"
            }
            out += "  </metadata>\n"
        }

        // Waypoints, in document order.  Per the GPX schema they appear
        // before tracks at the document level.
        for wpt in raw.waypoints {
            out += writeWaypoint(wpt)
        }

        // Tracks, in document order.
        for trk in raw.tracks {
            out += writeTrack(trk)
        }

        out += "</gpx>\n"
        return Data(out.utf8)
    }

    // MARK: - Per-element emission

    private static func writeTrack(_ trk: RawTrack) -> String {
        var s = "  <trk>\n"
        if let name = trk.name {
            s += "    <name>" + escapeText(name) + "</name>\n"
        }
        for seg in trk.segments {
            s += writeSegment(seg)
        }
        s += "  </trk>\n"
        return s
    }

    private static func writeSegment(_ seg: RawSegment) -> String {
        // Empty segments are spec-valid (GPX 1.1 schema sets
        // minOccurs=0 on <trkpt> inside <trkseg>).  Emit as a self-
        // closing tag for compactness.  D-012's segment-preservation
        // contract requires that empty segments survive round-trip,
        // so we never silently drop them here.
        if seg.points.isEmpty {
            return "    <trkseg/>\n"
        }
        var s = "    <trkseg>\n"
        for pt in seg.points {
            s += writePoint(pt)
        }
        s += "    </trkseg>\n"
        return s
    }

    private static func writePoint(_ pt: RawPoint) -> String {
        // <trkpt lat="..." lon="..."> — required attributes.  Use minimal-
        // precision Double formatting (Swift's default `String(Double)`)
        // which produces the shortest representation that round-trips
        // back to the same Double — e.g. 0.0001 stays "0.0001", not
        // "0.00009999999999999999".
        let head = "      <trkpt lat=\"" + formatDouble(pt.latitude) + "\" lon=\"" + formatDouble(pt.longitude) + "\""

        // Self-closing form when both <ele> and <time> are absent.
        if pt.elevation == nil && pt.time == nil {
            return head + "/>\n"
        }

        var s = head + ">\n"
        if let ele = pt.elevation {
            s += "        <ele>" + formatDouble(ele) + "</ele>\n"
        }
        if let time = pt.time {
            s += "        <time>" + formatDate(time) + "</time>\n"
        }
        s += "      </trkpt>\n"
        return s
    }

    private static func writeWaypoint(_ wpt: RawWaypoint) -> String {
        let head = "  <wpt lat=\"" + formatDouble(wpt.latitude) + "\" lon=\"" + formatDouble(wpt.longitude) + "\""

        let hasContent = wpt.elevation != nil
            || wpt.time != nil
            || wpt.name != nil
            || wpt.sym != nil
            || wpt.description != nil
        if !hasContent {
            return head + "/>\n"
        }

        var s = head + ">\n"
        // Order matches the GPX 1.1 schema's wptType sequence: ele, time,
        // ... name, ..., desc, ..., sym.  The schema is strict about
        // child order; emitting in the wrong order would produce a file
        // that some validators reject, even though our own parser is
        // order-tolerant.
        if let ele = wpt.elevation {
            s += "    <ele>" + formatDouble(ele) + "</ele>\n"
        }
        if let time = wpt.time {
            s += "    <time>" + formatDate(time) + "</time>\n"
        }
        if let name = wpt.name {
            s += "    <name>" + escapeText(name) + "</name>\n"
        }
        if let desc = wpt.description {
            s += "    <desc>" + escapeText(desc) + "</desc>\n"
        }
        if let sym = wpt.sym {
            s += "    <sym>" + escapeText(sym) + "</sym>\n"
        }
        s += "  </wpt>\n"
        return s
    }

    // MARK: - Formatting helpers

    /// Format a Double using Swift's default minimum-precision string
    /// representation.  Round-trips through `Double(String)` exactly.
    private static func formatDouble(_ d: Double) -> String {
        return String(d)
    }

    /// Format a Date as ISO 8601, using fractional seconds only when the
    /// Date carries a non-zero sub-second component.  This keeps whole-
    /// second timestamps clean ("2026-01-01T00:00:00Z") while still
    /// preserving fractional precision through a parse-write-parse round
    /// trip when it was present in the original source.
    private static func formatDate(_ d: Date) -> String {
        let total = d.timeIntervalSinceReferenceDate
        let frac = abs(total - total.rounded())
        // 1ms tolerance for floating-point noise on whole-second Dates.
        // Fractional seconds finer than 1ms aren't commonly emitted by
        // the GPS hardware that produces source files, so this threshold
        // is comfortably below the precision of any realistic input.
        if frac < 0.001 {
            return plainISO.string(from: d)
        }
        return fractionalISO.string(from: d)
    }

    private static let plainISO: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let fractionalISO: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Escape XML attribute value characters.  Attributes are double-
    /// quoted, so " must escape; & < > are universal.  ' is escaped for
    /// good measure (some XML strict-parsers reject unescaped apostrophes
    /// inside quoted attrs).
    private static func escapeAttribute(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "&":  out += "&amp;"
            case "<":  out += "&lt;"
            case ">":  out += "&gt;"
            case "\"": out += "&quot;"
            case "'":  out += "&apos;"
            default:   out.append(ch)
            }
        }
        return out
    }

    /// Escape XML element-content characters.  Only & < > require
    /// escaping in text content; quotes and apostrophes are literal.
    private static func escapeText(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            default:  out.append(ch)
            }
        }
        return out
    }

    /// Estimate the output size to pre-reserve a capacity-appropriate
    /// String buffer.  Off-by-a-factor doesn't matter for correctness;
    /// this just avoids a few internal reallocations during emission.
    private static func estimatedSize(_ raw: RawGPX) -> Int {
        // ~120 bytes of fixed overhead (XML decl + <gpx> + </gpx> +
        // optional <metadata>) plus an estimated per-point cost.
        var bytes = 200
        for trk in raw.tracks {
            bytes += 64  // <trk><name>...</name></trk> overhead
            for seg in trk.segments {
                bytes += 32  // <trkseg></trkseg> overhead
                bytes += seg.points.count * 96  // ~96 bytes per <trkpt>
            }
        }
        bytes += raw.waypoints.count * 128  // ~128 bytes per <wpt>
        return bytes
    }
}
