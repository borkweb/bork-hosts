import Foundation
import Testing
@testable import HostsCore

struct AddInputTests {
    @Test func parsesSimpleLines() throws {
        let lines = try parseAddInput("192.0.2.10 example.com\n192.0.2.10 api.example.com")
        #expect(lines.map(\.hostname) == ["example.com", "api.example.com"])
        #expect(lines.allSatisfy { $0.ip == "192.0.2.10" })
    }

    @Test func splitsMultipleHostnamesPerLine() throws {
        #expect(try parseAddInput("1.1.1.1 a.com b.com").map(\.hostname) == ["a.com", "b.com"])
    }

    @Test func skipsBlankAndCommentLinesAndStripsInlineComments() throws {
        let lines = try parseAddInput("# header\n\n   \n1.1.1.1 a.com # sandbox\r\n  #x\n")
        #expect(lines.map(\.hostname) == ["a.com"])
    }

    @Test func throwsInvalidLineWithNumber() {
        #expect(throws: AddInputError.invalidLine(number: 2, text: "not an ip")) {
            try parseAddInput("1.1.1.1 a.com\nnot an ip")
        }
    }

    @Test(arguments: [
        "256.1.1.1 a", "1.1.1.1", "1.1.1.1 a..com", "1.1.1.1 -", "1.1.1.1 a.com.", "::g a",
        "fe80::1%lo0 a", "1.1.1.1 bad host!", "999.1.1.1 a", "1.1.1.1 -a.com", "1.1.1.1 a-.com",
        "1.1.1.1 " + String(repeating: "a", count: 64) + ".com",
        "1.1.1.1 " + String(repeating: "a.", count: 127) + "b",
    ])
    func rejectsMalformed(_ input: String) {
        #expect(throws: AddInputError.self) { try parseAddInput(input) }
    }

    @Test func acceptsLongestHostnameAndIPv6() throws {
        let labels = [String(repeating: "a", count: 63), String(repeating: "b", count: 63),
                      String(repeating: "c", count: 63), String(repeating: "d", count: 61)]
        let host = labels.joined(separator: ".")
        #expect(host.count == 253)
        #expect(try parseAddInput("1.1.1.1 \(host)\nFE80::1 a_b-c.com").count == 2)
        #expect(throws: AddInputError.self) { try parseAddInput("1.1.1.1 \(host)e") }
    }

    @Test func throwsEmptyForOnlyComments() {
        #expect(throws: AddInputError.empty) { try parseAddInput("# a\n\n") }
        #expect(throws: AddInputError.empty) { try parseAddInput("") }
    }

    @Test func throwsConflictingHostnameWithinInput() {
        #expect(throws: AddInputError.conflictingHostname("a.com")) {
            try parseAddInput("1.1.1.1 a.com\n2.2.2.2 A.com")
        }
    }

    @Test func dedupesIdenticalPairs() throws {
        #expect(try parseAddInput("1.1.1.1 a.com\n1.1.1.1 A.COM\n1.1.1.1 a.com").count == 1)
    }

    @Test(arguments: ["localhost", "LocalHost", "broadcasthost"])
    func rejectsReservedHostnames(_ name: String) {
        #expect(throws: AddInputError.reservedHostname(name.lowercased())) { try parseAddInput("127.0.0.1 \(name)") }
    }

    @Test func validateLineFieldsRejectsEmptyAndSpaces() {
        for (ip, host) in [("", "a.com"), ("1.1.1.1", ""), ("  ", "  "), ("1.1.1.1", "a b")] {
            #expect(throws: AddInputError.self) { try validateLine(ip: ip, hostname: host) }
        }
        let ok = try? validateLine(ip: " 1.1.1.1 ", hostname: " a.com ")
        #expect(ok?.ip == "1.1.1.1" && ok?.hostname == "a.com")
    }

    @Test func groupNameRules() throws {
        #expect(try validateGroupName("  Sandbox ") == "Sandbox")
        for bad in ["", "   ", "\n"] { #expect(throws: AddInputError.blankName) { try validateGroupName(bad) } }
        #expect(throws: AddInputError.invalidName) { try validateGroupName("a\nb") }
    }

    @Test func rejectsPairInAnotherGroup() {
        let existing = HostLine(ip: "1.1.1.1", hostname: "a.com")
        let other = HostGroup(name: "Other", lines: [existing])
        let candidate = HostLine(ip: "1.1.1.1", hostname: "A.com")
        #expect(throws: AddInputError.alreadyInGroup(pair: "1.1.1.1 a.com", group: "Other")) {
            try checkAgainstGroups([candidate], groups: [other], targetGroup: nil, editing: nil)
        }
    }

    @Test func rejectsSameHostnameDifferentIPInTargetGroup() {
        let existing = HostLine(ip: "1.1.1.1", hostname: "a.com")
        let g = HostGroup(name: "G", lines: [existing])
        #expect(throws: AddInputError.conflictingHostname("a.com")) {
            try checkAgainstGroups([HostLine(ip: "2.2.2.2", hostname: "a.com")], groups: [g], targetGroup: g.id, editing: nil)
        }
        // Editing the same line to a new IP is fine.
        #expect(throws: Never.self) {
            try checkAgainstGroups([HostLine(id: existing.id, ip: "2.2.2.2", hostname: "a.com")], groups: [g], targetGroup: g.id, editing: existing.id)
        }
    }
}
