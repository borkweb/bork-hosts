# Sandbox switch

The sandbox switch is one toggle for a specific kind of setup: you reach a development server (a "sandbox") through a SOCKS proxy, and want a hostname to resolve to the sandbox's address from `/etc/hosts` instead of being resolved by the proxy. It also points your AI coding tools' MCP servers at the same proxy, and can run a command on the sandbox. Every name in it is a setting; nothing is built in.

It is **off by default**. Until you turn it on, the app shows no panel, never runs `networksetup`, and the `bork-hosts sandbox` command refuses.

## Turn it on

Open **Settings** (Cmd-,) and turn on **Show the sandbox panel**. A Sandbox panel appears on the right of the window, with a toolbar button to show or hide it. Each setting below is also a step; a step whose setting is blank is skipped.

| Setting             | Default                    | What it is                                                                                                  |
| ------------------- | -------------------------- | ----------------------------------------------------------------------------------------------------------- |
| Main group          | `sandbox`                  | The group the switch always turns on and off. It must match a group in the window (case is ignored).        |
| API group           | `sandbox api`              | The group the **Include API group** checkbox adds. It holds the host you want to bypass the proxy for.      |
| Proxy bypass host   | blank                      | The host added to the proxy bypass list while the sandbox is on. Blank skips the step.                      |
| Network service     | blank                      | The service whose bypass list is edited, for example `Wi-Fi`. List yours with `networksetup -listallnetworkservices`. |
| MCP tools           | all three on               | Which tools' MCP config gets the proxy: Claude Code, Codex, Grok. A tool whose file is missing is skipped.   |
| MCP servers         | blank                      | The servers to point at the proxy, for example `my-server, other=SOCKS_PROXY`. See [MCP servers](#mcp-servers). Blank skips the step. |
| SOCKS proxy         | `socks5://127.0.0.1:8080`  | The proxy the MCP servers use. Must be `socks5://`, never `socks5h://`.                                     |
| ssh host            | blank                      | The sandbox to run a command on, as `user@host` or a name from `~/.ssh/config`. Blank skips the step.       |
| Command to run      | blank                      | The command run on the sandbox. Blank skips the step. Give a full path, or start it with `cd <path> &&`, because the login directory may not be where it lives. |
| Check page          | blank                      | A page fetched through the proxy to confirm the sandbox answers. Blank skips the step.                      |
| Reply must contain  | blank                      | Text the check page's reply must contain. Blank accepts any successful reply.                               |

The network step needs both a bypass host and a network service; with the host blank it is skipped, and with a host but no service it fails with "No network service is set". Create the two groups in the window first; a missing group fails the first step.

## What the switch does

Switching **on** runs these steps in order. Switching **off** runs them too, in the same order, in the opposite direction; the last two have nothing to undo and show as skipped.

| Step | Switching on                                           | Switching off                                              |
| ---- | ------------------------------------------------------ | ---------------------------------------------------------- |
| 1    | Turn the main group on                                 | Turn the main group off                                    |
| 2    | Turn the API group on                                  | Turn the API group off                                     |
| 3    | Add the host to the proxy bypass list, then flush DNS  | Remove the host from the list, then flush DNS              |
| 4    | Clear Dia's host cache                                 | Clear Dia's host cache                                     |
| 5    | Flush Dia's socket pools                               | Flush Dia's socket pools                                   |
| 6    | Add the proxy to the chosen MCP servers                | Remove the proxy from them                                 |
| 7    | Run the command on the sandbox over ssh                | Skipped                                                    |
| 8    | Fetch the check page through the proxy                 | Skipped                                                    |

Rules:

- **Include API group.** With the box cleared, switching on skips steps 2, 3, 6, 7 and 8: the API group stays as it is, the host is not bypassed (that would sandbox the host anyway), and the later steps have nothing to point at. Switching off always runs everything. The checkbox is remembered between launches.
- **Steps stop at the first failure.** The failed row shows why, the later rows stay pending, and nothing already done is rolled back. Fix the cause and run it again; switching on or off again is safe to repeat.
- **Skipped is not failed.** A Dia step is skipped when Dia is not running or was not started with scripting turned on. A step whose setting is blank is skipped. The run continues.
- **The switch shows what the file says.** It reads on when the main group is fully on (and the API group too, when it is included), read from `/etc/hosts` each time rather than remembered.
- **One authorization.** Steps 1 to 3 share the app's single macOS authorization, so you approve once, and later runs within about five minutes need no dialog.
- **A log.** Every run writes one line per step to `~/Library/Logs/BorkHosts/sandbox.log`, which is cleared when it passes 256 KB.

### What step 3 runs

The app reads the bypass list as you, then runs `networksetup -setproxybypassdomains <service> <list>` as root, reads the list again to confirm the change took, and flushes DNS with `dscacheutil -flushcache` and `killall -HUP mDNSResponder`. The service and host are validated first: blanks, control characters and a leading dash are refused. Adding is idempotent, and removing the last entry clears the list. See [Safety model](security.md).

## MCP servers

An MCP server does not use macOS's proxy settings, so to reach the sandbox through the SOCKS proxy its own environment has to carry the proxy. Step 6 does this for you in every tool you have turned on:

| Tool        | File                    | Entry                                  |
| ----------- | ----------------------- | -------------------------------------- |
| Claude Code | `~/.claude.json`        | `mcpServers.<name>.env` (top level)    |
| Codex       | `~/.codex/config.toml`  | `[mcp_servers.<name>]` (honors `CODEX_HOME`) |
| Grok        | `~/.grok/config.toml`   | `[mcp_servers.<name>]`                 |

The **MCP servers** setting is a comma-separated list. A bare name sets `HTTPS_PROXY` and `HTTP_PROXY`; `name=SOCKS_PROXY` sets only that variable; several variables join with `+`. Which variables a server reads is up to the server, so check its documentation.

- **`socks5://`, never `socks5h://`.** The first resolves names on your Mac, so `/etc/hosts` sends the host to your sandbox. The second resolves on the proxy and goes to the real server. The app refuses `socks5h`.
- **Only the `env` changes.** The rest of each file is kept as it was; the TOML files are edited as text, so comments and order survive, and switching off gives back the same bytes. Switching off removes a variable only if it still holds the proxy URL, so a value you set yourself stays. The file is copied to `~/Library/Application Support/BorkHosts/<tool>-config.before-sandbox` before it changes, and read back afterward. If a tool rewrote the file at the same moment the step says so; run the switch again.
- **A tool or server that is not there is skipped.** A missing file, or a name that is not in a tool's file, is not an error. A step that finds nothing at all shows as skipped with the reason.
- **Restart or reconnect.** A tool reads a server's environment only when it starts the server. After the step, reconnect it in a running session (`/mcp` in Claude Code) or start a new one.
- **Only user-level entries.** A server that comes from a plugin, or from a project's own config, has no entry in these files to edit. Add it yourself once as a user-level server (for Claude Code, `claude mcp add --transport stdio --scope user <name> -- <command>`) so the step has an entry to change. Grok also reads `~/.claude.json` when its Claude import is on, so those entries reach it too.
- **URL servers cannot be proxied this way.** An entry written with `url = "..."` speaks HTTP directly, and the HTTP transport does not use a SOCKS proxy. The step leaves it alone and says so on the row. To route such a server through the proxy, run it as a stdio entry through a local bridge program that reads a proxy variable from its environment, then name it in the setting.
- **Keep your proxy app's "route all traffic" mode off.** Anything that makes the proxy resolve names itself sends the host back to the real server whatever the hosts file says. The app cannot change that setting; the check in step 8 fails when it is on.

## Running a command on the sandbox

Step 7 runs your command on the sandbox with `/usr/bin/ssh`, as you. A typical use is a script that enables something a session needs, such as write access. The host is passed as one argument after `--`, so a value that looks like an option is refused. The command has 60 seconds. Leave the ssh host or the command blank to skip the step.

**Signing in.** Many hosts accept your key and then ask for a second factor (ssh reports `Permission denied (keyboard-interactive)` when it is not allowed to ask). The app never answers that itself, so the step works over a shared ssh connection:

1. If a connection to the host is already open, the command runs over it with no sign-in.
2. If not, the app tries to open one without asking anything. This is all a host needs when your key is enough.
3. If the host wants a second factor, the app opens a Terminal window that runs one `ssh` command. Answer the prompt there. The app waits up to two minutes, then runs the command. What you type goes to ssh in that window; the app never sees it.

The connection stays open for four hours (`ControlPersist`), so switching on again in that time needs no sign-in. Its socket is `~/.ssh/bork-hosts-<hash>`, which only you can use. If the window is closed or you do not finish, the step fails and tells you to switch on again. Your key must be available to ssh, for example through your `~/.ssh/config`.

## The sandbox check

Step 8 runs `curl --socks5 <proxy> <check page>` and, if **Reply must contain** is set, looks for that text in the reply. It is the same check you would run by hand. A failure usually means the proxy is not connected, a hosts group is off, the proxy app is routing all traffic, or a DNS cache still holds the old address. Leave the check page blank to skip it.

## Enabling Dia scripting

Dia has no command for clearing its caches, so the app opens `chrome://net-internals` in a new tab, clicks **Clear host cache** or **Flush socket pools**, and closes the tab. Dia only runs scripted JavaScript when it was started with a flag:

```sh
# Quit Dia first, then:
open -a Dia --args --enable-applescript-javascript
```

To start Dia this way every time, wrap that command in a small launcher app or alias and open Dia through it. Without the flag, or with Dia closed, steps 4 and 5 show **skipped** and the rest of the run is unaffected. If a button cannot be found, the step fails with `Could not find the "Clear host cache" button on the page`.

macOS may ask you to let bork-hosts control Dia the first time; allow it. The app also needs a Dia window open to hold the temporary tab, and fails with "Dia has no open window" otherwise.

## Drive it from a script or an agent

```sh
bork-hosts sandbox on            # all eight steps
bork-hosts sandbox on --no-api   # leave the API group and the bypass alone
bork-hosts sandbox off
bork-hosts sandbox status
```

`--no-api` applies to that one run and does not change the remembered checkbox. See [Agents and scripts](agents.md).
