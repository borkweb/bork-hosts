import Foundation

/// Edits the `env` of servers in a Codex or Grok `config.toml`, as text, so everything else in the file stays exactly
/// as it was (comments, order, spacing).
///
/// Both tools keep stdio MCP servers in `[mcp_servers.<name>]` tables. A server's environment may be written as a
/// `[mcp_servers.<name>.env]` table or as an inline `env = { A = "x" }`; both are handled. Switching on adds the proxy
/// variables; switching off removes only those that still hold the proxy URL, and removes an `env` it leaves empty,
/// so a round trip gives the original file back. A server written with `url = ...` is reported, not changed: an
/// environment variable cannot reach a remote (HTTP) transport. This is a line reader, not a TOML parser, so anything
/// it does not recognize throws and the file is left alone.
public enum TOMLConfig {
    struct Invalid: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    public static func apply(_ mode: SandboxMode, routes: [MCPRoute], proxyURL: String, to data: Data) throws -> MCPEditResult {
        guard let text = String(data: data, encoding: .utf8) else { throw Invalid(message: "The file is not UTF-8 text.") }
        var lines = text.components(separatedBy: "\n")
        var result = MCPEditResult(data: nil, routed: [], missing: [], unsupported: [])
        var changed = false
        for route in routes {
            do {
                switch try editServer(route, mode: mode, proxy: proxyURL, lines: &lines) {
                case .missing: result.missing.append(route.name)
                case .unsupported: result.unsupported.append(route.name)
                case let .routed(didChange):
                    result.routed.append(route.name)
                    changed = changed || didChange
                }
            } catch let error as Invalid {
                throw Invalid(message: "\u{201C}\(route.name)\u{201D}: \(error.message)")
            }
        }
        if changed { result.data = Data(lines.joined(separator: "\n").utf8) }
        return result
    }

    // MARK: One server

    private enum Found { case missing, unsupported, routed(changed: Bool) }

    private static func editServer(_ route: MCPRoute, mode: SandboxMode, proxy: String, lines: inout [String]) throws -> Found {
        let table = ["mcp_servers", route.name]
        let kinds = classify(lines)
        guard let server = headerIndex(kinds, table) else { return .missing }
        let entries = keyValues(lines, kinds, server + 1..<tableEnd(kinds, server))
        if entries.contains(where: { $0.path == ["url"] }), !entries.contains(where: { $0.path == ["command"] }) { return .unsupported }
        if entries.contains(where: { $0.path.first == "env" && $0.path.count > 1 }) {
            throw Invalid(message: "env is written with dotted keys. Edit it by hand or rewrite it as env = { ... }.")
        }
        var changed = false
        if headerIndex(kinds, table + ["env"]) != nil {
            changed = try editEnvTable(route, mode: mode, proxy: proxy, lines: &lines)
        } else if let inline = entries.first(where: { $0.path == ["env"] }) {
            changed = try editInlineEnv(at: inline.index, route, mode: mode, proxy: proxy, lines: &lines)
        } else if mode == .on {
            var at = server + 1
            for index in server + 1..<tableEnd(kinds, server) where kinds[index] != .other { at = index + 1 }
            let pairs = route.envKeys.map { "\($0) = \"\(proxy)\"" }.joined(separator: ", ")
            lines.insert("env = { \(pairs) }", at: at)
            changed = true
        }
        return .routed(changed: changed)
    }

    private static func editEnvTable(_ route: MCPRoute, mode: SandboxMode, proxy: String, lines: inout [String]) throws -> Bool {
        let path = ["mcp_servers", route.name, "env"]
        var changed = false
        for key in route.envKeys {
            let kinds = classify(lines)
            guard let header = headerIndex(kinds, path) else { break }
            let end = tableEnd(kinds, header)
            let hit = keyValues(lines, kinds, header + 1..<end).first { $0.path == [key] }
            if let hit {
                if hit.index + 1 < kinds.count, kinds[hit.index + 1] == .continuation {
                    throw Invalid(message: "\(key) spans several lines. Edit it by hand.")
                }
                let current = stringValue(hit.raw)
                switch mode {
                case .on where current != proxy:
                    lines[hit.index] = indent(of: lines[hit.index]) + "\(key) = \"\(proxy)\""
                    changed = true
                case .off where current == proxy:
                    lines.remove(at: hit.index)
                    changed = true
                default: break
                }
            } else if mode == .on {
                var at = header + 1
                for index in header + 1..<end where kinds[index] != .other { at = index + 1 }
                lines.insert("\(key) = \"\(proxy)\"", at: at)
                changed = true
            }
        }
        if mode == .off, changed {
            // An env table that has nothing left in it goes away, so the file is as it was before the switch.
            let kinds = classify(lines)
            if let header = headerIndex(kinds, path) {
                let end = tableEnd(kinds, header)
                if lines[header + 1..<end].allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                    lines.removeSubrange(header..<end)
                }
            }
        }
        return changed
    }

    private static func editInlineEnv(at index: Int, _ route: MCPRoute, mode: SandboxMode, proxy: String, lines: inout [String]) throws -> Bool {
        let chars = Array(lines[index])
        guard let key = parseKeyPath(chars, from: 0), let equals = skipSpaces(chars, key.next), equals < chars.count, chars[equals] == "=",
              let open = skipSpaces(chars, equals + 1), open < chars.count, chars[open] == "{",
              let close = matchingBrace(chars, open) else {
            throw Invalid(message: "env is not a simple inline table. Edit it by hand.")
        }
        var pairs: [(key: String, text: String, value: String?)] = []
        for piece in splitTopLevel(Array(chars[open + 1..<close])) {
            let trimmed = piece.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            let p = Array(trimmed)
            guard let k = parseKeyPath(p, from: 0), k.path.count == 1, let eq = skipSpaces(p, k.next), eq < p.count, p[eq] == "=" else {
                throw Invalid(message: "env has an entry this editor cannot read. Edit it by hand.")
            }
            pairs.append((k.path[0], trimmed, stringValue(String(p[(eq + 1)...]))))
        }
        var changed = false
        for envKey in route.envKeys {
            let at = pairs.firstIndex { $0.key == envKey }
            switch mode {
            case .on:
                let text = "\(envKey) = \"\(proxy)\""
                if let at { if pairs[at].value != proxy { pairs[at] = (envKey, text, proxy); changed = true } }
                else { pairs.append((envKey, text, proxy)); changed = true }
            case .off:
                if let at, pairs[at].value == proxy { pairs.remove(at: at); changed = true }
            }
        }
        guard changed else { return false }
        if pairs.isEmpty {
            lines.remove(at: index)
        } else {
            let before = String(chars[..<open])
            let after = String(chars[(close + 1)...])
            lines[index] = before + "{ " + pairs.map(\.text).joined(separator: ", ") + " }" + after
        }
        return true
    }

    // MARK: Reading lines

    enum Kind: Equatable {
        case header([String])
        case keyValue
        /// The rest of a value that runs over several lines.
        case continuation
        /// Blank or a comment.
        case other
    }

    /// What each line is. Tracks multi-line strings and arrays so a line inside one is never read as a header.
    static func classify(_ lines: [String]) -> [Kind] {
        var kinds: [Kind] = []
        var multi: String?
        var depth = 0
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if multi == nil, depth == 0 {
                if trimmed.isEmpty || trimmed.hasPrefix("#") { kinds.append(.other); continue }
                if trimmed.hasPrefix("[") { kinds.append(.header(parseHeader(trimmed) ?? [])); continue }
                kinds.append(.keyValue)
            } else {
                kinds.append(.continuation)
            }
            scan(Array(line), multi: &multi, depth: &depth)
        }
        return kinds
    }

    private static func scan(_ chars: [Character], multi: inout String?, depth: inout Int) {
        var quote: Character?
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if let open = multi {
                if open == "\"\"\"", c == "\\" { i += 2; continue }
                if starts(chars, at: i, with: open) { multi = nil; i += 3; continue }
                i += 1
                continue
            }
            if let q = quote {
                if q == "\"", c == "\\" { i += 2; continue }
                if c == q { quote = nil }
                i += 1
                continue
            }
            switch c {
            case "#": return
            case "\"", "'":
                let triple = String(repeating: c, count: 3)
                if starts(chars, at: i, with: triple) { multi = triple; i += 3; continue }
                quote = c
            case "[", "{": depth += 1
            case "]", "}": depth = max(0, depth - 1)
            default: break
            }
            i += 1
        }
    }

    private static func starts(_ chars: [Character], at i: Int, with s: String) -> Bool {
        let w = Array(s)
        return i + w.count <= chars.count && Array(chars[i..<i + w.count]) == w
    }

    private static func parseHeader(_ trimmed: String) -> [String]? {
        let chars = Array(trimmed)
        let open = chars.starts(with: ["[", "["]) ? 2 : 1
        guard let key = parseKeyPath(chars, from: open) else { return nil }
        return key.path
    }

    private static func headerIndex(_ kinds: [Kind], _ path: [String]) -> Int? {
        kinds.firstIndex { $0 == .header(path) }
    }

    private static func tableEnd(_ kinds: [Kind], _ header: Int) -> Int {
        for i in header + 1..<kinds.count { if case .header = kinds[i] { return i } }
        return kinds.count
    }

    struct Entry { var index: Int; var path: [String]; var raw: String }

    private static func keyValues(_ lines: [String], _ kinds: [Kind], _ range: Range<Int>) -> [Entry] {
        var out: [Entry] = []
        for i in range where kinds[i] == .keyValue {
            let chars = Array(lines[i])
            guard let key = parseKeyPath(chars, from: 0), let eq = skipSpaces(chars, key.next), eq < chars.count, chars[eq] == "=" else { continue }
            out.append(Entry(index: i, path: key.path, raw: String(chars[(eq + 1)...])))
        }
        return out
    }

    private static func indent(of line: String) -> String { String(line.prefix { $0 == " " || $0 == "\t" }) }

    // MARK: Small pieces of TOML

    private static func skipSpaces(_ chars: [Character], _ from: Int) -> Int? {
        var i = from
        while i < chars.count, chars[i] == " " || chars[i] == "\t" { i += 1 }
        return i
    }

    /// A dotted key such as `a."b c".d`, starting at `from`. `next` is the index after it.
    static func parseKeyPath(_ chars: [Character], from: Int) -> (path: [String], next: Int)? {
        var path: [String] = []
        var i = skipSpaces(chars, from) ?? from
        while true {
            guard i < chars.count else { return nil }
            var part = ""
            if chars[i] == "\"" || chars[i] == "'" {
                let q = chars[i]
                i += 1
                while i < chars.count, chars[i] != q {
                    if q == "\"", chars[i] == "\\", i + 1 < chars.count { i += 1 }
                    part.append(chars[i])
                    i += 1
                }
                guard i < chars.count else { return nil }
                i += 1
            } else {
                while i < chars.count, chars[i].isLetter || chars[i].isNumber || chars[i] == "_" || chars[i] == "-" {
                    part.append(chars[i])
                    i += 1
                }
                guard !part.isEmpty else { return nil }
            }
            path.append(part)
            let after = skipSpaces(chars, i) ?? i
            if after < chars.count, chars[after] == "." { i = skipSpaces(chars, after + 1) ?? after + 1; continue }
            return (path, after)
        }
    }

    /// The text of a one-line string value (`"..."` or `'...'`), or nil for anything else.
    static func stringValue(_ raw: String) -> String? {
        let chars = Array(raw.trimmingCharacters(in: .whitespaces))
        guard let q = chars.first, q == "\"" || q == "'" else { return nil }
        var out = ""
        var i = 1
        while i < chars.count, chars[i] != q {
            if q == "\"", chars[i] == "\\", i + 1 < chars.count { i += 1 }
            out.append(chars[i])
            i += 1
        }
        guard i < chars.count else { return nil }
        let rest = String(chars[(i + 1)...]).trimmingCharacters(in: .whitespaces)
        return rest.isEmpty || rest.hasPrefix("#") ? out : nil
    }

    private static func matchingBrace(_ chars: [Character], _ open: Int) -> Int? {
        var depth = 0
        var quote: Character?
        var i = open
        while i < chars.count {
            let c = chars[i]
            if let q = quote {
                if q == "\"", c == "\\" { i += 2; continue }
                if c == q { quote = nil }
            } else {
                switch c {
                case "\"", "'": quote = c
                case "{", "[": depth += 1
                case "}", "]":
                    depth -= 1
                    if depth == 0 { return c == "}" ? i : nil }
                case "#": return nil
                default: break
                }
            }
            i += 1
        }
        return nil
    }

    private static func splitTopLevel(_ chars: [Character]) -> [String] {
        var pieces: [String] = []
        var current = ""
        var depth = 0
        var quote: Character?
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if let q = quote {
                current.append(c)
                if q == "\"", c == "\\", i + 1 < chars.count { i += 1; current.append(chars[i]) } else if c == q { quote = nil }
            } else {
                switch c {
                case "\"", "'": quote = c; current.append(c)
                case "{", "[": depth += 1; current.append(c)
                case "}", "]": depth -= 1; current.append(c)
                case "," where depth == 0: pieces.append(current); current = ""
                default: current.append(c)
                }
            }
            i += 1
        }
        pieces.append(current)
        return pieces
    }
}
