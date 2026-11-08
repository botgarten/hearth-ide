# Product

<!-- impeccable:product-schema 1 -->

## Platform

web (landing page on GitHub Pages; the product itself is a native macOS app)

## Stack

Static HTML/CSS in `site/`, no build step, deployed to GitHub Pages by a GitHub Actions workflow.

## Users

Developers who already use agent CLIs (Claude Code, Codex, GitHub Copilot CLI, OpenCode, Gemini CLI) on a Mac and do not want to hand an agent their whole machine: SSH keys, shell configuration, browser data, the rest of the home folder and arbitrary network access.

## Product Purpose

Hearth IDE is a native macOS app (SwiftUI) that runs any agent CLI inside a nono sandbox (Seatbelt), with one inbox for all sessions and an inspector around them (directory, Git, editor, preview, tests, architecture/Mermaid, Build & Deployment, CI pipelines). Success: a developer installs it in one command, starts their usual agent in a project folder and works as before, but the agent can only write in that folder and only reach known developer hosts.

## Positioning

Agent-agnostic and sandbox-first: Hearth does not ship its own model or agent; it hosts the CLIs developers already pay for, each with its own login (e.g. Claude Code keeps using the user's Claude subscription), and confines all of them with the same kernel-level sandbox. Build & Deployment and Git actions run in the sandbox too, never directly on the Mac.

## Operating Context

- Install: `curl -fsSL https://github.com/botgarten/hearth-ide/releases/latest/download/install.sh | bash` (SHA-256 verified, installs to /Applications, updates from inside the app).
- Start: pick a folder and an agent; the agent runs as a terminal in the chat area; the inbox shows running / needs input / done (Claude Code via hooks, Codex via notify).
- Settings: extra domains, ports, folders, per-project folders, credentials in the keychain (nono proxy injection so the sandbox only sees a placeholder token).

## Capabilities and Constraints

- Version 0.4, early: terminal chat today; native chat over ACP (Agent Client Protocol) is the next step.
- macOS 14+, Apple Silicon only. Ad-hoc signed, not notarized (browser downloads need "Open anyway"; the curl installer does not).
- Bundles nono v0.80.0 (Apache-2.0). App licensed MIT.
- Network allowlist: LLM APIs, package registries, GitHub/GitLab, documentation, plus the agent's own API hosts and user additions.

## Brand Commitments

- Name: "Hearth IDE" (short: Hearth). A hearth: a protected place where you work with fire.
- App icon: `Resources/AppIcon-1024.png` (flames in orange/red/purple on dark, a dark key with glowing "HI").
- Landing page languages: English at `/` (default), German at `/de/`; both share `assets/site.css` and `assets/site.js` (texts for the script per `<html lang>`).

## Evidence on Hand

- Real app screenshots can be produced with the snapshot developer aids (README). No testimonials, user numbers, benchmarks or press exist; do not invent them.
- Verified behaviour (tested): sandbox blocks ~/.ssh and writes outside the project, blocks non-allowlisted hosts; Claude Code runs with the user's subscription inside the sandbox.

## Product Principles

1. Your agent, your login, our sandbox.
2. Nothing runs unsandboxed: agents, builds and Git actions alike.
3. Honest about maturity: say what works today and what comes next.
4. One command to install, no account, no telemetry from Hearth itself.
