# Agents and scripts

The `bork-hosts` command lets a shell script, Claude Code, Codex or any other tool switch groups, lines and the sandbox on or off in the running app. It is deliberately narrow: it can turn things that already exist on or off and read their state, and nothing else.

## Install the command

`scripts/build-app.sh` puts the command inside the app bundle, so it always matches the app it talks to. Link it onto your `PATH`:

```sh
ln -sf "$PWD/build/BorkHosts.app/Contents/MacOS/bork-hosts" ~/bin/bork-hosts   # any folder on your PATH
bork-hosts --help
```

## Commands

```sh
bork-hosts status                                       # sandbox state, groups, and the last run's steps
bork-hosts groups                                       # every group, its lines, and each state
bork-hosts sandbox on|off [--no-api]                    # the sandbox switch (must be enabled in Settings)
bork-hosts sandbox status                               # same as status
bork-hosts group on|off "<group name>"                  # one group
bork-hosts line on|off <hostname> [--group "<group name>"]
```

| Option             | Effect                                                                                |
| ------------------ | ------------------------------------------------------------------------------------- |
| `--json`           | Print the app's reply as JSON                                                         |
| `--timeout <secs>` | How long to wait, including for the macOS dialog. Default 120                         |
| `--no-launch`      | Do not start the app if it is not running                                             |
| `--api`, `--no-api`| With `sandbox on`, include or skip the API group for this run                         |
| `-h`, `--help`     | Show the usage text                                                                   |

- Group names are matched ignoring case. A name with spaces needs quotes.
- A hostname that appears in more than one group needs `--group`, otherwise the command says so and changes nothing.
- Every change is read back from `/etc/hosts` before the command reports success.

## What an agent cannot do

There is no command to add, edit, rename or delete a group or a line. This is by design, and it is enforced in the app, not only in the command: the request protocol has no such operations, and an unknown request is refused with "cannot add, edit or delete them" and changes nothing. An agent also cannot run arbitrary commands as root; the only privileged work is the app's own fixed hosts-file write and the sandbox's `networksetup` and DNS flush. Ask the user to make those edits in the app.

## Authentication

The first change asks the user to approve the standard macOS dialog, in the app. After that, changes within about five minutes need no dialog. An agent should not try to work around it: if a command waits or exits 4, tell the user to approve the dialog and run it again.

Because the dialog belongs to the app, the command works the same whether you run it yourself or an agent does. There is no way to supply a password to the command, and the code never reads or stores one.

## Output

By default the command prints a short readable summary:

```text
Sandbox: on
  [ok]      sandbox group
  [ok]      sandbox api group
  [ok]      Proxy bypass & DNS
  [skipped] Dia: host cache (Launch Dia with --enable-applescript-javascript to let the app click this button)
  [skipped] Dia: socket pools (Launch Dia with --enable-applescript-javascript to let the app click this button)
```

With `--json` it prints the reply as one JSON object:

```json
{
  "ok": true,
  "message": "Group “staging” turned on.",
  "sandbox": { "on": false, "running": false, "includeAPI": true },
  "groups": [
    {
      "name": "staging",
      "state": "on",
      "lines": [
        { "host": "example.com", "ip": "192.0.2.10", "state": "on" }
      ]
    }
  ]
}
```

| Field      | Values                                                                                          |
| ---------- | ----------------------------------------------------------------------------------------------- |
| `ok`       | `true` when the request was carried out                                                         |
| `message`  | A sentence about the result, or the reason for a failure                                        |
| `state`    | For a group `on`, `off` or `mixed`; for a line `on`, `off` or `missing` (not in the block)      |
| `steps`    | After a sandbox run: `name`, `status` (`pending`, `running`, `done`, `skipped`, `failed`) and `detail` |

## Exit codes

| Code | Meaning                                                              |
| ---- | -------------------------------------------------------------------- |
| 0    | Done                                                                 |
| 1    | The app reported a failure. Read the message                         |
| 2    | Bad usage, such as an unknown command or a missing group name        |
| 3    | The app could not be reached (and `--no-launch` was set, or it would not start) |
| 4    | Timed out, usually because the macOS dialog was not approved         |

## How it works and who can use it

The command writes one JSON request to a Unix domain socket at `~/Library/Application Support/BorkHosts/agent.sock` and reads one JSON reply. The app listens only while it is running; if it is not, the command opens it and waits up to 30 seconds for the socket.

- The folder is mode 0700 and the socket is mode 0600, and the app checks the user ID of each connection, so other users on the Mac cannot use it.
- **Any process running as you can.** While the five-minute authorization is open, a request from your own user changes the file with no dialog. If you do not want that, do not run untrusted code as your user while the app is open.
- Requests are limited to 16 KB and must arrive within 5 seconds. A malformed request gets an error and changes nothing.

More on what is and is not protected: [Safety model](security.md).

## For agent authors

[`AGENTS.md`](../AGENTS.md) at the repository root describes the command for coding agents working in this repository, and [`skills/bork-hosts/SKILL.md`](../skills/bork-hosts/SKILL.md) is a ready-made Claude Code skill. To install the skill for your own use, link the folder into your skills directory, for example `ln -s "$PWD/skills/bork-hosts" ~/.claude/skills/bork-hosts`.
