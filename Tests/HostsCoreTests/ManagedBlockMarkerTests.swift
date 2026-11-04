import Foundation
import Testing
@testable import HostsCore

/// Marker matching, damage detection and the outside-line query (document level, no I/O).
struct ManagedBlockMarkerTests {
    let a = HostLine(ip: "1.1.1.1", hostname: "a")

    // MARK: Matching

    static let matchingRows: [String] = [
        "x\n" + beginMarker + "\n1.1.1.1 a\n" + endMarker + "\n",
        "x\n" + beginMarker + " \n1.1.1.1 a\n" + endMarker + "\t\n",
        "x\n" + beginMarker + "   \n1.1.1.1 a\n" + endMarker + " \t \n",
        "x\r\n" + beginMarker + "\r\n1.1.1.1 a\r\n" + endMarker + "\r\n",
        "x\n" + beginMarker + "\n1.1.1.1 a\n" + endMarker,
        "x\n" + beginMarker + "\n1.1.1.1 a\n" + endMarker + "\r",
        "x\n" + beginMarker + "\u{0B}\u{0C}\n1.1.1.1 a\n" + endMarker + "\u{0B}\n",
    ]

    @Test(arguments: matchingRows)
    func markerMatchingTable(_ t: String) {
        let d = HostsDocument(t)
        #expect(d.blockDamage == nil)
        #expect(d.state(of: a) == .on, "the line between the markers is inside the block")
        #expect(d.outsideLines(forHostname: "a").isEmpty)
        #expect(d.text == t)
    }

    @Test(arguments: [
        " # BEGIN: bork-hosts", "\t# BEGIN: bork-hosts", "#BEGIN: bork-hosts", "## BEGIN: bork-hosts", "# begin: bork-hosts",
        "# BEGIN:  bork-hosts", "# BEGIN: bork-hosts x", "# BEGIN: bork-hosts#", "# BEGIN: bork-hosts-2", "1.1.1.1 # BEGIN: bork-hosts",
        "# BEGIN: bork-host", "# BEGIN: bork-hosts\u{301}", "# BEGIN: bork-hosts\u{A0}", "# BEGIN: bork-hosts\u{2003}",
    ])
    func nearMissMarkersAreNeitherMarkersNorDamage(_ decoy: String) {
        for form in [decoy, decoy.replacingOccurrences(of: "BEGIN", with: "END").replacingOccurrences(of: "begin", with: "end")] {
            // A lone decoy on either side of a line that would be inside a block: there is no block.
            let t = form + "\n1.1.1.1 a\n"
            let d = HostsDocument(t)
            #expect(d.blockDamage == nil, "\(form.debugDescription)")
            #expect(d.state(of: a) == .missing)
            #expect(d.outsideLines(forHostname: "a") == [2])
        }
    }

    @Test func decoyMarkersOutsideRealBlockAreIgnored() {
        let t = "# BEGIN: bork-hosts v2\nout\n" + blk("1.1.1.1 a\n") + "  # END: bork-hosts\n"
        let d = HostsDocument(t)
        #expect(d.blockDamage == nil)
        #expect(d.state(of: a) == .on)
        #expect(d.displayLines.map(\.isInBlock) == [false, false, false, true, false, false])
    }

    // MARK: Damage

    static let damageRows: [(String, BlockDamage)] = [
        (beginMarker + "\nx\n", .missingEnd),
        ("x\n" + endMarker + "\n", .missingBegin),
        (endMarker + "\nx\n" + beginMarker + "\n", .endBeforeBegin),
        (beginMarker + "\n" + beginMarker + "\nx\n" + endMarker + "\n", .duplicateMarker),
        (beginMarker + "\nx\n" + endMarker + "\n" + endMarker + "\n", .duplicateMarker),
        (blk("x\n") + blk("y\n"), .duplicateMarker),
        (endMarker + "\n" + beginMarker + "\n" + endMarker + "\n", .duplicateMarker),
        (beginMarker + "\n" + beginMarker + "\n", .duplicateMarker),
        (beginMarker + " \r\nx\r\n", .missingEnd),
    ]

    @Test(arguments: damageRows)
    func damageShapes(_ text: String, _ reason: BlockDamage) {
        let d = HostsDocument(text)
        #expect(d.blockDamage == reason)
        #expect(d.text == text, "parsing stays byte-exact")
        #expect(d.state(of: a) == .missing)
    }

    @Test(arguments: [blk(), "x\n" + blk("1.1.1.1 a\n") + "y\n", "", "no markers\n", beginMarker + "\n" + endMarker])
    func undamagedShapes(_ text: String) {
        #expect(HostsDocument(text).blockDamage == nil)
    }

    @Test func damageDescriptionsAreDistinctAndNameTheMarker() {
        let reasons: [BlockDamage] = [.missingEnd, .missingBegin, .endBeforeBegin, .duplicateMarker]
        let texts = reasons.map { HostsServiceError.blockDamaged($0).errorDescription ?? "" }
        #expect(Set(texts).count == 4)
        for text in texts { #expect(text.contains("BEGIN") || text.contains("END"), "\(text)") }
        #expect(texts[0].contains("END") && texts[1].contains("BEGIN"))
        #expect(HostsServiceError.confinementViolated.errorDescription?.isEmpty == false)
    }

    // MARK: Outside lines

    static let outsideRows: [(String, [Int])] = [
        ("1.1.1.1 a.com\n" + blk(), [1]),
        (blk() + "1.1.1.1 a.com\n", [3]),
        ("1.1.1.1 a.com\n", [1]),
        ("x\n" + blk("2.2.2.2 q\n") + "9.9.9.9 a.com\n", [5]),
        ("x\r\n1.1.1.1 a.com\r\n", [2]),
        ("  \t1.1.1.1 a.com\n", [1]),
        ("1.1.1.1 x.com a.com\n", [1]),
        ("1.1.1.1 x.com b.com a.com\n", [1]),
        ("::1 a.com\n", [1]),
        ("1.1.1.1 A.COM\n", [1]),
        ("1.1.1.1 a.com # sandbox\n", [1]),
        ("1.1.1.1 a.com\n2.2.2.2 a.com\n", [1, 2]),
        ("1.1.1.1 a.com\n" + blk("1.1.1.1 a.com\n") + "3.3.3.3 a.com\n", [1, 5]),
        ("# 1.1.1.1 a.com\n", []),
        ("#1.1.1.1 a.com\n", []),
        ("1.1.1.1 xa.com\n", []),
        ("1.1.1.1 a.com.evil\n", []),
        ("999.1.1.1 a.com\n", []),
        ("# prose about a.com here\n", []),
        (blk("1.1.1.1 a.com\n"), []),
        (blk("1.1.1.1 a.com\n2.2.2.2 other.com\n"), []),
        ("x\n" + beginMarker + "\n" + endMarker + "\n", []),
    ]

    @Test(arguments: outsideRows)
    func outsideLinesForHostname(_ text: String, _ expected: [Int]) {
        #expect(HostsDocument(text).outsideLines(forHostname: "a.com") == expected, "\(text.debugDescription)")
    }

    @Test func outsideLinesUseTheWholeFileWhenMarkersAreDamaged() {
        let d = HostsDocument(beginMarker + "\n1.1.1.1 a.com\n")
        #expect(d.outsideLines(forHostname: "a.com") == [2], "damaged markers mean no block, so every line is outside")
    }

    // MARK: Display

    @Test func displayLinesFlagOutsideCopiesAsUnmanaged() {
        let t = "1.1.1.1 a\n" + blk("1.1.1.1 a\n# 2.2.2.2 b\n") + "1.1.1.1 a\n"
        let lines = HostsDocument(t).displayLines
        #expect(lines.map(\.isInBlock) == [false, false, true, true, false, false])
        #expect(lines[0].entryKey == lines[2].entryKey, "same entry, different membership")
        #expect(HostsDocument("1.1.1.1 a\n").displayLines.allSatisfy { !$0.isInBlock })
    }
}
