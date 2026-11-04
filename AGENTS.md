# bork-hosts agent guidance

A macOS app (SwiftUI, Swift Package) that turns groups of `/etc/hosts` lines on or off and, optionally, runs a sandbox switch. See [README.md](README.md) and [CONTRIBUTING.md](CONTRIBUTING.md).

## Controlling the running app

Use the `bork-hosts` command (built at `build/BorkHosts.app/Contents/MacOS/bork-hosts`, usually linked onto `PATH`). It sends requests to the running app, which does the work.

```sh
bork-hosts status
bork-hosts groups
bork-hosts sandbox on [--no-api]
bork-hosts sandbox off
bork-hosts group on|off "<group name>"
bork-hosts line on|off <hostname> [--group "<group name>"]
```

- Add `--json` for machine-readable output. Exit codes: 0 done, 1 the app reported a failure, 2 bad usage, 3 app unreachable, 4 timed out.
- The first change asks the user to approve a macOS dialog; later changes in about 5 minutes need none. If it times out, ask the user to approve the dialog and retry. Never try to work around it.
- `sandbox on|off` works only after the user turns the sandbox on in the app's Settings; until then it reports "turned off". Ask the user to enable it.
- Agents cannot add, edit, rename or delete groups and lines. That is deliberate. Ask the user to do it in the app.
- Full reference: [docs/agents.md](docs/agents.md) and `bork-hosts --help`. A Claude Code skill with the same guidance is in [skills/bork-hosts/SKILL.md](skills/bork-hosts/SKILL.md).

## Rules for working on this repository

- Keep the hosts-file model, writers and sandbox steps in `HostsCore`, free of UI, so they are testable without a window.
- Never widen the agent protocol. It has no command to add, edit, delete or run anything; do not add one. The test `theCommandListHasNoWayToAddEditOrDelete` pins this.
- Anything that runs as root has one write path: the confined, compare-and-swap hosts write, and the sandbox's `networksetup` and DNS flush. Never pass a value to a root command through a shell; pass it as its own argument and validate it first (`SandboxValidation`). See [docs/security.md](docs/security.md).
- Never read, store or mention handling a password in `Sources/`. A test rejects it; if it trips on a comment, reword the comment.
- Never put a real home-directory path or IP address in shipped files. A test allows only loopback and `192.0.2.0/24`.
- Keep the sandbox optional and its names configurable. The app must work with it off.
- Tests never run a real root command. Use the fake runners in `Tests/HostsCoreTests`.

## Building and testing

- `swift test` runs the suite. `BORK_LIVE_DIA=1 swift test --filter liveDia` also drives a real Dia (started with `--enable-applescript-javascript`).
- `bash scripts/build-app.sh` builds `build/BorkHosts.app`, including the `bork-hosts` command.
- For any UI change, build and open the app and look at it; passing tests are not enough.
