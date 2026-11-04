import Foundation

public enum AddInputError: Error, Equatable {
    case blankName
    case invalidName
    case empty
    case invalidLine(number: Int, text: String)
    case conflictingHostname(String)
    /// `localhost` and `broadcasthost` can never be sidebar items, so Delete cannot remove them.
    case reservedHostname(String)
    case alreadyInGroup(pair: String, group: String)
}

extension AddInputError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .blankName: return "Enter a name for the group."
        case .invalidName: return "A group name must be a single line."
        case .empty: return "Enter at least one line such as 192.0.2.10 example.com."
        case let .invalidLine(number, text): return "Line \(number) is not a valid IP address and hostname: \(text)"
        case let .conflictingHostname(host): return "\(host) is mapped to more than one IP address in the same group."
        case let .reservedHostname(host): return "\(host) is a system entry and cannot be added."
        case let .alreadyInGroup(pair, group): return "\(pair) is already in the group \"\(group)\"."
        }
    }
}

let reservedHostnames: Set<String> = ["localhost", "broadcasthost"]

public func validateGroupName(_ name: String) throws -> String {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { throw AddInputError.blankName }
    if trimmed.contains(where: \.isNewline) { throw AddInputError.invalidName }
    return trimmed
}

/// Validates one IP and hostname pair typed into a field.
public func validateLine(ip: String, hostname: String, number: Int = 1) throws -> HostLine {
    let ip = ip.trimmingCharacters(in: .whitespaces)
    let host = hostname.trimmingCharacters(in: .whitespaces)
    guard HostsValidation.isValidIP(ip), HostsValidation.isValidHostname(host) else {
        throw AddInputError.invalidLine(number: number, text: "\(ip) \(host)".trimmingCharacters(in: .whitespaces))
    }
    if reservedHostnames.contains(host.lowercased()) { throw AddInputError.reservedHostname(host.lowercased()) }
    return HostLine(ip: ip, hostname: host)
}

/// Parses pasted hosts lines into sidebar lines, one per hostname.
public func parseAddInput(_ text: String) throws -> [HostLine] {
    var result: [HostLine] = []
    var seenPairs = Set<String>()
    var ipByHost: [String: [UInt8]] = [:]
    for (index, raw) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
        let number = index + 1
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let content = trimmed.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let tokens = content.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        if tokens.isEmpty { continue }
        guard tokens.count >= 2 else { throw AddInputError.invalidLine(number: number, text: trimmed) }
        for host in tokens.dropFirst() {
            let line: HostLine
            do { line = try validateLine(ip: tokens[0], hostname: host, number: number) } catch AddInputError.invalidLine {
                throw AddInputError.invalidLine(number: number, text: trimmed)
            }
            guard let key = HostsValidation.ipKey(line.ip) else { continue }
            let lower = line.hostname.lowercased()
            if let known = ipByHost[lower], known != key { throw AddInputError.conflictingHostname(lower) }
            ipByHost[lower] = key
            if seenPairs.insert("\(key)|\(lower)").inserted { result.append(line) }
        }
    }
    if result.isEmpty { throw AddInputError.empty }
    return result
}

/// Rejects lines that would break the sidebar's invariants.
/// - A pair already in another group (two sidebar items must never share one file line).
/// - The same pair twice in the target group, or one hostname with two IPs in the target group.
/// `editing` is the id of the line being replaced, which is excluded from the comparison.
public func checkAgainstGroups(_ lines: [HostLine], groups: [HostGroup], targetGroup: UUID?, editing: UUID?) throws {
    for line in lines {
        guard let key = HostsValidation.ipKey(line.ip) else { continue }
        let lower = line.hostname.lowercased()
        for group in groups {
            for other in group.lines where other.id != editing {
                guard other.hostname.lowercased() == lower else { continue }
                let sameIP = HostsValidation.ipKey(other.ip) == key
                if sameIP { throw AddInputError.alreadyInGroup(pair: "\(line.ip) \(lower)", group: group.name) }
                if group.id == targetGroup { throw AddInputError.conflictingHostname(lower) }
            }
        }
    }
}
