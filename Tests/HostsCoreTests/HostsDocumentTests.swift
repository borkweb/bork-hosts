import Testing
@testable import HostsCore

struct HostsDocumentTests {
    static let stockMacHosts = """
    ##
    # Host Database
    #
    # localhost is used to configure the loopback interface
    # when the system is booting.  Do not change this entry.
    ##
    127.0.0.1\tlocalhost
    255.255.255.255\tbroadcasthost
    ::1             localhost

    """

    @Test(arguments: [
        "127.0.0.1 localhost\n", "a\r\nb\r\n", "x", "", "  # c\n\n1.1.1.1\ta  b # n\n",
        "a\rb\n", "caf\u{E9} \u{2603}\r\n\r\n", stockMacHosts,
        "x\n# BEGIN: bork-hosts \t\r\n1.1.1.1 a\n# END: bork-hosts  \r\ntail", "# END: bork-hosts\n# BEGIN: bork-hosts", "# BEGIN: bork-hosts\r",
    ])
    func roundTripIsByteExact(_ s: String) {
        #expect(HostsDocument(s).text == s)
    }

    @Test func stateOnForActiveLine() {
        let d = HostsDocument(blk("192.0.2.10 example.com\n"))
        #expect(d.state(of: HostLine(ip: "192.0.2.10", hostname: "example.com")) == .on)
    }

    @Test(arguments: ["# 192.0.2.10 example.com\n", "#192.0.2.10\texample.com\n"])
    func stateOffForCommentedLine(_ s: String) {
        #expect(HostsDocument(blk(s)).state(of: HostLine(ip: "192.0.2.10", hostname: "example.com")) == .off)
    }

    @Test func stateMissing() {
        #expect(HostsDocument(blk("127.0.0.1 localhost\n")).state(of: HostLine(ip: "192.0.2.10", hostname: "example.com")) == .missing)
    }

    @Test func caseInsensitiveMatch() {
        #expect(HostsDocument(blk("192.0.2.10 Example.COM\n")).state(of: HostLine(ip: "192.0.2.10", hostname: "example.com")) == .on)
    }

    @Test func multiHostnameFileLineNeverMatches() {
        #expect(HostsDocument(blk("192.0.2.10 a.com b.com\n")).state(of: HostLine(ip: "192.0.2.10", hostname: "a.com")) == .missing)
    }

    @Test func ipv6Matches() {
        #expect(HostsDocument(blk("::1 localhost\n")).state(of: HostLine(ip: "::1", hostname: "localhost")) == .on)
    }

    @Test func ipv6CaseIsOneIdentity() {
        let d = HostsDocument(blk("FE80::1 a.com\n"))
        #expect(d.state(of: HostLine(ip: "fe80::1", hostname: "a.com")) == .on)
    }

    @Test func proseCommentDoesNotMatch() {
        #expect(HostsDocument(blk("# 192.0.2.10 is the sandbox\n")).state(of: HostLine(ip: "192.0.2.10", hostname: "is")) == .missing)
    }

    @Test func duplicateEnabledAndCommentedCopies() {
        #expect(HostsDocument(blk("# 1.1.1.1 a\n1.1.1.1 a\n")).state(of: HostLine(ip: "1.1.1.1", hostname: "a")) == .on)
    }

    @Test func differentIPSameHostnameIsMissing() {
        #expect(HostsDocument(blk("1.1.1.2 a\n")).state(of: HostLine(ip: "1.1.1.1", hostname: "a")) == .missing)
    }

    @Test(arguments: [
        ("# 127.0.0.1 localhost\n", false), ("# the word localhost here\n", false),
        ("1.1.1.1 notlocalhost\n", false), ("", false), ("127.0.0.1 localhost foo\n", true),
        ("::1 foo LocalHost\n", true), (stockMacHosts, true),
    ])
    func hasEnabledLocalhost(_ s: String, _ expected: Bool) {
        #expect(HostsDocument(s).hasEnabledLocalhost == expected)
    }
}

struct DisplayLinesTests {
    @Test func displayLinesFlagCommentsAndEntries() {
        let d = HostsDocument("# banner\n127.0.0.1 localhost\n  # 10.0.0.1 x.com\r\n10.0.0.1 a b\nlast")
        let lines = d.displayLines
        #expect(lines.map(\.text) == ["# banner", "127.0.0.1 localhost", "  # 10.0.0.1 x.com", "10.0.0.1 a b", "last"])
        #expect(lines.map(\.isComment) == [true, false, true, false, false])
        #expect(lines.map(\.isEnabledEntry) == [false, true, false, true, false])
        #expect(lines[2].entryKey == HostsDocument.entryKey(for: HostLine(ip: "10.0.0.1", hostname: "X.com")))
        #expect(lines[3].entryKey == nil, "multi-name lines are never matched")
    }
}
