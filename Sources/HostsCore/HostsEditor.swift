import Foundation

/// Toggles that keep one enabled IP per hostname across all sidebar lines.
public enum HostsEditor {
    /// Returns the lines that were turned off to make room.
    @discardableResult
    public static func setLine(_ line: HostLine, enabled: Bool, groups: [HostGroup], in doc: inout HostsDocument) -> [HostLine] {
        guard enabled else {
            doc.setEnabled(line, false)
            return []
        }
        let off = disableConflicts(of: [line], groups: groups, keeping: [line], in: &doc)
        doc.setEnabled(line, true)
        return off
    }

    @discardableResult
    public static func setGroup(_ group: HostGroup, enabled: Bool, groups: [HostGroup], in doc: inout HostsDocument) -> [HostLine] {
        guard enabled else {
            for line in group.lines { doc.setEnabled(line, false) }
            return []
        }
        let off = disableConflicts(of: group.lines, groups: groups, keeping: group.lines, in: &doc)
        for line in group.lines { doc.setEnabled(line, true) }
        return off
    }

    /// Rewrites `old` as `new` in place. If the result is enabled, other enabled lines with the
    /// same hostname and a different IP are turned off in the same write. `groups` must already
    /// contain `new`.
    @discardableResult
    public static func replaceLine(_ old: HostLine, with new: HostLine, groups: [HostGroup], in doc: inout HostsDocument) -> [HostLine] {
        doc.replace(old, with: new)
        guard doc.state(of: new) == .on else { return [] }
        return disableConflicts(of: [new], groups: groups, keeping: [new], in: &doc)
    }

    /// Ids of enabled sidebar lines that share a hostname with a different enabled IP.
    public static func conflicts(groups: [HostGroup], in doc: HostsDocument) -> Set<UUID> {
        var byHost: [String: [HostLine]] = [:]
        for line in groups.flatMap(\.lines) where doc.state(of: line) == .on {
            byHost[line.hostname.lowercased(), default: []].append(line)
        }
        var ids = Set<UUID>()
        for lines in byHost.values where Set(lines.compactMap { HostsValidation.ipKey($0.ip) }).count > 1 {
            ids.formUnion(lines.map(\.id))
        }
        return ids
    }

    public static func groupState(_ group: HostGroup, in doc: HostsDocument) -> GroupState {
        let states = group.lines.map { doc.state(of: $0) }
        let on = states.filter { $0 == .on }.count
        if on == 0 { return .off }
        return on == states.count ? .on : .mixed
    }

    private static func disableConflicts(of targets: [HostLine], groups: [HostGroup], keeping: [HostLine], in doc: inout HostsDocument) -> [HostLine] {
        let keepIDs = Set(keeping.map(\.id))
        var off: [HostLine] = []
        var seen = Set<String>()
        for target in targets {
            guard let targetKey = HostsValidation.ipKey(target.ip) else { continue }
            for other in groups.flatMap(\.lines) where !keepIDs.contains(other.id) {
                guard other.hostname.lowercased() == target.hostname.lowercased(),
                      let otherKey = HostsValidation.ipKey(other.ip), otherKey != targetKey,
                      doc.state(of: other) == .on
                else { continue }
                doc.setEnabled(other, false)
                if seen.insert("\(otherKey)|\(other.hostname.lowercased())").inserted { off.append(other) }
            }
        }
        return off
    }
}
