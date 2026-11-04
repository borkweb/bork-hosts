import Foundation
import Observation

/// The state behind the sidebar and file pane. Every operation that reads or writes the hosts file
/// runs one at a time (queued in call order), so a focus-triggered reload can never race a write.
@MainActor @Observable
public final class AppModel {
    private let service: HostsService
    private let store: GroupStore

    public private(set) var groups: [HostGroup] = []
    public private(set) var document = HostsDocument("")
    public private(set) var errorMessage: String?
    public private(set) var notice: String?
    /// True while an operation is running or queued behind one; the views disable switches.
    public private(set) var isBusy = false

    /// The groups file exists but could not be read. It is copied aside before the first save.
    private var storeUnreadable = false
    /// The message the last reload showed, so the next reload clears only its own.
    private var lastReloadMessage: String?
    private var running = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(service: HostsService, store: GroupStore) {
        self.service = service
        self.store = store
    }

    // MARK: Derived state

    /// Ids of enabled lines that share a hostname with a different enabled IP.
    public var conflictIDs: Set<UUID> { HostsEditor.conflicts(groups: groups, in: document) }

    /// Line id to the lowest line number (1-based, whole file) of an active line outside the managed block
    /// that maps the same hostname. Only for sidebar lines that are on. Separate from `conflictIDs`, and
    /// derived from the current document, so it is never stale.
    public var outsideWarnings: [UUID: Int] {
        var warnings: [UUID: Int] = [:]
        for line in groups.flatMap(\.lines) where document.state(of: line) == .on {
            if let number = document.outsideLines(forHostname: line.hostname).first { warnings[line.id] = number }
        }
        return warnings
    }

    public static func outsideWarningText(lineNumber: Int) -> String {
        "Another active line outside the \(HostsDocument.beginMarker) block, line \(lineNumber), also maps this hostname. This app never edits it."
    }

    public func lineState(_ line: HostLine) -> LineState { document.state(of: line) }
    public func groupState(_ group: HostGroup) -> GroupState { HostsEditor.groupState(group, in: document) }
    public func dismissError() { errorMessage = nil }
    public func dismissNotice() { notice = nil }

    // MARK: Serialization

    private func acquire() async {
        isBusy = true
        if running {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            running = true
        }
    }

    private func release() {
        if waiters.isEmpty {
            running = false
            isBusy = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    // MARK: Reload (never writes the hosts file)

    public func reload() async {
        await acquire()
        defer { release() }
        // Clear only a message an earlier reload set. A write that failed after authentication left its
        // own banner, and the focus reload queued behind it must not wipe that out.
        if errorMessage == lastReloadMessage { errorMessage = nil }
        // All problems are shown together; one must not overwrite another. Damaged markers do not stop
        // reading or display, but launch and focus reloads say so, so the problem is seen right away.
        let storeProblem = loadStore()
        let readProblem = readDocument()
        let damageProblem = readProblem == nil ? document.blockDamage.map { HostsServiceError.blockDamaged($0).localizedDescription } : nil
        let problems = [storeProblem, readProblem, damageProblem].compactMap { $0 }
        let message = problems.isEmpty ? nil : problems.joined(separator: "\n")
        if let message { errorMessage = message }
        lastReloadMessage = message
    }

    /// Returns an error message when the groups file could not be read.
    private func loadStore() -> String? {
        do {
            groups = try store.load()
            storeUnreadable = false
            return nil
        } catch {
            storeUnreadable = true
            return "Your saved groups could not be read. A copy of that file will be kept the next time groups are saved. (\(error.localizedDescription))"
        }
    }

    /// Replaces `document`; on failure keeps the previous one, so a read problem never looks like an empty file.
    private func readDocument() -> String? {
        do {
            document = try service.read()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func refreshDocument() {
        if let message = readDocument() { errorMessage = message }
    }

    private func report(_ error: Error) {
        if let write = error as? HostsWriteError, write == .cancelled { return }
        errorMessage = error.localizedDescription
    }

    private func clearMessages() {
        errorMessage = nil
        notice = nil
    }

    /// Checks a fresh read for damaged markers before anything is saved to the store, so a refused add
    /// leaves the store unchanged. An unreadable file is left for the write to report as before.
    private func refuseIfMarkersDamaged() throws {
        guard let damage = (try? service.read())?.blockDamage else { return }
        let error = HostsServiceError.blockDamaged(damage)
        errorMessage = error.localizedDescription
        throw error
    }

    private func noticeText(_ turnedOff: [HostLine]) -> String? {
        turnedOff.isEmpty ? nil : "Turned off " + turnedOff.map { "\($0.ip) \($0.hostname)" }.joined(separator: ", ")
    }

    // MARK: Toggles

    /// Returns whether the line ended up as asked. On failure `errorMessage` says why.
    @discardableResult
    public func setLine(_ line: HostLine, enabled: Bool) async -> Bool {
        await acquire()
        defer { release() }
        clearMessages()
        guard line.isValid else { errorMessage = "\"\(line.ip) \(line.hostname)\" is not a valid entry, so nothing was changed."; return false }
        let snapshot = groups
        var succeeded = false
        do {
            let off = try await service.apply(expect: { enabled ? $0.state(of: line) == .on : $0.state(of: line) != .on }) { doc in
                HostsEditor.setLine(line, enabled: enabled, groups: snapshot, in: &doc)
            }
            notice = noticeText(off)
            succeeded = true
        } catch { report(error) }
        refreshDocument()
        return succeeded
    }

    /// Returns whether the group ended up as asked. On failure `errorMessage` says why.
    @discardableResult
    public func setGroup(_ group: HostGroup, enabled: Bool) async -> Bool {
        await acquire()
        defer { release() }
        clearMessages()
        let group = groups.first { $0.id == group.id } ?? group
        guard group.lines.allSatisfy(\.isValid) else { errorMessage = "This group has an invalid entry, so nothing was changed."; return false }
        let snapshot = groups
        var succeeded = false
        do {
            let off = try await service.apply(expect: { doc in
                group.lines.allSatisfy { enabled ? doc.state(of: $0) == .on : doc.state(of: $0) != .on }
            }) { doc in
                HostsEditor.setGroup(group, enabled: enabled, groups: snapshot, in: &doc)
            }
            notice = noticeText(off)
            succeeded = true
        } catch { report(error) }
        refreshDocument()
        return succeeded
    }

    // MARK: Add

    /// Saves the group first, then enables all its lines in one write. A cancelled or failed write
    /// leaves the group in the sidebar, off.
    public func addGroup(name: String, input: String) async throws {
        await acquire()
        defer { release() }
        let cleanName = try validateGroupName(name)
        let lines = try parseAddInput(input)
        try checkAgainstGroups(lines, groups: groups, targetGroup: nil, editing: nil)
        clearMessages()
        try refuseIfMarkersDamaged()
        let group = HostGroup(name: cleanName, lines: lines)
        try persist(groups + [group])
        groups.append(group)
        await enable(group)
    }

    public func addLine(to groupID: UUID, ip: String, hostname: String) async throws {
        await acquire()
        defer { release() }
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        let line = try validateLine(ip: ip, hostname: hostname)
        try checkAgainstGroups([line], groups: groups, targetGroup: groupID, editing: nil)
        clearMessages()
        try refuseIfMarkersDamaged()
        var updated = groups
        updated[index].lines.append(line)
        try persist(updated)
        groups = updated
        let snapshot = groups
        do {
            let off = try await service.apply(expect: { $0.state(of: line) == .on }) { doc in
                HostsEditor.setLine(line, enabled: true, groups: snapshot, in: &doc)
            }
            notice = noticeText(off)
        } catch { report(error) }
        refreshDocument()
    }

    private func enable(_ group: HostGroup) async {
        let snapshot = groups
        do {
            let off = try await service.apply(expect: { doc in group.lines.allSatisfy { doc.state(of: $0) == .on } }) { doc in
                HostsEditor.setGroup(group, enabled: true, groups: snapshot, in: &doc)
            }
            notice = noticeText(off)
        } catch { report(error) }
        refreshDocument()
    }

    // MARK: Rename and edit

    public func renameGroup(_ id: UUID, to name: String) async {
        await acquire()
        defer { release() }
        clearMessages()
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        do {
            let clean = try validateGroupName(name)
            var updated = groups
            updated[index].name = clean
            try persist(updated)
            groups = updated
        } catch { report(error) }
    }

    /// Rewrites the file line in place (keeping its on/off state), then updates the store.
    /// Returns true only when the edit was applied (file and store) or was a no-op. A cancelled
    /// prompt returns false without an error, so the caller can keep the edit visible.
    /// If the store cannot be saved afterward, the error says so and the next reload shows the true state.
    @discardableResult
    public func editLine(_ lineID: UUID, ip: String, hostname: String) async -> Bool {
        await acquire()
        defer { release() }
        clearMessages()
        guard let gi = groups.firstIndex(where: { $0.lines.contains { $0.id == lineID } }),
              let li = groups[gi].lines.firstIndex(where: { $0.id == lineID }) else {
            errorMessage = "That entry no longer exists, so nothing was changed."
            return false
        }
        let old = groups[gi].lines[li]
        var new: HostLine
        do {
            new = try validateLine(ip: ip, hostname: hostname)
            new.id = old.id
            try checkAgainstGroups([new], groups: groups, targetGroup: groups[gi].id, editing: old.id)
        } catch { report(error); return false }
        if new.ip == old.ip && new.hostname == old.hostname { return true }
        var preview = groups
        preview[gi].lines[li] = new
        let snapshot = preview
        do {
            let off = try await service.apply { doc in HostsEditor.replaceLine(old, with: new, groups: snapshot, in: &doc) }
            notice = noticeText(off)
        } catch {
            report(error)
            refreshDocument()
            return false
        }
        // Apply the edit to the groups as they are now, not to the copy taken before the prompt.
        var updated = groups
        for g in updated.indices {
            if let l = updated[g].lines.firstIndex(where: { $0.id == lineID }) { updated[g].lines[l] = new }
        }
        groups = updated
        var saved = true
        do { try persist(updated) } catch {
            saved = false
            errorMessage = "The hosts file was updated, but your groups could not be saved: \(error.localizedDescription)"
        }
        refreshDocument()
        return saved
    }

    // MARK: Delete

    /// Removes the matching file lines first and drops the group from the store only after the write succeeds.
    public func deleteGroup(_ id: UUID) async {
        await acquire()
        defer { release() }
        clearMessages()
        guard let group = groups.first(where: { $0.id == id }) else { return }
        guard await removeFromFile(group.lines) else { return }
        await dropFromStore { $0.removeAll { $0.id == id } }
    }

    public func deleteLine(_ lineID: UUID) async {
        await acquire()
        defer { release() }
        clearMessages()
        guard let line = groups.flatMap(\.lines).first(where: { $0.id == lineID }) else { return }
        guard await removeFromFile([line]) else { return }
        await dropFromStore { groups in
            for i in groups.indices { groups[i].lines.removeAll { $0.id == lineID } }
        }
    }

    /// System entries are never removed, even if an old groups file lists one.
    private func removeFromFile(_ lines: [HostLine]) async -> Bool {
        let removable = lines.filter { !reservedHostnames.contains($0.hostname.lowercased()) }
        do {
            try await service.apply { doc in for line in removable { doc.remove(line) } }
        } catch {
            report(error)
            refreshDocument()
            return false
        }
        return true
    }

    private func dropFromStore(_ change: (inout [HostGroup]) -> Void) async {
        var updated = groups
        change(&updated)
        groups = updated
        do { try persist(updated) } catch {
            errorMessage = "The hosts file was updated, but your groups could not be saved: \(error.localizedDescription)"
        }
        refreshDocument()
    }

    // MARK: Store

    private func persist(_ newGroups: [HostGroup]) throws {
        if storeUnreadable { try keepUnreadableStoreCopy() }
        try store.save(newGroups)
        storeUnreadable = false
    }

    private func keepUnreadableStoreCopy() throws {
        let url = store.fileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let copy = url.deletingLastPathComponent().appendingPathComponent("groups.unreadable-\(stamp).json")
        try FileManager.default.copyItem(at: url, to: copy)
    }
}
