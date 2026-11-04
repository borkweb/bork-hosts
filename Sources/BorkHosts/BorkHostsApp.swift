import AppKit
import HostsCore
import SwiftUI

@main
struct BorkHostsApp: App {
    @State private var model: AppModel
    @State private var sandbox: SandboxController
    @State private var agentServer: AgentSocketServer

    init() {
        // One writer for both, so a single macOS authorization covers the hosts file and the proxy bypass.
        let writer = AuthorizationWriter()
        let service = HostsService(writer: writer, backups: BackupManager(directory: BackupManager.defaultDirectory))
        let model = AppModel(service: service, store: GroupStore(fileURL: GroupStore.defaultURL))
        _model = State(initialValue: model)
        let preferences: @Sendable () -> SandboxPreferences = { SandboxPreferences.load() }
        let controller = SandboxController(
            model: model,
            network: SandboxNetwork(runner: writer, preferences: preferences, log: SandboxLog.append),
            browser: DiaBrowser(),
            mcp: SandboxMCP(preferences: preferences, log: SandboxLog.append),
            remote: SandboxSSH(preferences: preferences, log: SandboxLog.append),
            verifier: SandboxProbe(preferences: preferences, log: SandboxLog.append),
            log: SandboxLog.append)
        _sandbox = State(initialValue: controller)
        // Agents and scripts reach the app through the bork-hosts command, which sends requests to this socket.
        let agent = AgentService(model: model, sandbox: controller)
        _agentServer = State(initialValue: AgentSocketServer { request in await agent.handle(request) })
    }

    @MainActor
    private static func redrawWindows() {
        for window in NSApplication.shared.windows {
            window.contentView?.needsLayout = true
            window.contentView?.needsDisplay = true
            window.displayIfNeeded()
        }
    }

    var body: some Scene {
        WindowGroup("bork-hosts") {
            ContentView(model: model, sandbox: sandbox)
                .frame(minWidth: 760, minHeight: 440)
                .task {
                    NSApplication.shared.setActivationPolicy(.regular)
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    try? agentServer.start()
                    await model.reload()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    Task { await model.reload() }
                    Self.redrawWindows()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    agentServer.stop()
                }
                // Experiment: after a toggle the window once stopped repainting until something forced a layout.
                .onChange(of: sandbox.isRunning) { _, running in
                    if !running { Self.redrawWindows() }
                }
        }
        Settings {
            SandboxSettingsView(controller: sandbox)
        }
    }
}
