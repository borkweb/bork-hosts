import Foundation

public struct HostLine: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var ip: String
    public var hostname: String

    public init(id: UUID = UUID(), ip: String, hostname: String) {
        self.id = id
        self.ip = ip
        self.hostname = hostname
    }
}

public struct HostGroup: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var lines: [HostLine]

    public init(id: UUID = UUID(), name: String, lines: [HostLine]) {
        self.id = id
        self.name = name
        self.lines = lines
    }
}

public enum LineState: Equatable, Sendable { case on, off, missing }

public enum GroupState: Equatable, Sendable { case on, off, mixed }

/// Shared input rules. Anything that reaches the root-written file passes through these.
public enum HostsValidation {
    /// Dotted IPv4 or IPv6 text with no zone id, whitespace, or control characters.
    public static func isValidIP(_ s: String) -> Bool {
        guard !s.isEmpty, s.unicodeScalars.allSatisfy({ "0123456789abcdefABCDEF:.".unicodeScalars.contains($0) }) else {
            return false
        }
        return ipKey(s) != nil
    }

    /// Dot-separated labels of `[A-Za-z0-9_-]`, 1-63 each, no leading or trailing hyphen, 253 total.
    public static func isValidHostname(_ s: String) -> Bool {
        guard !s.isEmpty, s.utf8.count <= 253 else { return false }
        for label in s.split(separator: ".", omittingEmptySubsequences: false) {
            guard (1...63).contains(label.utf8.count),
                  !label.hasPrefix("-"), !label.hasSuffix("-"),
                  label.unicodeScalars.allSatisfy({ isLabelScalar($0) })
            else { return false }
        }
        return true
    }

    /// Canonical bytes of an IP so `FE80::1` and `fe80::1` compare equal.
    static func ipKey(_ s: String) -> [UInt8]? {
        var v4 = in_addr()
        if inet_pton(AF_INET, s, &v4) == 1 {
            return [4] + withUnsafeBytes(of: &v4) { Array($0) }
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, s, &v6) == 1 {
            return [6] + withUnsafeBytes(of: &v6) { Array($0) }
        }
        return nil
    }

    private static func isLabelScalar(_ c: Unicode.Scalar) -> Bool {
        switch c {
        case "a"..."z", "A"..."Z", "0"..."9", "_", "-": return true
        default: return false
        }
    }
}

extension HostLine {
    public var isValid: Bool {
        HostsValidation.isValidIP(ip) && HostsValidation.isValidHostname(hostname)
    }
}
