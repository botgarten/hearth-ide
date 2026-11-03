# Hearth IDE

A native macOS app (SwiftUI) for AI coding agents that run in a sandbox.
Hearth gathers every running agent in one inbox, shows each agent as a terminal
in the chat area and adds an inspector with directory, Git, editor, tests,
architecture (Mermaid), Build & Deployment and CI/CD (GitLab pipelines and
GitHub Actions).

Website: <https://pvanissem.github.io/hearth-ide/> · Deutsch: <https://pvanissem.github.io/hearth-ide/de/>

## Agents in the sandbox

With **+ Start agent** you pick a folder and an agent: Claude Code, Codex,
GitHub Copilot CLI, OpenCode, Gemini CLI or a sandbox shell. Hearth starts it in
a bundled [nono](https://nono.sh) sandbox (macOS Seatbelt):

- Writing only in the chosen folder and in Hearth’s own settings folder for the
  agent (`~/Library/Application Support/Hearth/agents/<agent>`). Your
  `CLAUDE.md`, skills, agents and commands are linked read-only, your settings
  are copied once. An agent therefore can’t write anything into your real
  `~/.claude` & co. that would run outside Hearth.
- `.git/hooks` in the project is write-protected
- Blocked: SSH keys, shell configuration, browser data, the rest of your home folder
- Network only to LLM APIs, package registries, GitHub/GitLab, documentation and
  the agent’s own API hosts
- Claude Code, Codex and Copilot may use the keychain (their login lives there)

Every agent uses its own login (Claude plan, ChatGPT, GitHub …). “Sign in…”
(Settings › Agents) runs the agent’s login command in the sandbox. Because
Claude Code, Codex and OpenCode get their own settings folder in Hearth, you sign
in there once separately.

The chat area shows the agent as a terminal. The inbox knows its status: Claude
Code reports it through hooks (running, waiting for approval, done), Codex
through `notify`, other agents through input and the terminal bell. Sessions
keep running when you switch; finished Claude/Codex/OpenCode sessions can be
resumed. Each session’s profile, log and status events live in
`~/Library/Application Support/Hearth/runs/<id>/`.

**Settings** (⌘,): General (language, appearance, terminal), Agents (installed?,
sign in, keychain), Sandbox (extra domains, ports, folders, SSH for the Git area,
profile preview), Projects (more folders for sessions in one project folder) and
Credentials (API keys/tokens in the keychain – through the nono proxy, so the
sandbox only sees a placeholder, or as an environment variable). Stored in
`~/Library/Application Support/Hearth/settings.json`, never in a repository;
applies to agents, Build & Deployment and Git.

**Language:** English by default; German under Settings › General › Language.

**Themes:** macOS light/dark, Hearth Light, Darcula and Storm (Settings › General ›
Theme); the own themes also colour the editor, the syntax and the terminals.

**Search Everywhere:** press Shift twice, like in IntelliJ IDEA. Searches files,
symbols, text, the agents' chats, sessions, tests and actions; Tab switches the
category. ⇧⌘O goes to a file, ⇧⌘F searches text, ⇧⌘A finds an action. Text hits
open the file with the term marked.

**Editor:** [Monaco](https://github.com/microsoft/monaco-editor), the editor of VS Code,
in the Preview pane – offline, from the app bundle. Syntax colouring, folding, multiple
cursors, find/replace, JavaScript and TypeScript also get completion and hover
(single file). Go, Java, Python, Rust, Kotlin, Swift, C#, C/C++, Ruby, PHP, shell, SQL, YAML, XML,
HTML/CSS, Markdown and more are tokenized (no language servers). ⌘-click or F12 jumps to a
definition, ⌘[ / ⌘] go back and forward, ⌘S saves. Unstaged Git changes show as bars and tinted lines.

**Find Usages:** right-click a name in the editor (or ⌥F7), or a file or folder in the directory,
▸ *Find Usages*. The list below the editor shows where it is used (file and line) and who uses it
(the class and function around it), grouped by file, with definitions, code, imports and comments
filterable. It searches the workspace – including unsaved edits – in the same language by default
(switchable to all files). There is no compiler behind it: hits are whole-word matches, so a
different class with the same name also shows up.

> **Status:** next up is a native chat over ACP (Agent Client Protocol).
> Details: [PLAN.md](PLAN.md), structure: [architecture](docs/architecture.md).

## Requirements

- macOS 14+ on Apple Silicon
- at least one agent CLI on the PATH of your login shell

## Installation

```bash
curl -fsSL https://github.com/pvanissem/hearth-ide/releases/latest/download/install.sh | bash
```

Downloads the latest version from GitHub Releases, verifies its SHA-256
checksum, installs `Hearth IDE.app` into `/Applications` (or `~/Applications`
without write access) and starts it. Run it again to update, or update from
inside the app under Settings › Updates.

The app is ad-hoc signed and not notarized by Apple.

## Build & run

```bash
swift run                       # development
scripts/bundle.sh               # builds "build/Hearth IDE.app"
open "build/Hearth IDE.app"
scripts/test.sh                 # all tests (swift test), also without Xcode
scripts/check-localization.sh   # texts without a German translation
```

With only the Command Line Tools (no Xcode):
- `@State` is written as an explicit `State(...)` property, because the SwiftUI
  macro plugin only ships with Xcode.
- `scripts/test.sh` runs `swift test` with the Command Line Tools’ testing
  framework; with Xcode, plain `swift test` works.
- The live sandbox tests need nono in `Vendor/` (`scripts/fetch-nono.sh`).

Every push and pull request runs through GitHub Actions
(`.github/workflows/ci.yml`): build, all tests including a real nono sandbox,
the German translation check and the app bundle as a download artifact. A
version tag publishes the release.

**Translations:** texts in the code are English. German lives in
`Resources/de.lproj/Localizable.strings`; its keys are the English texts as the
Swift compiler sees them (`%@`, `%lld` for interpolations).
`scripts/check-localization.sh` lists every text without a German entry.

`scripts/bundle.sh` downloads nono (pinned version, SHA-256 verified) via
`scripts/fetch-nono.sh` into `Vendor/` and puts it into `Contents/Helpers/nono`.
`swift run` finds it there as well; override with `HEARTH_NONO_BIN`.

Developer aids (environment variables at launch):

| Variable | Effect |
|---|---|
| `HEARTH_AUTOSTART_AGENT=claude` + `HEARTH_AUTOSTART_DIR=<folder>` | starts an agent right away |
| `HEARTH_AUTOSTART_PROMPT=<text>` | confirms the folder question and types the prompt |
| `HEARTH_SHOW_START_SHEET=1` | opens the start dialog |
| `HEARTH_WINDOW_SNAPSHOT=<file.png>` | writes an image of the window every 3 s (no screen-recording permission needed) |
| `HEARTH_SUPPORT_DIR=<folder>` | separate data folder for a development instance |

```bash
open -n --env HEARTH_AUTOSTART_AGENT=shell --env HEARTH_AUTOSTART_DIR=$HOME/IdeaProjects/demo "build/Hearth IDE.app"
```

App icon: artwork in `Resources/AppIcon-source.png` (full bleed, 1024 × 1024);
`scripts/make-icon.swift` crops it to the macOS shape and builds `AppIcon.icns`.

## Cutting a release

On an Apple Silicon Mac, on an up-to-date `main`, with the GitHub CLI signed in:

```bash
scripts/release.sh v0.4.0
```

Checks the working tree, runs the tests, turns the “Unveröffentlicht”
(unreleased) section of [`CHANGELOG.md`](CHANGELOG.md) into the new version’s
entry (committed to `main`) and pushes it together with the tag. GitHub Actions
then builds the bundle, tests again and creates the GitHub release with the zip,
its checksum, `latest-version.txt`, `CHANGELOG.md` and `install.sh`. New changes
go under a fresh `## Unveröffentlicht` heading; without one, the notes come from
the commits. The app updater and `install.sh` read from
`releases/latest/download/…`.

## More documentation (German)

- [Security](docs/security-hardening.md): CI token approval, terminal/Mermaid protection, Git policy, tests
- [Build & Deployment](docs/build-and-deployment.md)
- [App updates](docs/app-updates.md)
- [Architecture](docs/architecture.md)
- [Security and architecture review](docs/review-security-architecture.md)
- [Code and project review](docs/review-code-project.md)

## License

[MIT](LICENSE)
