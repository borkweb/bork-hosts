import HostsCore
import SwiftUI

/// Settings (Cmd-,): turns the sandbox panel on and says which groups, host and network service it acts on.
struct SandboxSettingsView: View {
    @Bindable var controller: SandboxController

    var body: some View {
        Form {
            Section {
                Toggle("Show the sandbox panel", isOn: $controller.preferences.enabled)
                Text("One switch that turns two groups on or off, adds a host to the proxy bypass list, flushes DNS, clears Dia's caches, and can point MCP servers at the sandbox. Agents can use it through the bork-hosts command only while this is on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("What it acts on") {
                TextField("Main group", text: $controller.preferences.mainGroup, prompt: Text(SandboxPreferences.defaultMainGroup))
                TextField("API group", text: $controller.preferences.apiGroup, prompt: Text(SandboxPreferences.defaultAPIGroup))
                TextField("Proxy bypass host", text: $controller.preferences.bypassHost, prompt: Text("api.example.com"))
                TextField("Network service", text: $controller.preferences.networkService, prompt: Text("Wi-Fi"))
                Text("Group names must match a group in the window. The proxy bypass step needs a host and a network service (list yours with networksetup -listallnetworkservices); with the host empty it is skipped.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!controller.preferences.enabled)
            Section("MCP servers") {
                Toggle("Claude Code (~/.claude.json)", isOn: $controller.preferences.mcpClaude)
                Toggle("Codex (~/.codex/config.toml)", isOn: $controller.preferences.mcpCodex)
                Toggle("Grok (~/.grok/config.toml)", isOn: $controller.preferences.mcpGrok)
                TextField("Servers to proxy", text: $controller.preferences.mcpServers, prompt: Text("my-server, other-server=SOCKS_PROXY"))
                TextField("SOCKS proxy", text: $controller.preferences.proxyURL, prompt: Text(SandboxPreferences.defaultProxyURL))
                Text("While the sandbox is on, these servers in each tool's config file get the proxy in their env, and it is removed when you turn the sandbox off. A tool whose file is missing is skipped; a server that uses a URL cannot take a proxy variable and is reported. A name alone sets HTTPS_PROXY and HTTP_PROXY; name=SOCKS_PROXY sets only that variable. Leave the list empty to skip this. The proxy must be socks5://, never socks5h://. Running sessions need to restart or reconnect the server.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!controller.preferences.enabled)
            Section("On the sandbox") {
                TextField("ssh host", text: $controller.preferences.sshHost, prompt: Text("user@host, or a name from ~/.ssh/config"))
                TextField("Command to run", text: $controller.preferences.remoteCommand, prompt: Text("/path/to/script"))
                TextField("Check page", text: $controller.preferences.verifyURL, prompt: Text("https://example.com/check"))
                TextField("Reply must contain", text: $controller.preferences.verifyExpected, prompt: Text("any successful reply"))
                Text("Switching on runs the command over ssh as you, then fetches the check page through the proxy. If the sandbox asks for a second factor, a Terminal window opens so you can sign in once; the connection then stays open for four hours. Leave the ssh host or the command empty to skip the first, the check page empty to skip the second. If your login lands outside the directory the command expects, give its full path or start it with cd and the path.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!controller.preferences.enabled)
            Section("Backup") {
                HStack {
                    Button("Export Settings\u{2026}") { SettingsTransfer.export(controller) }
                    Button("Import Settings\u{2026}") { SettingsTransfer.importFile(controller) }
                        .disabled(controller.isRunning)
                }
                Text("Saves the settings above to a file, or loads them from one, for example on a new Mac. The file includes your ssh host and command, so share it only with people you trust. An import shows what will change and asks first. The setting that shows the panel is not included.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // The form scrolls inside a window that fits on a laptop screen, however many sections it grows.
        .frame(width: 520, height: 680)
    }
}
