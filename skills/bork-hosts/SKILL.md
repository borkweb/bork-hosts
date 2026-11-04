---
name: bork-hosts
description: Use when asked to turn the sandbox (a development server reached through a SOCKS proxy) on or off, to enable or disable a host group or a single hosts-file line in the bork-hosts app, or to check what is currently enabled. Drives the running bork-hosts macOS app through its `bork-hosts` command.
---

# bork-hosts

`bork-hosts` is a command that controls the running bork-hosts app. The app edits `/etc/hosts`, sets the proxy bypass, and clears Dia's caches. This command only sends it requests.

## Commands

```sh
bork-hosts status                         # sandbox state, groups, and the last run's steps
bork-hosts groups                         # every group, its lines, and each state
bork-hosts sandbox on [--no-api]          # sandbox on
bork-hosts sandbox off                    # sandbox off (always does everything)
bork-hosts group on|off "<group name>"    # one group, for example "sandbox"
bork-hosts line on|off <hostname> [--group "<group name>"]
```

Add `--json` to parse the reply. `--no-api` leaves the API group and the proxy bypass alone when switching on. Run `bork-hosts groups` to see the real group names; the sandbox's two groups and its host are chosen in the app's Settings (the default group names are "sandbox" and "sandbox api"; the host is blank until set).

## What to know

- **Sandbox switch must be enabled:** `sandbox on|off` fails with "turned off" until the user turns it on in the app's Settings (Cmd-,). Tell the user; do not try to change it.
- **Authentication:** the first change asks the user to approve a macOS dialog; after that, changes in the next ~5 minutes need no prompt. If a command waits or exits 4 (timed out), tell the user to approve the dialog, then retry. Do not try to work around it.
- **Not available:** adding, editing, renaming and deleting groups or lines. Do not try; ask the user to do it in the app.
- **The app starts itself** if it is not running (use `--no-launch` to prevent that).
- **Exit codes:** 0 done, 1 the app reported a failure (read the message), 2 bad usage, 3 the app could not be reached, 4 timed out.
- **MCP, ssh and check steps** show `[skipped]` when the user has not set them up (no MCP servers in the config files, no ssh host, no check page). After `sandbox on`, a running Claude Code, Codex or Grok session must restart or reconnect an MCP server before it uses the sandbox; tell the user. A `[FAILED]` ssh step usually means the proxy that supplies the user's key is not connected.
- **Dia steps** show `[skipped]` unless Dia was started with `--enable-applescript-javascript`. That is expected, not a failure.
- **Verify** after switching on: `bork-hosts status` should say `Sandbox: on`. The sandbox's own web server can still be down; that is separate from this tool.
- Group names are matched ignoring case. A hostname that is in more than one group needs `--group`.
