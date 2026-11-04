import HostsCore
import SwiftUI

struct ContentView: View {
    enum Mode { case file, add }

    let model: AppModel
    let sandbox: SandboxController
    @State private var mode: Mode = .file
    @State private var showSandbox = true

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model, onAddGroup: { mode = .add })
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 420)
        } detail: {
            VStack(spacing: 0) {
                if let message = model.errorMessage {
                    Banner(text: message, systemImage: "exclamationmark.triangle.fill", tint: .red, dismiss: model.dismissError)
                }
                if let notice = model.notice {
                    Banner(text: notice, systemImage: "info.circle.fill", tint: .blue, dismiss: model.dismissNotice)
                }
                switch mode {
                case .file: FilePaneView(model: model)
                case .add: AddGroupView(model: model, onDone: { mode = .file })
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // The panel exists only when the sandbox is turned on in Settings.
        .inspector(isPresented: Binding(get: { showSandbox && sandbox.preferences.enabled }, set: { showSandbox = $0 })) {
            SandboxPanelView(controller: sandbox)
                .inspectorColumnWidth(min: 230, ideal: 260, max: 340)
        }
        .toolbar {
            ToolbarItem {
                if sandbox.preferences.enabled {
                    Button { showSandbox.toggle() } label: { Label("Sandbox", systemImage: "sidebar.trailing") }
                        .help("Show or hide the Sandbox panel")
                }
            }
        }
        .navigationTitle("bork-hosts")
    }
}

private struct Banner: View {
    let text: String
    let systemImage: String
    let tint: Color
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: systemImage).foregroundStyle(tint)
            Text(text).textSelection(.enabled)
            Spacer()
            Button("Dismiss", action: dismiss).buttonStyle(.link)
        }
        .padding(10)
        .background(tint.opacity(0.12))
        .accessibilityElement(children: .combine)
    }
}
