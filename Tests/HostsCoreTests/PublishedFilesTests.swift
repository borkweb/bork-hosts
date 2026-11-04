import Foundation
import Testing
@testable import HostsCore

/// The repo is meant to be shared, so what ships (source, scripts, docs) must not name a particular machine: no
/// home-directory paths and no IP addresses except loopback and the documentation range (192.0.2.0/24).
/// Tests are excluded because their fixtures use many made-up addresses.
struct PublishedFilesTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    func shippedFiles() -> [URL] {
        var urls: [URL] = []
        for folder in ["Sources", "scripts", "skills"] {
            let enumerator = FileManager.default.enumerator(at: Self.root.appendingPathComponent(folder), includingPropertiesForKeys: nil)
            urls += (enumerator?.compactMap { $0 as? URL } ?? []).filter { ["swift", "sh", "md"].contains($0.pathExtension) }
        }
        // The docs folder holds only published pages; local design notes live in docs/superpowers, which Git ignores.
        let docs = FileManager.default.enumerator(at: Self.root.appendingPathComponent("docs"), includingPropertiesForKeys: nil)
        urls += (docs?.compactMap { $0 as? URL } ?? []).filter { $0.pathExtension == "md" && !$0.path.contains("/docs/superpowers/") }
        urls += ["README.md", "AGENTS.md", "CONTRIBUTING.md", "LICENSE", "Package.swift"].map { Self.root.appendingPathComponent($0) }
        return urls.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    @Test func shippedFilesHaveNoHomeDirectoryPaths() throws {
        let files = shippedFiles()
        #expect(files.count > 10)
        let pattern = try NSRegularExpression(pattern: "/(Users|home)/[A-Za-z0-9._-]+")
        for file in files {
            let text = try readText(file)
            let hits = pattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
            #expect(hits.isEmpty, "\(file.lastPathComponent) names a home directory")
        }
    }

    /// The app is generic: it must not ship another company's tool names, hosts or private scripts. Anyone's own
    /// setup belongs in their Settings, not in the defaults, docs or examples.
    @Test func shippedFilesNameNoCompanyToolsHostsOrScripts() throws {
        let banned = ["a8c", "automattic", "autoproxxy", "big river", "big-river", "wpcom", "wordpress.com", "amisandboxed",
                      "allow-sandbox-production-writes", "context-a8c", "wpdev"]
        for file in shippedFiles() {
            let text = try readText(file).lowercased()
            for word in banned {
                #expect(!text.contains(word), "\(file.lastPathComponent) mentions \(word)")
            }
        }
    }

    @Test func shippedFilesHaveNoIPAddressesExceptLoopbackAndDocumentationRanges() throws {
        let pattern = try NSRegularExpression(pattern: "[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}")
        for file in shippedFiles() where file.lastPathComponent != "Package.swift" {
            let text = try readText(file)
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let address = String(text[Range(match.range, in: text)!])
                let allowed = address == "127.0.0.1" || address == "0.0.0.0" || address.hasPrefix("192.0.2.")
                #expect(allowed, "\(file.lastPathComponent) contains \(address)")
            }
        }
    }
}
