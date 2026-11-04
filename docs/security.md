# Safety model

bork-hosts changes a file owned by root, and one optional feature changes your network settings. This page says exactly what runs with elevated rights, how each change is checked, and what the design does not protect against.

## What runs as root

Only three things, all started by the app after you approve the standard macOS authorization dialog (administrator password or Touch ID):

1. **The hosts-file write**: a fixed shell script that replaces `/etc/hosts`.
2. **The sandbox's `networksetup -setproxybypassdomains` call**, only if you turned the sandbox on.
3. **The sandbox's DNS flush**: `dscacheutil -flushcache` and `killall -HUP mDNSResponder`.

The app asks for rights with `AuthorizationExecuteWithPrivileges`, which Apple has deprecated but which still works and is the one API that keeps the dialog and the five-minute window in the app. It is looked up at run time. There is no helper daemon, no setuid binary, and nothing is installed with elevated permissions. The code never reads, stores or handles a password; the dialog belongs to macOS.

The hosts write and the sandbox share one authorization, so one approval covers both. The sandbox's commands run through a small Perl launcher that raises the real user ID to root (the privileged launcher sets only the effective one, and `sh` and some system tools distrust that), clears the environment variables that change how programs start, and then runs the command with fixed arguments.

## How a hosts-file write is checked

1. **Fresh read and validation.** The app reads `/etc/hosts` again, applies your change in memory, and refuses if the file is not valid text, has no enabled `localhost` line, or has damaged `bork-hosts` markers.
2. **Confinement.** The result is compared with the original: if any line outside the managed block would change, nothing is written.
3. **Backup.** The current file is copied to the backups folder. If that fails, nothing is written.
4. **A private content file.** The new content goes to a temporary file created with mode 0600, an unpredictable name, and `O_EXCL | O_NOFOLLOW`, so it cannot be replaced or redirected by another user.
5. **The root script** copies that file next to `/etc/hosts` and verifies the copy, not the original, so it cannot be swapped after the check. It checks the copy's SHA-256 against the expected one, and that `/etc/hosts` still has the exact content the app last read (a compare-and-swap). It then gives the copy the target's mode and owner, syncs, and renames it into place in one atomic step.
6. **Stale file.** If the file changed since it was read, the script refuses, and the app reads again and retries once.
7. **Read-back.** The app rereads the file to confirm the change landed.

## What runs as you, outside root

The three sandbox steps after the Dia ones never use root or the authorization dialog:

- **MCP config.** The app edits `~/.claude.json`, `~/.codex/config.toml` and `~/.grok/config.toml` as you, changing only the `env` of the servers named in Settings. It copies the file aside first, writes it in one step, and reads it back. The proxy URL is validated before it is written: it must be `socks5://host:port` with a plain host, so it needs no escaping in JSON or TOML, and `socks5h://` is refused.
- **ssh.** The app runs `/usr/bin/ssh` as you with your own keys and agent. Its own ssh calls never ask a question (`BatchMode=yes`) and stop after at most 60 seconds. When the sandbox wants a second factor, the app opens a Terminal window that runs the one signing-in `ssh` command, so you answer in ssh itself; the app never reads or stores what you type. That script is written to a private folder (mode 0700), quotes its values for the shell, and deletes itself. The signed-in connection is shared through a socket in `~/.ssh` for four hours, usable only by your user: while it is open, a process running as you can run commands on the sandbox through it without signing in again. The host is one argument after `--`, validated to refuse blanks, control characters and a leading dash. The command goes to the remote shell, like any ssh command you type, so it runs with your rights on the sandbox only.
- **The check.** `curl` fetches one page through the local proxy.

These settings, like the others, can be changed by any process running as you; see below. The agent socket still cannot change settings, add a command, or run one: `bork-hosts sandbox on` only runs these steps with what is already saved.

## Importing settings

Importing a settings file is the one way settings arrive from outside the app, and some of them cause actions later: an ssh host and command that run on switch-on, and MCP servers whose config files are edited. So an import is checked before anything is applied. Each value goes through the same rules as one typed into Settings (no leading dash, no control characters, `socks5://` only, a plain `http` or `https` check page, a size limit on the file and on each field), and one bad value refuses the whole file. The app then lists the changes and asks you to confirm, and says so when a change takes effect on switch-on. The panel's on/off choice is never imported, so a file cannot turn the feature on. The agent socket has no import or export request.

## Values that reach root

The sandbox's network service name and bypass host come from Settings, which any process running as you could change. They are passed as single arguments, never through a shell, and are validated before use: blanks, control characters and a leading dash are refused (a host also cannot contain whitespace). The service name is first read as you with `networksetup -getproxybypassdomains`, which fails for a name that is not a real service, before anything privileged runs.

## The agent socket

See [Agents and scripts](agents.md#how-it-works-and-who-can-use-it). In short:

- The socket is mode 0600 in a 0700 folder, and each connection's user ID is checked, so other users cannot use it.
- The protocol cannot add, edit or delete groups and lines, and it has no way to run a command.
- A request can only switch groups or lines that already exist, or run the sandbox steps with the settings already saved.

## What this does not protect against

- **Anything running as you, while the authorization is open.** A process with your user ID can send the socket a request to turn an existing group or line on or off, and during the five-minute window macOS shows no dialog for it. It cannot create a line that is not already in your groups, but it can switch on a line you added earlier, or change Settings, which affects the sandbox's host and network service. Do not run untrusted code as your user alongside the app.
- **A compromised administrator account, or a tampered app bundle.** The app is signed ad hoc, so macOS cannot tell it from a modified copy. Build it yourself from source you have read.
- **Another tool editing `/etc/hosts` at the same moment.** The compare-and-swap prevents a lost update, but the other tool's change makes your write fail and retry once.
- **Settings that name a command.** The ssh host and command come from Settings, which any process running as you can change, so such a process could make the next switch-on run its command on the host it names. That is no more than it could do by running `ssh` itself, but it is another reason not to run untrusted code as your user.
- **Anything outside `/etc/hosts`, the proxy bypass list, the MCP `env` entries and the ssh command.** The app does not change DNS servers, firewall rules or any other network setting.

## Reporting a problem

If you find a security problem, please do not open a public issue. Use GitHub's private vulnerability reporting on the repository's Security tab, or contact the maintainer directly through their GitHub profile.
