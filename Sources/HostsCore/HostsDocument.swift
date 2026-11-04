import Foundation

/// Why the `# BEGIN: bork-hosts` / `# END: bork-hosts` markers cannot be trusted.
public enum BlockDamage: Equatable, Sendable {
    /// A BEGIN line with no END line after it.
    case missingEnd
    /// An END line with no BEGIN line before it.
    case missingBegin
    /// One BEGIN and one END, in the wrong order.
    case endBeforeBegin
    /// More than one BEGIN or more than one END.
    case duplicateMarker

    /// Plain-language problem statement. It names the markers and never quotes file content.
    public var problem: String {
        switch self {
        case .missingEnd: return "The hosts file has a \"\(HostsDocument.beginMarker)\" line but no \"\(HostsDocument.endMarker)\" line after it."
        case .missingBegin: return "The hosts file has a \"\(HostsDocument.endMarker)\" line but no \"\(HostsDocument.beginMarker)\" line before it."
        case .endBeforeBegin: return "The \"\(HostsDocument.endMarker)\" line comes before the \"\(HostsDocument.beginMarker)\" line."
        case .duplicateMarker: return "The hosts file has more than one \"\(HostsDocument.beginMarker)\" line or more than one \"\(HostsDocument.endMarker)\" line."
        }
    }
}

/// The hosts file as raw segments, each keeping its own terminator, so `text` is a plain join.
/// Only `\n` and `\r\n` terminate a segment; a lone `\r` stays inside the segment body.
///
/// Every edit is confined to the managed block: the segments strictly between the marker lines.
/// Lines outside the block are never matched, edited or removed.
public struct HostsDocument: Equatable, Sendable {
    struct Parsed: Equatable, Sendable {
        var commented: Bool
        /// Scalar index just past leading whitespace, where `# ` is inserted and removed.
        var leadEnd: Int
        var ipRange: Range<Int>
        var hostRanges: [Range<Int>]
        var ipKey: [UInt8]
    }

    struct Segment: Equatable, Sendable {
        var body: [Unicode.Scalar]
        var terminator: [Unicode.Scalar]
        var parsed: Parsed?

        init(body: [Unicode.Scalar], terminator: [Unicode.Scalar]) {
            self.body = body
            self.terminator = terminator
            self.parsed = HostsDocument.parse(body)
        }

        mutating func setBody(_ new: [Unicode.Scalar]) {
            body = new
            parsed = HostsDocument.parse(new)
        }

        func hostname(at index: Int = 0) -> String? {
            guard let p = parsed, p.hostRanges.indices.contains(index) else { return nil }
            return String(String.UnicodeScalarView(body[p.hostRanges[index]]))
        }
    }

    var segments: [Segment]

    public init(_ text: String) {
        var segments: [Segment] = []
        var body: [Unicode.Scalar] = []
        for scalar in text.unicodeScalars {
            if scalar == "\n" {
                if body.last == "\r" {
                    body.removeLast()
                    segments.append(Segment(body: body, terminator: ["\r", "\n"]))
                } else {
                    segments.append(Segment(body: body, terminator: ["\n"]))
                }
                body = []
            } else {
                body.append(scalar)
            }
        }
        if !body.isEmpty { segments.append(Segment(body: body, terminator: [])) }
        self.segments = segments
    }

    public var text: String {
        var bytes: [UInt8] = []
        for s in segments {
            for scalar in s.body { UTF8.encode(scalar) { bytes.append($0) } }
            for scalar in s.terminator { UTF8.encode(scalar) { bytes.append($0) } }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Only lines inside the managed block count. With no block, or damaged markers, every line is `.missing`.
    public func state(of line: HostLine) -> LineState {
        guard let key = HostsValidation.ipKey(line.ip), let interior = interior else { return .missing }
        var found = false
        for seg in segments[interior] where matches(seg, key: key, hostname: line.hostname) {
            if seg.parsed?.commented == false { return .on }
            found = true
        }
        return found ? .off : .missing
    }

    /// True when some uncommented line lists `localhost` among its names (any number of names).
    public var hasEnabledLocalhost: Bool {
        segments.contains { seg in
            guard let p = seg.parsed, !p.commented else { return false }
            return p.hostRanges.indices.contains { seg.hostname(at: $0)?.lowercased() == "localhost" }
        }
    }

    // MARK: Internals

    func matches(_ seg: Segment, key: [UInt8], hostname: String) -> Bool {
        guard let p = seg.parsed, p.hostRanges.count == 1, p.ipKey == key else { return false }
        return seg.hostname()?.lowercased() == hostname.lowercased()
    }

    static func isBlank(_ c: Unicode.Scalar) -> Bool {
        c == " " || c == "\t" || c == "\r" || c == "\u{0B}" || c == "\u{0C}"
    }

    /// A line parses only if its first token is an IP and at least one name follows.
    static func parse(_ b: [Unicode.Scalar]) -> Parsed? {
        var i = 0
        while i < b.count, isBlank(b[i]) { i += 1 }
        let leadEnd = i
        var commented = false
        while i < b.count, b[i] == "#" || isBlank(b[i]) {
            if b[i] == "#" { commented = true }
            i += 1
        }
        var tokens: [Range<Int>] = []
        var start: Int?
        var j = i
        while j < b.count, b[j] != "#" {
            if isBlank(b[j]) {
                if let s = start { tokens.append(s..<j); start = nil }
            } else if start == nil {
                start = j
            }
            j += 1
        }
        if let s = start { tokens.append(s..<j) }
        guard tokens.count >= 2 else { return nil }
        let ip = String(String.UnicodeScalarView(b[tokens[0]]))
        guard HostsValidation.isValidIP(ip), let key = HostsValidation.ipKey(ip) else { return nil }
        return Parsed(commented: commented, leadEnd: leadEnd, ipRange: tokens[0],
                      hostRanges: Array(tokens.dropFirst()), ipKey: key)
    }
}

// MARK: - Managed block

extension HostsDocument {
    public static let beginMarker = "# BEGIN: bork-hosts"
    public static let endMarker = "# END: bork-hosts"
    private static let beginScalars = Array(beginMarker.unicodeScalars)
    private static let endScalars = Array(endMarker.unicodeScalars)

    enum Marker { case begin, end }

    enum Block: Equatable {
        case none
        case intact(begin: Int, end: Int)
        case damaged(BlockDamage)
    }

    /// A marker line equals the marker text once trailing blanks (space, tab, CR, VT, FF) are ignored.
    /// Compared scalar by scalar, so canonically equivalent or look-alike text never matches.
    static func marker(of body: [Unicode.Scalar]) -> Marker? {
        guard body.first == "#" else { return nil }
        var n = body.count
        while n > 0, isBlank(body[n - 1]) { n -= 1 }
        let trimmed = body[..<n]
        if trimmed.elementsEqual(beginScalars) { return .begin }
        if trimmed.elementsEqual(endScalars) { return .end }
        return nil
    }

    var block: Block {
        var begins: [Int] = [], ends: [Int] = []
        for (i, seg) in segments.enumerated() {
            switch Self.marker(of: seg.body) {
            case .begin: begins.append(i)
            case .end: ends.append(i)
            case nil: break
            }
        }
        if begins.count > 1 || ends.count > 1 { return .damaged(.duplicateMarker) }
        switch (begins.first, ends.first) {
        case (nil, nil): return .none
        case (_?, nil): return .damaged(.missingEnd)
        case (nil, _?): return .damaged(.missingBegin)
        case let (b?, e?): return e < b ? .damaged(.endBeforeBegin) : .intact(begin: b, end: e)
        }
    }

    /// Set when the markers are unusable. Reading and display still work; every mutation is a no-op.
    public var blockDamage: BlockDamage? {
        if case let .damaged(reason) = block { return reason }
        return nil
    }

    /// Indexes of the segments strictly between the markers, or nil without an intact block.
    var interior: Range<Int>? {
        if case let .intact(b, e) = block { return (b + 1)..<e }
        return nil
    }

    /// UTF-8 offsets of the BEGIN line start, just past the BEGIN line, the END line start, and just past
    /// the END line with its terminator (nil without an intact block).
    var blockByteOffsets: (beginLineStart: Int, beginLineEnd: Int, endLineStart: Int, endLineEnd: Int)? {
        guard case let .intact(b, e) = block else { return nil }
        func size(_ seg: Segment) -> Int { (seg.body + seg.terminator).reduce(0) { $0 + UTF8.width($1) } }
        let endStart = segments[..<e].reduce(0) { $0 + size($1) }
        return (segments[..<b].reduce(0) { $0 + size($1) }, segments[...b].reduce(0) { $0 + size($1) },
                endStart, endStart + size(segments[e]))
    }

    /// 1-based numbers (over the whole file) of active lines outside the block that list `hostname`,
    /// lowest first. Any IP and any number of names counts; commented lines and the block are ignored.
    /// With damaged markers there is no block, so the whole file is outside.
    public func outsideLines(forHostname hostname: String) -> [Int] {
        let inside = interior
        let wanted = hostname.lowercased()
        var numbers: [Int] = []
        for (i, seg) in segments.enumerated() where inside?.contains(i) != true {
            guard let p = seg.parsed, !p.commented else { continue }
            if p.hostRanges.indices.contains(where: { seg.hostname(at: $0)?.lowercased() == wanted }) { numbers.append(i + 1) }
        }
        return numbers
    }

    /// The most common terminator; a tie, or no terminator at all, means LF.
    var dominantTerminator: [Unicode.Scalar] {
        let crlf = segments.filter { $0.terminator.count == 2 }.count
        let lf = segments.filter { $0.terminator.count == 1 }.count
        return crlf > lf ? ["\r", "\n"] : ["\n"]
    }

    private static func segment(_ text: String, _ terminator: [Unicode.Scalar]) -> Segment {
        Segment(body: Array(text.unicodeScalars), terminator: terminator)
    }

    /// Appends a new block holding `line`: repairs a missing final newline, adds a blank line unless the
    /// file is empty or already ends with one, and uses the file's dominant line ending.
    private mutating func createBlock(with line: HostLine) {
        let terminator = dominantTerminator
        let endsBlank = segments.last.map { !$0.terminator.isEmpty && $0.body.allSatisfy(Self.isBlank) } ?? true
        if let last = segments.indices.last, segments[last].terminator.isEmpty { segments[last].terminator = terminator }
        if !endsBlank { segments.append(Self.segment("", terminator)) }
        segments.append(Self.segment(Self.beginMarker, terminator))
        segments.append(Self.segment("\(line.ip) \(line.hostname)", terminator))
        segments.append(Self.segment(Self.endMarker, terminator))
    }
}

// MARK: - Mutations

extension HostsDocument {
    /// Works only on the managed block. Off adds `# ` to every enabled copy inside the block. On enables
    /// the first copy only when none is enabled; when the block has no copy it inserts the line before
    /// END, creating the block at the end of the file if there is none. A line missing from the block is
    /// never created by Off, and nothing outside the block is ever touched. With damaged markers nothing
    /// changes. Invalid lines are ignored so a corrupt sidebar entry can never put extra lines into the file.
    public mutating func setEnabled(_ line: HostLine, _ enabled: Bool) {
        guard line.isValid, let key = HostsValidation.ipKey(line.ip) else { return }
        switch block {
        case .damaged: return
        case .none:
            if enabled { createBlock(with: line) }
        case let .intact(b, e):
            let hits = ((b + 1)..<e).filter { matches(segments[$0], key: key, hostname: line.hostname) }
            if enabled {
                if hits.contains(where: { segments[$0].parsed?.commented == false }) { return }
                if let first = hits.first {
                    guard let p = segments[first].parsed else { return }
                    var body = segments[first].body
                    body.removeSubrange(p.leadEnd..<p.ipRange.lowerBound)
                    segments[first].setBody(body)
                } else {
                    segments.insert(Self.segment("\(line.ip) \(line.hostname)", dominantTerminator), at: e)
                }
            } else {
                for i in hits {
                    guard let p = segments[i].parsed, !p.commented else { continue }
                    var body = segments[i].body
                    body.insert(contentsOf: ["#", " "], at: p.leadEnd)
                    segments[i].setBody(body)
                }
            }
        }
    }

    /// Removes matching lines inside the block only. The marker lines stay.
    public mutating func remove(_ line: HostLine) {
        guard let key = HostsValidation.ipKey(line.ip), let interior else { return }
        for i in interior.reversed() where matches(segments[i], key: key, hostname: line.hostname) {
            segments.remove(at: i)
        }
    }

    /// Rewrites only the IP and hostname tokens of each matching line inside the block, keeping its on/off state.
    public mutating func replace(_ old: HostLine, with new: HostLine) {
        guard new.isValid, let key = HostsValidation.ipKey(old.ip), let interior else { return }
        for i in interior where matches(segments[i], key: key, hostname: old.hostname) {
            guard let p = segments[i].parsed, let host = p.hostRanges.first else { continue }
            let b = segments[i].body
            let body = Array(b[..<p.ipRange.lowerBound]) + Array(new.ip.unicodeScalars)
                + Array(b[p.ipRange.upperBound..<host.lowerBound]) + Array(new.hostname.unicodeScalars)
                + Array(b[host.upperBound...])
            segments[i].setBody(body)
        }
    }
}

// MARK: - Display

public struct DisplayLine: Identifiable, Equatable, Sendable {
    public let id: Int
    public let text: String
    /// The first non-blank character is `#`.
    public let isComment: Bool
    /// Set for single-name entries, on or off; compare with `HostsDocument.entryKey(for:)`.
    public let entryKey: String?
    public let isEnabledEntry: Bool
    /// The line sits strictly between the BEGIN and END markers. Outside lines are never managed.
    public let isInBlock: Bool
}

extension HostsDocument {
    public var displayLines: [DisplayLine] {
        let inside = interior
        return segments.enumerated().map { index, seg in
            var key: String?
            if let p = seg.parsed, p.hostRanges.count == 1, let host = seg.hostname() {
                key = Self.entryKey(ipKey: p.ipKey, hostname: host)
            }
            return DisplayLine(id: index, text: String(String.UnicodeScalarView(seg.body)),
                               isComment: seg.body.first(where: { !Self.isBlank($0) }) == "#",
                               entryKey: key, isEnabledEntry: seg.parsed?.commented == false,
                               isInBlock: inside?.contains(index) == true)
        }
    }

    public static func entryKey(for line: HostLine) -> String? {
        HostsValidation.ipKey(line.ip).map { entryKey(ipKey: $0, hostname: line.hostname) }
    }

    static func entryKey(ipKey: [UInt8], hostname: String) -> String {
        "\(ipKey)|\(hostname.lowercased())"
    }
}
