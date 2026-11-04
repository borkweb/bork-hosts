import Foundation
import Testing
@testable import HostsCore

let beginMarker = "# BEGIN: bork-hosts"
let endMarker = "# END: bork-hosts"

/// A well-formed block with the given interior (each interior line must carry its own terminator).
func blk(_ interior: String = "", nl: String = "\n") -> String {
    beginMarker + nl + interior + endMarker + nl
}

struct ManagedBlockDocumentTests {
    let a = HostLine(ip: "1.1.1.1", hostname: "a")

    func apply(_ text: String, _ body: (inout HostsDocument) -> Void) -> String {
        var d = HostsDocument(text)
        body(&d)
        return d.text
    }

    // MARK: Reads see only the block

    @Test func stateIgnoresLinesOutsideBlock() {
        #expect(HostsDocument("1.1.1.1 a\n" + blk()).state(of: a) == .missing)
        #expect(HostsDocument(blk() + "# 1.1.1.1 a\n").state(of: a) == .missing)
        #expect(HostsDocument("1.1.1.1 a\n").state(of: a) == .missing, "no block at all")
        #expect(HostsDocument(HostsDocumentTests.stockMacHosts).state(of: HostLine(ip: "127.0.0.1", hostname: "localhost")) == .missing)
        #expect(HostsDocument("1.1.1.1 a\n" + blk("# 1.1.1.1 a\n")).state(of: a) == .off)
        #expect(HostsDocument(blk("1.1.1.1 a\n")).state(of: a) == .on)
    }

    @Test func setEnabledNeverAdoptsOutsideLine() {
        let before = "# 1.1.1.1 a\n"
        #expect(apply(before) { $0.setEnabled(a, true) } == before + "\n" + blk("1.1.1.1 a\n"))
        let after = blk() + "# 1.1.1.1 a\n"
        #expect(apply(after) { $0.setEnabled(a, true) } == blk("1.1.1.1 a\n") + "# 1.1.1.1 a\n")
    }

    @Test func removeOnlyTouchesBlock() {
        let t = "1.1.1.1 a\n" + blk("1.1.1.1 a\n# 1.1.1.1 a\n") + "1.1.1.1 a\n"
        #expect(apply(t) { $0.remove(a) } == "1.1.1.1 a\n" + blk() + "1.1.1.1 a\n")
    }

    @Test func replaceOnlyTouchesBlock() {
        let new = HostLine(ip: "2.2.2.2", hostname: "b")
        let t = "1.1.1.1 a\n" + blk("1.1.1.1 a\n") + "# 1.1.1.1 a\n"
        #expect(apply(t) { $0.replace(a, with: new) } == "1.1.1.1 a\n" + blk("2.2.2.2 b\n") + "# 1.1.1.1 a\n")
    }

    @Test func disableOnlyTouchesBlock() {
        let t = "1.1.1.1 a\n" + blk("1.1.1.1 a\n") + "1.1.1.1 a\n"
        #expect(apply(t) { $0.setEnabled(a, false) } == "1.1.1.1 a\n" + blk("# 1.1.1.1 a\n") + "1.1.1.1 a\n")
    }

    @Test func markerLinesAreNeverMatchedOrEdited() {
        let bork = HostLine(ip: "1.1.1.1", hostname: "bork-hosts")
        let t = "x\r\n" + beginMarker + " \t\r\n1.1.1.1 bork-hosts\r\n" + endMarker + "  \r\n"
        let keep = "x\r\n" + beginMarker + " \t\r\n" + endMarker + "  \r\n"
        #expect(apply(t) { $0.remove(bork) } == keep)
        #expect(apply(t) { $0.replace(bork, with: HostLine(ip: "2.2.2.2", hostname: "other")) }
            == "x\r\n" + beginMarker + " \t\r\n2.2.2.2 other\r\n" + endMarker + "  \r\n")
        #expect(apply(t) { $0.setEnabled(bork, false) }
            == "x\r\n" + beginMarker + " \t\r\n# 1.1.1.1 bork-hosts\r\n" + endMarker + "  \r\n")
        #expect(apply(keep) { $0.setEnabled(a, false) } == keep)
    }

    // MARK: Creating the block

    static let createRows: [(String, String)] = [
        ("", blk("1.1.1.1 a\n")),
        ("127.0.0.1 localhost\n", "127.0.0.1 localhost\n\n" + blk("1.1.1.1 a\n")),
        ("127.0.0.1 localhost", "127.0.0.1 localhost\n\n" + blk("1.1.1.1 a\n")),
        ("127.0.0.1 localhost\r\n", "127.0.0.1 localhost\r\n\r\n" + blk("1.1.1.1 a\r\n", nl: "\r\n")),
        ("x\r\ny", "x\r\ny\r\n\r\n" + blk("1.1.1.1 a\r\n", nl: "\r\n")),
        ("a\n\n", "a\n\n" + blk("1.1.1.1 a\n")),
        ("a\r\n\r\n", "a\r\n\r\n" + blk("1.1.1.1 a\r\n", nl: "\r\n")),
        ("\n", "\n" + blk("1.1.1.1 a\n")),
        ("a\nb\r\nc\r\nd\r\n", "a\nb\r\nc\r\nd\r\n\r\n" + blk("1.1.1.1 a\r\n", nl: "\r\n")),
        ("a\nb\r\n", "a\nb\r\n\n" + blk("1.1.1.1 a\n")),
        ("abc", "abc\n\n" + blk("1.1.1.1 a\n")),
        (HostsDocumentTests.stockMacHosts, HostsDocumentTests.stockMacHosts + "\n" + blk("1.1.1.1 a\n")),
        ("a\n  \n", "a\n  \n" + blk("1.1.1.1 a\n")),
        ("a\n  ", "a\n  \n\n" + blk("1.1.1.1 a\n")),
    ]

    @Test(arguments: createRows)
    func createBlockTable(_ input: String, _ expected: String) {
        #expect(apply(input) { $0.setEnabled(a, true) } == expected)
        #expect(HostsDocument(input).text == input)
    }

    @Test func groupOfLinesCreatesExactlyOneBlock() {
        let g = HostGroup(name: "G", lines: [a, HostLine(ip: "2.2.2.2", hostname: "b"), HostLine(ip: "3.3.3.3", hostname: "c")])
        var d = HostsDocument("127.0.0.1 localhost\n")
        HostsEditor.setGroup(g, enabled: true, groups: [g], in: &d)
        #expect(d.text == "127.0.0.1 localhost\n\n" + blk("1.1.1.1 a\n2.2.2.2 b\n3.3.3.3 c\n"))
        #expect(d.text.components(separatedBy: beginMarker).count == 2)
        #expect(d.text.components(separatedBy: endMarker).count == 2)
    }

    @Test func disablingMissingLineNeverCreatesBlock() {
        for t in ["127.0.0.1 localhost\n", blk(), "1.1.1.1 a\n", "x\n" + blk("# 2.2.2.2 q\n")] {
            #expect(apply(t) { $0.setEnabled(a, false) } == t)
        }
        var d = HostsDocument("127.0.0.1 localhost\n")
        let g = HostGroup(name: "G", lines: [a])
        HostsEditor.setGroup(g, enabled: false, groups: [g], in: &d)
        HostsEditor.setLine(a, enabled: false, groups: [g], in: &d)
        #expect(d.text == "127.0.0.1 localhost\n")
    }

    @Test func loneCRFileHasNoMatchableMarkerAndIsBlockless() {
        // D14: a lone CR is not a line ending, so the whole file is one line and no marker can match.
        let input = "x\r" + beginMarker + "\r" + endMarker + "\r"
        let d = HostsDocument(input)
        #expect(d.blockDamage == nil)
        #expect(d.interior == nil)
        #expect(d.text == input)
        #expect(d.state(of: a) == .missing)
        #expect(apply(input) { $0.setEnabled(a, true) } == input + "\n\n" + blk("1.1.1.1 a\n"), "block created after the full old text")
    }

    // MARK: Inserting into an existing block

    @Test func insertLandsBeforeEndAndKeepsEndBytes() {
        #expect(apply("x\n" + blk()) { $0.setEnabled(a, true) } == "x\n" + blk("1.1.1.1 a\n"))
        #expect(apply("x\n" + beginMarker + "\n" + endMarker) { $0.setEnabled(a, true) }
            == "x\n" + beginMarker + "\n1.1.1.1 a\n" + endMarker, "END without a terminator stays without one")
        #expect(apply(beginMarker + "\r\n" + endMarker + "  \r\n") { $0.setEnabled(a, true) }
            == beginMarker + "\r\n1.1.1.1 a\r\n" + endMarker + "  \r\n")
        let mixed = "p\r\nq\r\n" + beginMarker + "\n2.2.2.2 b\n" + endMarker + "\r\n"
        #expect(apply(mixed) { $0.setEnabled(a, true) }
            == "p\r\nq\r\n" + beginMarker + "\n2.2.2.2 b\n1.1.1.1 a\r\n" + endMarker + "\r\n", "file's dominant ending")
    }

    @Test func removingLastItemLeavesMarkers() {
        #expect(apply("x\n" + blk("1.1.1.1 a\n") + "y\n") { $0.remove(a) } == "x\n" + blk() + "y\n")
    }

    // MARK: Damaged markers: mutators change nothing

    static let damaged: [String] = [
        beginMarker + "\n1.1.1.1 a\n",
        "1.1.1.1 a\n" + endMarker + "\n",
        endMarker + "\n1.1.1.1 a\n" + beginMarker + "\n",
        blk("1.1.1.1 a\n") + blk("# 1.1.1.1 a\n"),
        beginMarker + "\n" + beginMarker + "\n1.1.1.1 a\n" + endMarker + "\n",
    ]

    @Test(arguments: damaged)
    func mutatorsChangeNothingOnDamagedMarkers(_ t: String) {
        #expect(HostsDocument(t).state(of: a) == .missing)
        #expect(apply(t) { $0.setEnabled(a, true) } == t)
        #expect(apply(t) { $0.setEnabled(a, false) } == t)
        #expect(apply(t) { $0.remove(a) } == t)
        #expect(apply(t) { $0.replace(a, with: HostLine(ip: "2.2.2.2", hostname: "b")) } == t)
    }

    @Test(arguments: [
        beginMarker + "\n" + endMarker + "\n", beginMarker + " \t\n" + endMarker + "  \n",
        beginMarker + "\r\n" + endMarker + "\r\n", beginMarker + "\n" + endMarker + "\r", "x\n" + beginMarker + "\n" + endMarker,
    ])
    func trailingBlankMarkersStillMatch(_ t: String) {
        #expect(apply(t) { $0.setEnabled(a, true) }.contains("1.1.1.1 a"))
        #expect(HostsDocument(t).state(of: a) == .missing)
        var d = HostsDocument(t)
        d.setEnabled(a, true)
        #expect(d.state(of: a) == .on, "the line landed inside the matched block")
    }

    @Test(arguments: [
        " # BEGIN: bork-hosts", "\t# BEGIN: bork-hosts", "#BEGIN: bork-hosts", "## BEGIN: bork-hosts", "# begin: bork-hosts",
        "# BEGIN:  bork-hosts", "# BEGIN: bork-hosts x", "# BEGIN: bork-hosts#", "# BEGIN: bork-hosts-2", "1.1.1.1 # BEGIN: bork-hosts",
        "# BEGIN: bork-host", "# BEGIN: bork-hosts\u{301}", "# BEGIN: bork-hosts\u{A0}",
    ])
    func nearMissMarkersDoNotMatch(_ decoy: String) {
        // A decoy never forms a marker (so no damage either), and the first write creates a real block after it.
        for form in [decoy, decoy.replacingOccurrences(of: "BEGIN", with: "END").replacingOccurrences(of: "begin", with: "end")] {
            let t = form + "\n"
            #expect(HostsDocument(t).state(of: a) == .missing)
            var d = HostsDocument(t)
            d.setEnabled(a, true)
            #expect(d.text == t + "\n" + blk("1.1.1.1 a\n"), "decoys stay byte-identical in the prefix: \(form.debugDescription)")
            #expect(d.state(of: a) == .on)
        }
    }
}
