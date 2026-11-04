import Testing
@testable import HostsCore

struct HostsEditorTests {
    let a1 = HostLine(ip: "10.0.0.1", hostname: "x.com")
    let b1 = HostLine(ip: "10.0.0.2", hostname: "X.COM")
    let a2 = HostLine(ip: "10.0.0.1", hostname: "y.com")
    let b2 = HostLine(ip: "10.0.0.2", hostname: "y.com")
    var groupA: HostGroup { HostGroup(name: "A", lines: [a1, a2]) }
    var groupB: HostGroup { HostGroup(name: "B", lines: [b1, b2]) }

    @Test func enablingLineDisablesOtherIPForSameHostname() {
        var d = HostsDocument(blk("127.0.0.1 localhost\n10.0.0.1 x.com\n# 10.0.0.2 X.COM\n"))
        let off = HostsEditor.setLine(b1, enabled: true, groups: [groupA, groupB], in: &d)
        #expect(d.text == blk("127.0.0.1 localhost\n# 10.0.0.1 x.com\n10.0.0.2 X.COM\n"))
        #expect(off == [a1])
    }

    @Test func hostnameConflictIsCaseInsensitive() {
        var d = HostsDocument(blk("10.0.0.1 x.com\n"))
        _ = HostsEditor.setLine(b1, enabled: true, groups: [groupA, groupB], in: &d)
        #expect(d.state(of: a1) == .off)
        #expect(d.state(of: b1) == .on)
    }

    @Test func enablingGroupDisablesConflictsOutsideGroup() {
        var d = HostsDocument(blk("10.0.0.1 x.com\n10.0.0.1 y.com\n# 10.0.0.2 X.COM\n# 10.0.0.2 y.com\n"))
        let off = HostsEditor.setGroup(groupB, enabled: true, groups: [groupA, groupB], in: &d)
        #expect(d.text == blk("# 10.0.0.1 x.com\n# 10.0.0.1 y.com\n10.0.0.2 X.COM\n10.0.0.2 y.com\n"))
        #expect(Set(off) == [a1, a2])
        #expect(!off.contains(b1) && !off.contains(b2))
    }

    @Test func sameIPSameHostnameIsNotAConflict() {
        let twin = HostLine(ip: "10.0.0.1", hostname: "x.com")
        var d = HostsDocument(blk("10.0.0.1 x.com\n"))
        let off = HostsEditor.setLine(twin, enabled: true, groups: [groupA, HostGroup(name: "T", lines: [twin])], in: &d)
        #expect(off.isEmpty)
        #expect(d.text == blk("10.0.0.1 x.com\n"))
    }

    @Test func disablingNeverTouchesOtherLines() {
        var d = HostsDocument(blk("10.0.0.1 x.com\n10.0.0.2 X.COM\n"))
        let off = HostsEditor.setLine(a1, enabled: false, groups: [groupA, groupB], in: &d)
        #expect(d.text == blk("# 10.0.0.1 x.com\n10.0.0.2 X.COM\n"))
        #expect(off.isEmpty)
    }

    @Test func conflictsReportsBothEnabledLinesOnLaunchState() {
        let d = HostsDocument(blk("10.0.0.1 x.com\n10.0.0.2 x.com\n"))
        #expect(HostsEditor.conflicts(groups: [groupA, groupB], in: d) == [a1.id, b1.id])
    }

    @Test func conflictsEmptyWhenOneSideOff() {
        let d = HostsDocument(blk("10.0.0.1 x.com\n# 10.0.0.2 x.com\n"))
        #expect(HostsEditor.conflicts(groups: [groupA, groupB], in: d).isEmpty)
    }

    @Test func groupStateOnOffMixed() {
        let g = groupA
        #expect(HostsEditor.groupState(g, in: HostsDocument(blk("10.0.0.1 x.com\n10.0.0.1 y.com\n"))) == .on)
        #expect(HostsEditor.groupState(g, in: HostsDocument(blk("# 10.0.0.1 x.com\n"))) == .off)
        #expect(HostsEditor.groupState(g, in: HostsDocument(blk("10.0.0.1 x.com\n"))) == .mixed)
        #expect(HostsEditor.groupState(HostGroup(name: "E", lines: []), in: HostsDocument("")) == .off)
    }

    @Test func replaceLineResolvesConflictsWhenEditedLineIsOn() {
        // Editing a on line so it now clashes with an enabled line elsewhere turns the other off.
        let edited = HostLine(id: a1.id, ip: "10.0.0.2", hostname: "x.com")
        let other = HostLine(ip: "10.0.0.9", hostname: "x.com")
        var d = HostsDocument(blk("10.0.0.1 x.com\n10.0.0.9 x.com\n"))
        let groups = [HostGroup(name: "A", lines: [edited]), HostGroup(name: "O", lines: [other])]
        let off = HostsEditor.replaceLine(a1, with: edited, groups: groups, in: &d)
        #expect(d.text == blk("10.0.0.2 x.com\n# 10.0.0.9 x.com\n"))
        #expect(off == [other])
    }
}
