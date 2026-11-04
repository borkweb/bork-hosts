import Testing
@testable import HostsCore

/// In-block behavior of the mutators. Every sidebar line lives between the markers, so each input
/// wraps its lines with `blk`. Placement outside the block is covered by `ManagedBlockDocumentTests`.
struct HostsDocumentMutationTests {
    let a = HostLine(ip: "1.1.1.1", hostname: "a")

    func apply(_ text: String, _ body: (inout HostsDocument) -> Void) -> String {
        var d = HostsDocument(text)
        body(&d)
        return d.text
    }

    @Test func disableAddsHashSpaceOnly() {
        #expect(apply(blk("1.1.1.1 a\n")) { $0.setEnabled(a, false) } == blk("# 1.1.1.1 a\n"))
    }

    @Test(arguments: [("# 1.1.1.1 a\n", "1.1.1.1 a\n"), ("#1.1.1.1 a\n", "1.1.1.1 a\n"), ("## 1.1.1.1 a\n", "1.1.1.1 a\n")])
    func enableRemovesCommentPrefix(_ input: String, _ expected: String) {
        var d = HostsDocument(blk(input))
        d.setEnabled(a, true)
        #expect(d.text == blk(expected))
        #expect(d.state(of: a) == .on)
    }

    @Test func togglePreservesEverythingElse() {
        let original = "# banner\r\n\r\n127.0.0.1 localhost\r\n" + blk("1.1.1.1 a # note\r\n  \t\r\n9.9.9.9 z\r\n", nl: "\r\n")
        let off = apply(original) { $0.setEnabled(a, false) }
        #expect(off == "# banner\r\n\r\n127.0.0.1 localhost\r\n" + blk("# 1.1.1.1 a # note\r\n  \t\r\n9.9.9.9 z\r\n", nl: "\r\n"))
        #expect(apply(off) { $0.setEnabled(a, true) } == original)
    }

    @Test func offThenOnRestoresIndentedLine() {
        let original = blk("  \t1.1.1.1   a\n")
        let off = apply(original) { $0.setEnabled(a, false) }
        #expect(off == blk("  \t# 1.1.1.1   a\n"))
        #expect(apply(off) { $0.setEnabled(a, true) } == original)
    }

    @Test func enableMissingInsertsBeforeEndOfExistingBlock() {
        #expect(apply("127.0.0.1 localhost\n" + blk("2.2.2.2 b\n")) { $0.setEnabled(a, true) }
            == "127.0.0.1 localhost\n" + blk("2.2.2.2 b\n1.1.1.1 a\n"))
    }

    @Test func enableMissingCreatesBlockAtEndRepairingTheFinalNewline() {
        #expect(apply("127.0.0.1 localhost\n") { $0.setEnabled(a, true) } == "127.0.0.1 localhost\n\n" + blk("1.1.1.1 a\n"))
        #expect(apply("127.0.0.1 localhost") { $0.setEnabled(a, true) } == "127.0.0.1 localhost\n\n" + blk("1.1.1.1 a\n"))
    }

    @Test func createUsesCRLFWhenFileUsesCRLF() {
        #expect(apply("127.0.0.1 localhost\r\n") { $0.setEnabled(a, true) }
            == "127.0.0.1 localhost\r\n\r\n" + blk("1.1.1.1 a\r\n", nl: "\r\n"))
        #expect(apply("127.0.0.1 localhost") { $0.setEnabled(a, true) } == "127.0.0.1 localhost\n\n" + blk("1.1.1.1 a\n"))
    }

    @Test func createInEmptyFile() {
        #expect(apply("") { $0.setEnabled(a, true) } == blk("1.1.1.1 a\n"))
    }

    @Test func disableMissingIsNoOp() {
        #expect(apply("127.0.0.1 localhost\n") { $0.setEnabled(a, false) } == "127.0.0.1 localhost\n")
        #expect(apply(blk()) { $0.setEnabled(a, false) } == blk())
    }

    @Test func disableCommentsEveryEnabledCopy() {
        #expect(apply(blk("1.1.1.1 a\nx\n1.1.1.1 A\n")) { $0.setEnabled(a, false) } == blk("# 1.1.1.1 a\nx\n# 1.1.1.1 A\n"))
    }

    @Test func enableWithOneEnabledCopyIsNoOp() {
        let t = blk("# 1.1.1.1 a\n1.1.1.1 a\n")
        #expect(apply(t) { $0.setEnabled(a, true) } == t)
    }

    @Test func enableUncommentsFirstCopyOnly() {
        #expect(apply(blk("# 1.1.1.1 a\n# 1.1.1.1 a\n")) { $0.setEnabled(a, true) } == blk("1.1.1.1 a\n# 1.1.1.1 a\n"))
    }

    @Test func removeDeletesOnlyMatchingLines() {
        let t = blk("1.1.1.1 a\n# 1.1.1.1 a\n1.1.1.2 a\n1.1.1.1 b\n1.1.1.1 a b\n")
        #expect(apply(t) { $0.remove(a) } == blk("1.1.1.2 a\n1.1.1.1 b\n1.1.1.1 a b\n"))
    }

    @Test func replaceRewritesIPInPlaceKeepingState() {
        let new = HostLine(ip: "2.2.2.2", hostname: "a")
        #expect(apply(blk("1.1.1.1   a # n\n# 1.1.1.1 a\n")) { $0.replace(a, with: new) } == blk("2.2.2.2   a # n\n# 2.2.2.2 a\n"))
        #expect(apply(blk("x\n")) { $0.replace(a, with: new) } == blk("x\n"))
    }

    @Test func replaceRewritesHostname() {
        let new = HostLine(ip: "1.1.1.1", hostname: "b.com")
        #expect(apply(blk("# 1.1.1.1 a\n")) { $0.replace(a, with: new) } == blk("# 1.1.1.1 b.com\n"))
    }

    @Test func invalidLinesCannotInject() {
        let evil = HostLine(ip: "1.1.1.1", hostname: "a.com\n6.6.6.6 evil.com")
        let evilIP = HostLine(ip: "1.1.1.1 # x\n6.6.6.6", hostname: "a.com")
        let t = "127.0.0.1 localhost\n"
        #expect(apply(t) { $0.setEnabled(evil, true) } == t)
        #expect(apply(t) { $0.setEnabled(evilIP, true) } == t)
        #expect(apply(blk("1.1.1.1 a\n")) { $0.replace(a, with: evil) } == blk("1.1.1.1 a\n"))
    }
}
