import Testing
@testable import HostsCore

/// Seeded generator of hosts files shaped `pre + BEGIN + interior + END + post`. Each managed line is
/// built from known parts, so the expected result of every edit is computed from the generator's
/// parts, never from the parser. Only interior copies of the target may change.
struct HostsDocumentPropertyTests {
    struct Managed {
        var lead: String, hash: String, ip: String, sep: String, host: String, suffix: String
        var commented: Bool { !hash.isEmpty }
        var text: String { lead + hash + ip + sep + host + suffix }
        /// Off: `# ` goes right after the leading whitespace.
        var off: String { lead + "# " + hash + ip + sep + host + suffix }
        /// On: the whole comment run is removed.
        var on: String { lead + ip + sep + host + suffix }
    }
    enum Piece { case managed(Managed); case filler(String) }
    typealias Row = (piece: Piece, term: String)

    struct Doc {
        var pre: [Row], interior: [Row], post: [Row]
        var hasBlock: Bool
        var beginTerm: String, endTerm: String

        static func join(_ rows: [Row], _ transform: (Managed) -> String? = { $0.text }) -> String {
            rows.map { piece, term in
                switch piece {
                case let .managed(m): return transform(m).map { $0 + term } ?? ""
                case let .filler(f): return f + term
                }
            }.joined()
        }

        func text(interior: String? = nil) -> String {
            let inner = interior ?? Self.join(self.interior)
            guard hasBlock else { return Self.join(pre) + Self.join(post) }
            return Self.join(pre) + beginMarker + beginTerm + inner + endMarker + endTerm + Self.join(post)
        }

        var terminators: [String] { (pre + interior + post).map(\.term) + (hasBlock ? [beginTerm, endTerm] : []) }
    }

    static let ips = ["10.0.0.1", "10.0.0.2", "::1", "FE80::1"]
    static let hosts = ["a.com", "B.com", "c.example.test"]
    static let fillers = ["", "# comment", "   ", "caf\u{E9} \u{2603}", "1.1.1.1 multi a b", "9.9.9.9 other.com",
                          "lone\rcr", "127.0.0.1\tlocalhost", "##", "\t"]
    static let decoys = ["# BEGIN: bork-hosts v2", "  # END: bork-hosts", "#BEGIN: bork-hosts", "# end: bork-hosts", "# BEGIN:  bork-hosts"]

    static func generate(_ rng: inout SeededRandom, target: HostLine) -> Doc {
        func pick<T>(_ a: [T]) -> T { a[Int.random(in: 0..<a.count, using: &rng)] }
        func rows(_ n: Int, decoy: Bool) -> [Row] {
            (0..<n).map { _ in
                let piece: Piece
                if Bool.random(using: &rng) {
                    // Biased toward the target so most seeds have copies of it in every region.
                    let aimed = Int.random(in: 0..<3, using: &rng) != 0
                    piece = .managed(Managed(lead: pick(["", "  ", "\t"]), hash: pick(["", "", "# ", "#", "## ", "#\t"]),
                                             ip: aimed ? target.ip : pick(ips), sep: pick([" ", "\t", "   "]),
                                             host: aimed ? target.hostname : pick(hosts),
                                             suffix: pick(["", "", " # note", "  ", "\t# x"])))
                } else if decoy && Int.random(in: 0..<4, using: &rng) == 0 {
                    piece = .filler(pick(decoys))
                } else {
                    piece = .filler(pick(fillers))
                }
                return (piece, pick(["\n", "\r\n"]))
            }
        }
        let hasBlock = Int.random(in: 0..<8, using: &rng) != 0
        var doc = Doc(pre: rows(Int.random(in: 0...5, using: &rng), decoy: true),
                      interior: hasBlock ? rows(Int.random(in: 0...6, using: &rng), decoy: false) : [],
                      post: rows(Int.random(in: 0...5, using: &rng), decoy: true),
                      hasBlock: hasBlock, beginTerm: pick(["\n", "\r\n"]), endTerm: pick(["\n", "\r\n"]))
        // The very last line may lack a terminator.
        if Bool.random(using: &rng) {
            if !doc.post.isEmpty { doc.post[doc.post.count - 1].term = "" }
            else if hasBlock { doc.endTerm = "" }
            else if !doc.pre.isEmpty { doc.pre[doc.pre.count - 1].term = "" }
        }
        return doc
    }

    static func matches(_ m: Managed, _ line: HostLine) -> Bool {
        HostsValidation.ipKey(m.ip) == HostsValidation.ipKey(line.ip) && m.host.lowercased() == line.hostname.lowercased()
    }

    static func target(_ seed: UInt64) -> HostLine {
        HostLine(ip: ips[Int(seed) % ips.count], hostname: hosts[Int(seed / 3) % hosts.count])
    }

    static func copies(_ rows: [Row], of target: HostLine) -> [Managed] {
        rows.compactMap { piece, _ in
            if case let .managed(m) = piece, matches(m, target) { return m } else { return nil }
        }
    }

    /// The last line is whitespace-only and terminated (blank set: space, tab, CR, VT, FF).
    static func endsWithBlankLine(_ s: String) -> Bool {
        let scalars = Array(s.unicodeScalars)
        guard scalars.last == "\n" else { return false }
        let line = scalars.dropLast().reversed().prefix { $0 != "\n" }
        return line.allSatisfy { HostsDocument.isBlank($0) }
    }

    @Test(arguments: Array(1...150) as [UInt64])
    func editsTouchOnlyMatchingLinesAndRoundTrip(_ seed: UInt64) {
        var rng = SeededRandom(seed: seed)
        let target = Self.target(seed)
        let doc = Self.generate(&rng, target: target)
        let original = doc.text()
        let ctx = "seed \(seed): \(original.debugDescription)"
        #expect(HostsDocument(original).text == original, "\(ctx) round trip")

        let matching = Self.copies(doc.interior, of: target)
        func rebuilt(_ transform: (Managed) -> String?) -> String {
            doc.text(interior: Doc.join(doc.interior) { Self.matches($0, target) ? transform($0) : $0.text })
        }

        // Off: every enabled interior copy gets `# `; outside copies and everything else stay.
        var off = HostsDocument(original)
        off.setEnabled(target, false)
        #expect(off.text == rebuilt { $0.commented ? $0.text : $0.off }, "\(ctx) off")
        #expect(off.segments.count == HostsDocument(original).segments.count, "\(ctx) off keeps line count")

        // On: no-op if an interior copy is enabled; else the first commented interior copy is
        // uncommented; with no interior copy the line is inserted before END (or the block is created).
        var on = HostsDocument(original)
        on.setEnabled(target, true)
        let newLine = "\(target.ip) \(target.hostname)"
        let terms = doc.terminators
        let ending = terms.filter { $0 == "\r\n" }.count > terms.filter { $0 == "\n" }.count ? "\r\n" : "\n"
        if matching.isEmpty {
            if doc.hasBlock {
                #expect(on.text == doc.text(interior: Doc.join(doc.interior) + newLine + ending), "\(ctx) insert before END")
            } else {
                #expect(on.text.hasPrefix(original), "\(ctx) old file is an exact prefix of the created block")
                let tail = String(on.text.dropFirst(original.count))
                let repaired = original.isEmpty || original.utf8.last == 10 ? "" : ending
                let blank = (original.isEmpty || Self.endsWithBlankLine(original)) ? "" : ending
                #expect(tail == repaired + blank + beginMarker + ending + newLine + ending + endMarker + ending, "\(ctx) created block")
            }
        } else if matching.contains(where: { !$0.commented }) {
            #expect(on.text == original, "\(ctx) on with an enabled interior copy is a no-op")
        } else {
            var done = false
            #expect(on.text == rebuilt { m in
                if !done { done = true; return m.on }
                return m.text
            }, "\(ctx) on uncomments the first interior copy only")
        }

        // Off then on restores the original when exactly one interior copy exists and it was enabled.
        if matching.count == 1, !matching[0].commented {
            var round = HostsDocument(original)
            round.setEnabled(target, false)
            round.setEnabled(target, true)
            #expect(round.text == original, "\(ctx) off then on")
        }

        // Remove: exactly the interior matching lines disappear.
        var removed = HostsDocument(original)
        removed.remove(target)
        #expect(removed.text == rebuilt { _ in nil }, "\(ctx) remove")
        #expect(removed.segments.count == HostsDocument(original).segments.count - matching.count, "\(ctx) remove count")

        // Replace: only the IP and hostname tokens of interior matching lines change.
        let new = HostLine(ip: "192.0.2.77", hostname: "replaced.example.test")
        var replaced = HostsDocument(original)
        replaced.replace(target, with: new)
        #expect(replaced.text == rebuilt { m in m.lead + m.hash + new.ip + m.sep + new.hostname + m.suffix }, "\(ctx) replace")

        // Bytes before BEGIN and after END never change.
        if doc.hasBlock {
            for edited in [off.text, on.text, removed.text, replaced.text] {
                #expect(edited.hasPrefix(Doc.join(doc.pre) + beginMarker + doc.beginTerm), "\(ctx) prefix")
                #expect(edited.hasSuffix(endMarker + doc.endTerm + Doc.join(doc.post)), "\(ctx) suffix")
            }
        }
    }

    /// Guards the generator so the property test cannot go vacuous.
    @Test func generatorCoversOutsideCopiesAndMissingBlocks() {
        var outside = 0, noBlock = 0, insideEnabled = 0, insideCommented = 0
        for seed in 1...150 as ClosedRange<UInt64> {
            var rng = SeededRandom(seed: seed)
            let target = Self.target(seed)
            let doc = Self.generate(&rng, target: target)
            if !Self.copies(doc.pre + doc.post, of: target).isEmpty { outside += 1 }
            if !doc.hasBlock { noBlock += 1 }
            let inside = Self.copies(doc.interior, of: target)
            if inside.contains(where: { !$0.commented }) { insideEnabled += 1 }
            if inside.contains(where: \.commented) { insideCommented += 1 }
        }
        #expect(outside * 100 >= 30 * 150, "outside copies in \(outside) of 150")
        #expect(noBlock * 100 >= 10 * 150, "no block in \(noBlock) of 150")
        #expect(insideEnabled >= 15 && insideCommented >= 15, "inside enabled \(insideEnabled), commented \(insideCommented)")
    }

    @Test func stockMacOSFileRoundTripsAndEditsMinimally() {
        let stock = HostsDocumentTests.stockMacHosts
        var d = HostsDocument(stock)
        let line = HostLine(ip: "10.0.0.1", hostname: "x.com")
        d.setEnabled(line, true)
        #expect(d.text == stock + "\n" + blk("10.0.0.1 x.com\n"))
        d.setEnabled(line, false)
        #expect(d.text == stock + "\n" + blk("# 10.0.0.1 x.com\n"))
        d.remove(line)
        #expect(d.text == stock + "\n" + blk())
    }

    @Test(arguments: Array(1...300) as [UInt64])
    func blockMarkerRoundTrip(_ seed: UInt64) {
        var rng = SeededRandom(seed: seed)
        let alphabet = [beginMarker, endMarker, "# BEGIN: bork-hosts v2", "  # END: bork-hosts", beginMarker + " \t", endMarker + "\r",
                        "\n", "\r\n", "\r", "\t", " ", "1.1.1.1 a", "# 1.1.1.1 a", "caf\u{E9}", "\u{301}", "\u{A0}", "#", "x"]
        let s = (0..<Int.random(in: 0...24, using: &rng)).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &rng)] }.joined()
        #expect(HostsDocument(s).text == s, "seed \(seed): \(s.debugDescription)")
    }
}
