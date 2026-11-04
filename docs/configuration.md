# Configuration

bork-hosts has no config file to edit and no environment variables to set for normal use. Preferences live in the **Settings** window (Cmd-,), which saves them to macOS user defaults, and your data lives in two folders under your home directory.

## Settings

Everything here belongs to the [sandbox switch](sandbox.md). The groups, lines and the rest of the window need no setup.

| Setting                 | Defaults key             | Default                    | Purpose                                                                  |
| ----------------------- | ------------------------ | -------------------------- | ------------------------------------------------------------------------ |
| Show the sandbox panel  | `sandbox.enabled`        | off                        | Shows the panel and toolbar button, and allows `bork-hosts sandbox`.     |
| Main group              | `sandbox.mainGroup`      | `sandbox`                  | The group the switch always turns on and off.                            |
| API group               | `sandbox.apiGroup`       | `sandbox api`              | The group the **Include API group** checkbox adds.                       |
| Proxy bypass host       | `sandbox.bypassHost`     | blank                      | The host added to the proxy bypass list while the sandbox is on. Blank skips the step. |
| Network service         | `sandbox.networkService` | blank                      | The service whose bypass list is edited, such as `Wi-Fi`.                |
| Include API group       | `sandbox.includeAPI`     | on                         | Whether switching on also turns on the API group and sets the bypass.    |
| MCP tools               | `sandbox.mcpClaude`, `sandbox.mcpCodex`, `sandbox.mcpGrok` | on | Which tools' MCP config gets the proxy.                    |
| MCP servers             | `sandbox.mcpServers`     | blank                      | Servers to point at the proxy. Blank skips the step.                     |
| SOCKS proxy             | `sandbox.proxyURL`       | `socks5://127.0.0.1:8080`  | Must be `socks5://`.                                                     |
| ssh host                | `sandbox.sshHost`        | blank                      | Where to run the command. Blank skips the step.                          |
| Command to run          | `sandbox.remoteCommand`  | blank                      | The command run on the sandbox over ssh. Blank skips the step.           |
| Check page              | `sandbox.verifyURL`      | blank                      | Fetched through the proxy. Blank skips the step.                         |
| Reply must contain      | `sandbox.verifyExpected` | blank                      | Text the check page's reply must contain. Blank accepts any successful reply. |

A blank or whitespace-only text value falls back to its default (for most settings, blank). The bundle identifier is `com.borkweb.bork-hosts`, so you can read or change a value from a terminal:

```sh
defaults read com.borkweb.bork-hosts sandbox.enabled
defaults write com.borkweb.bork-hosts sandbox.enabled -bool true
```

The app reads these when it starts and saves them as you change them in Settings, so quit and reopen the app after a change made with `defaults`.

## Export and import settings

**Settings** (Cmd-,) has a **Backup** section with **Export Settings…** and **Import Settings…**. Use them to move your sandbox settings to another Mac or keep a copy.

- **Export** writes a JSON file (`bork-hosts-settings.json`, mode 0600) with the settings in the table above, except the one that shows the panel. It does not include your groups and lines, which live in `~/Library/Application Support/BorkHosts/groups.json`.
- **Import** reads a file, checks every value, and shows what would change before it applies anything. Fields missing from the file keep their current value, and unknown fields are ignored. The setting that shows the panel is never changed by an import, so turning the feature on stays your choice on each Mac.
- **A file with a value the app would not accept is refused as a whole**, and the message names the field: for example a `socks5h://` proxy, an ssh host that starts with a dash, or a command with a line break. Nothing is half applied.
- **Only import a file you trust.** The ssh host, the command, the MCP servers and the check page take effect the next time you switch the sandbox on, so the confirmation says so when any of them change.
- **Agents and scripts cannot import or export.** The `bork-hosts` command has no such request; the buttons are in the app only.

The file looks like this:

```json
{
  "sandbox" : {
    "apiGroup" : "sandbox api",
    "mainGroup" : "sandbox",
    "mcpServers" : "my-server",
    "sshHost" : "user@host"
  },
  "version" : 1
}
```

## Files

| Path                                                    | What it holds                                                                  |
| ------------------------------------------------------- | ------------------------------------------------------------------------------ |
| `/etc/hosts`                                            | The file the app edits, between `# BEGIN: bork-hosts` and `# END: bork-hosts`  |
| `~/Library/Application Support/BorkHosts/groups.json`   | Your groups and lines                                                          |
| `~/Library/Application Support/BorkHosts/backups/`      | `hosts-YYYYMMDD-HHMMSS-mmm` copies of `/etc/hosts`, the newest 20, one per write |
| `~/Library/Application Support/BorkHosts/agent.sock`    | The socket the `bork-hosts` command talks to (mode 0600, folder 0700)          |
| `~/Library/Logs/BorkHosts/sandbox.log`                  | One line per sandbox step. Cleared when it passes 256 KB                       |
| `~/Library/Application Support/BorkHosts/<tool>-config.before-sandbox` | The last copy of a tool's MCP config (`claude`, `codex`, `grok`) from before the sandbox changed it |
| `~/.claude.json`, `~/.codex/config.toml`, `~/.grok/config.toml` | Edited only in the `env` of the MCP servers you name, while the sandbox is on. See [MCP servers](sandbox.md#mcp-servers) |

The app also creates a short-lived file in the system temporary folder for each hosts write, mode 0600 with an unpredictable name, and removes it when the write ends.

## Environment variables

| Variable          | Used by            | Purpose                                                                  |
| ----------------- | ------------------ | ------------------------------------------------------------------------ |
| `CODEX_HOME`      | the app            | Moves the Codex config file the MCP step edits from `~/.codex`.          |
| `BORK_LIVE_DIA`   | `swift test`       | Set to `1` to run the live test that drives a real Dia. Off by default.  |

## Command-line options

The `bork-hosts` command takes `--json`, `--timeout <secs>` (default 120), `--no-launch`, and `--api` or `--no-api` for the sandbox. They are listed in [Agents and scripts](agents.md#commands).

## Ports

There are none. The command and the app talk over a Unix socket on disk, and nothing listens on the network.
