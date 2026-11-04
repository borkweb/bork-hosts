# Contributing to bork-hosts

Thanks for helping. This guide covers how to get set up, where code belongs, and what a pull request needs before review. For installing and using the app, start with the [README](README.md).

## What belongs here

bork-hosts turns groups of `/etc/hosts` lines on and off, with an optional sandbox switch and a command for agents. Because it edits a root-owned file, most rules below are about keeping that safe.

- **Keep the hosts-file model free of UI.** Parsing, editing, writing and the sandbox steps live in `HostsCore` and are tested without a window. The SwiftUI app and the command are thin layers over it.
- **Keep the sandbox optional.** Nothing about one person's setup belongs in the core path. New sandbox behavior is a setting with a neutral default, and the app must work with the sandbox off. See [Sandbox switch](docs/sandbox.md).
- **Do not widen what agents can do.** The `bork-hosts` command and its socket protocol can read state and switch existing groups, lines and the sandbox. They cannot add, edit, rename or delete anything, and they cannot run commands. A change that adds such a command needs a design discussion first, not a pull request.

### Rules for code that runs as root

Three things run with elevated rights: the hosts-file write, the sandbox's `networksetup` call, and its DNS flush. Read the [Safety model](docs/security.md) before changing them, and keep these rules:

- Never pass a value to a root command through a shell. Pass it as its own argument, and validate it first (see `SandboxValidation`). A value that can start with a dash is a flag until proven otherwise.
- Any new value that reaches root and can be changed by something running as the user needs a test showing a bad value never starts a root command.
- Keep every hosts write confined to the `# BEGIN: bork-hosts` block, verified by the compare-and-swap script, with a backup first. Do not add a second write path.
- Never read, store or ask for a password. macOS owns the dialog. A test scans `Sources/` for credential handling and fails if it finds it; if it trips on a comment, reword the comment.
- Never put a real machine path, address or hostname in shipped files. A test scans `Sources/`, `scripts/`, `skills/` and the docs for home-directory paths and for any IP other than loopback and `192.0.2.0/24`.
- Tests must never run a real root command. Use the fake runners in `Tests/HostsCoreTests`.

## Repository layout

| Path                      | What it holds                                                                     |
| ------------------------- | --------------------------------------------------------------------------------- |
| `Sources/HostsCore`       | The hosts-file model and writers, groups, the sandbox steps, and the agent protocol and socket |
| `Sources/BorkHosts`       | The SwiftUI app: window, sidebar, sandbox panel and Settings                       |
| `Sources/BorkHostsCLI`    | The `bork-hosts` command                                                           |
| `Tests/HostsCoreTests`    | Swift Testing suites for everything above                                          |
| `scripts/`                | `build-app.sh` builds and signs the app; `make-icon.sh` regenerates the icon art   |
| `Resources/`              | The app icon source and its layered icon                                           |
| `skills/bork-hosts`       | A Claude Code skill for the command                                                |
| `docs/`                   | User and contributor docs                                                          |

## Set up

You need macOS 14 or later and a Swift 6 toolchain (Xcode 16 or later).

```sh
git clone https://github.com/borkweb/bork-hosts.git
cd bork-hosts
swift build
swift test
bash scripts/build-app.sh    # build/BorkHosts.app, with the bork-hosts command inside
```

Work on a branch, not on `main`. The package builds in Swift 5 language mode, so match the style of the surrounding code rather than adding strict-concurrency annotations everywhere.

## Checks

Run these before you open a pull request:

```sh
swift build
swift test
bash scripts/build-app.sh
```

`swift test` needs no network, no root and no Dia. It covers the hosts-file parser and editor with property tests, every write outcome through a fake writer, the sandbox controller and its steps against fake runners and a fake browser, and the agent protocol, socket and command line end to end.

One test drives a real Dia and is off by default. Quit Dia, start it with scripting on, then run it:

```sh
open -a Dia --args --enable-applescript-javascript
BORK_LIVE_DIA=1 swift test --filter liveDia
```

### UI changes

Tests do not replace looking at the change. For any UI change, build and open the app, exercise it, and say in the pull request what you checked. If you could not, say that instead of leaving it out. A past layout bug left the window blank after a failed sandbox step, and only running the app showed it.

### Judging a failing test

Compare against `main` before you blame your change. Run the same test on a clean checkout of the merge-base and note which failures were already there. A pull request should only own the failures it introduces.

## Writing tests

- A test must be able to fail. Before you trust a new test, break the code it covers and confirm that it goes red for the reason you expect.
- Test what a user or caller sees, not the shape of the implementation.
- Test the root path with a fake `PrivilegedRunning`; assert on the exact command and arguments it received.
- Anything that touches the filesystem uses a temporary folder and a unique `UserDefaults` suite, never your real data.

## Documentation

- The README covers installing and the first run. Feature behavior goes in `docs/`, one topic per file, linked from the README's [Documentation](README.md#documentation) list.
- A new setting goes in [Configuration](docs/configuration.md), with its defaults key.
- A new command or option goes in [Agents and scripts](docs/agents.md), the `bork-hosts --help` text, `AGENTS.md` and the skill.
- Keep the American English spelling used throughout.

## Commits and pull requests

- Write the subject in the imperative with a Conventional Commits type, for example `fix(core): Keep a failed step from blanking the window`. Use the body to say what changed and why, with `Summary`, `Why` and `Testing` headings for anything larger than a one-line fix.
- Keep a pull request to one change. Say what changed, why, and how you checked it.
- Do not commit `build/`, `.build/` or anything that names your machine. Stage files by explicit path instead of `git add -A`, so nothing else rides along.
- Open pull requests against `main`.

## Security issues

Please do not open a public issue for a security problem. Use GitHub's private vulnerability reporting on this repository, or contact the maintainer directly.

## License

By contributing, you agree that your contribution is licensed under the [MIT License](LICENSE).
