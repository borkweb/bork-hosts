import Foundation

public enum HostsServiceError: Error, Equatable {
    case unreadable, missingLocalhost
    /// The edit did not produce the intended state, so nothing was written.
    case postconditionFailed
    case backupFailed(String)
    /// The BEGIN/END markers are unusable, so nothing was written.
    case blockDamaged(BlockDamage)
    /// The edit would change bytes outside the managed block, so nothing was written.
    case confinementViolated
}

extension HostsServiceError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unreadable: return "The hosts file is missing, unreadable, or not valid UTF-8 text. Nothing was changed."
        case .missingLocalhost: return "The hosts file has no enabled localhost entry, so it was not changed."
        case .postconditionFailed: return "The change could not be applied to this file, so nothing was written."
        case let .backupFailed(message): return "Could not back up the hosts file, so nothing was written. \(message)"
        case let .blockDamaged(damage): return "\(damage.problem) Fix the markers by hand. Nothing was changed."
        case .confinementViolated: return "The change would alter lines outside the \(HostsDocument.beginMarker) block, so nothing was written."
        }
    }
}

/// Fresh read, mutate, validate, back up, write, retry once when the file changed underneath us.
public final class HostsService: @unchecked Sendable {
    private let hostsURL: URL
    private let writer: HostsWriter
    private let backups: BackupManager

    public init(hostsURL: URL = URL(fileURLWithPath: "/etc/hosts"), writer: HostsWriter, backups: BackupManager) {
        self.hostsURL = hostsURL
        self.writer = writer
        self.backups = backups
    }

    /// Reads the raw bytes and refuses anything that is not plain UTF-8 without NUL bytes or a BOM,
    /// so the text we hash and back up is byte for byte what is on disk.
    public func read() throws -> HostsDocument {
        HostsDocument(try readText())
    }

    private func readText() throws -> String {
        guard let data = try? Data(contentsOf: hostsURL), !data.contains(0),
              let text = String(data: data, encoding: .utf8), Data(text.utf8) == data
        else { throw HostsServiceError.unreadable }
        return text
    }

    /// The backstop, computed only from the two texts: every byte before the BEGIN line and from the END
    /// line on is identical to the old file (the marker lines belong to those regions). When the old file
    /// has no block, it must be an exact prefix of the new one, followed only by the line breaks creation
    /// adds, then one well-formed block that ends the text. The new text is re-parsed here, so a bug in a document mutator cannot
    /// vouch for itself.
    static func confine(old: String, new: String) throws {
        let oldBytes = Array(old.utf8), newBytes = Array(new.utf8)
        let newDoc = HostsDocument(new)
        guard newDoc.blockDamage == nil, let newBlock = newDoc.blockByteOffsets else { throw HostsServiceError.confinementViolated }
        if let oldBlock = HostsDocument(old).blockByteOffsets {
            let suffix = oldBytes[oldBlock.endLineStart...]
            guard newBlock.beginLineEnd == oldBlock.beginLineEnd,
                  newBlock.endLineStart == newBytes.count - suffix.count,
                  newBytes[..<oldBlock.beginLineEnd].elementsEqual(oldBytes[..<oldBlock.beginLineEnd]),
                  newBytes[newBlock.endLineStart...].elementsEqual(suffix)
            else { throw HostsServiceError.confinementViolated }
        } else {
            // Creation appends exactly one block: the old bytes, then at most the repaired final newline and
            // one blank line (CR and LF bytes only), then BEGIN ... END, with END as the last line.
            guard newBytes.starts(with: oldBytes), newBlock.beginLineStart >= oldBytes.count,
                  newBlock.endLineEnd == newBytes.count
            else { throw HostsServiceError.confinementViolated }
            let gap = newBytes[oldBytes.count..<newBlock.beginLineStart]
            let repairedNewline = oldBytes.isEmpty || oldBytes.last == 10 ? 0 : 2
            let allowed = oldBytes.isEmpty ? 0 : repairedNewline + 2
            guard gap.allSatisfy({ $0 == 10 || $0 == 13 }), gap.count <= allowed else { throw HostsServiceError.confinementViolated }
        }
    }

    @discardableResult
    public func apply<T>(expect: ((HostsDocument) -> Bool)? = nil, _ mutate: (inout HostsDocument) -> T) async throws -> T {
        var retried = false
        while true {
            let freshText = try readText()
            let fresh = HostsDocument(freshText)
            // Before the no-op return, so even a change that would have done nothing reports the damage.
            if let damage = fresh.blockDamage { throw HostsServiceError.blockDamaged(damage) }
            var doc = fresh
            let result = mutate(&doc)
            let newText = doc.text
            // Bytes, not Swift String equality: canonically equal text (e + U+0301 vs U+00E9) is still a change.
            if newText.utf8.elementsEqual(freshText.utf8) { return result }
            try Self.confine(old: freshText, new: newText)
            guard fresh.hasEnabledLocalhost, doc.hasEnabledLocalhost, !doc.text.isEmpty else {
                throw HostsServiceError.missingLocalhost
            }
            if let expect, !expect(doc) { throw HostsServiceError.postconditionFailed }
            let backup: URL
            do { backup = try backups.createBackup(of: freshText) } catch {
                throw HostsServiceError.backupFailed(error.localizedDescription)
            }
            do {
                try await writer.write(newContent: doc.text, expectedCurrentSHA256: sha256Hex(freshText))
            } catch HostsWriteError.stale where !retried {
                backups.discard(backup)
                retried = true
                continue
            } catch {
                backups.discard(backup)
                throw error
            }
            try? backups.prune()
            return result
        }
    }
}
