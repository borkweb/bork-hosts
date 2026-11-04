import AppKit
import HostsCore
import UniformTypeIdentifiers

/// The Export and Import buttons in Settings: pick a file, then (for an import) show what would change and ask.
@MainActor
enum SettingsTransfer {
    static let fileName = "bork-hosts-settings.json"

    static func export(_ controller: SandboxController) {
        let panel = NSSavePanel()
        panel.title = "Export Settings"
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = fileName
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.message = "The file holds your sandbox settings, including any ssh host and command. Share it only with people you trust."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try controller.exportSettings().write(to: url, options: .atomic)
            // Only you need to read it.
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            show("Could not export the settings", error.localizedDescription)
        }
    }

    static func importFile(_ controller: SandboxController) {
        guard !controller.isRunning else {
            show("The sandbox is busy", "Wait for the current run to finish, then import.")
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Import Settings"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            guard size <= SandboxSettingsFile.maxBytes else {
                throw SandboxSettingsFile.Invalid(message: "This file is too large to be a bork-hosts settings file.")
            }
            let imported = try controller.previewImport(Data(contentsOf: url))
            guard !imported.changes.isEmpty else {
                show("Nothing to change", "These settings match the ones you have now.")
                return
            }
            if confirm(imported.changes) { controller.applyImport(imported) }
        } catch {
            show("Could not import the settings", error.localizedDescription)
        }
    }

    // MARK: Alerts

    private static func confirm(_ changes: [SandboxSettingsFile.Change]) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Import these settings?"
        var lines = changes.prefix(14).map { "\($0.label): \($0.old) \u{2192} \($0.new)" }
        if changes.count > 14 { lines.append("and \(changes.count - 14) more") }
        var text = lines.joined(separator: "\n")
        if changes.contains(where: \.actsOnSwitchOn) {
            text += "\n\nSome of these run or change things the next time you switch the sandbox on, such as the ssh command and the MCP config files. Only import a file you trust."
        }
        text += "\n\nThe panel's on/off choice is not changed."
        alert.informativeText = text
        alert.addButton(withTitle: "Import")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func show(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = detail
        alert.runModal()
    }
}
