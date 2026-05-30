# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

nimmux is a port of [cmux](https://github.com/manaflow-ai/cmux) from Swift/AppKit (macOS) to Nim for Linux and Windows (Posix). The original cmux is a Ghostty-based terminal multiplexer with vertical tabs, notification rings, and an in-app browser designed for running AI coding agents in parallel.

The Nim port targets Posix platforms (Linux + Windows via POSIX layer), replacing:
- Swift/AppKit → Nim
- libghostty (macOS GPU-accelerated terminal) → cross-platform terminal backend (TBD)
- macOS native UI → cross-platform UI (TBD)

## Core Features to Port

1. **Workspaces/tabs** — vertical sidebar showing per-workspace metadata: git branch, linked PR status, working directory, listening ports, latest notification text
2. **Split panes** — horizontal and vertical splits within a workspace
3. **Notification system** — picks up OSC 9/99/777 terminal sequences; pane gets a visual ring + tab lights up when agent is waiting; `nimmux notify` CLI command; `Cmd+Shift+U` equivalent to jump to latest unread
4. **Notification panel** — aggregated view of all pending notifications
5. **In-app browser** — split browser pane with scriptable API (accessibility tree, click, fill, JS eval); ported from [agent-browser](https://github.com/vercel-labs/agent-browser)
6. **SSH workspaces** — `nimmux ssh user@remote` creates a workspace for a remote machine; browser panes route through remote network; drag-to-upload via scp
7. **Claude Code Teams** — `nimmux claude-teams` spawns teammate sessions as native splits with sidebar metadata
8. **Session restore** — saves/restores window layout, working dirs, scrollback, browser URL on quit/relaunch
9. **Hooks integration** — `nimmux hooks setup [agent]` installs resume hooks for Claude Code, Codex, OpenCode, etc.
10. **Scriptable CLI + socket API** — create workspaces/tabs, split panes, send keystrokes, open browser URLs
11. **Config** — reads `~/.config/nimmux/nimmux.json` (analogous to `~/.config/cmux/cmux.json`)

## Architecture Decision Records

Decisions are recorded in [`docs/adr/`](docs/adr/) using [MADR](https://adr.github.io/madr/) format. Name new files `NNNN-short-title.md`.

## Key Architectural Differences from Original

- **Terminal backend — Alacritty** — use the `alacritty_terminal` Rust crate as the VTE parser and terminal state engine. Build it as a C-compatible shared library (`cdylib`) and call it from Nim via FFI. This gives GPU-accelerated rendering (wgpu) and full cross-platform support without reimplementing VTE.
- **No AppKit/SwiftUI** — UI layer must be chosen for cross-platform: options include a TUI (e.g., illwill/nimcurses), a GUI toolkit (e.g., nimx, webview), or embedding a browser-based UI. The tab/sidebar/notification chrome is built in Nim on top of the Alacritty terminal surfaces.
- **OSC sequences** — the notification system is protocol-based (OSC 9/99/777), so it's terminal-agnostic and can be preserved exactly. `alacritty_terminal` already parses these.
- **Socket API** — original uses a Unix domain socket; this works on Linux and Windows (via `\\.\pipe\` or WSL socket).
- **Session state** — stored under `~/.local/share/nimmux/` on Linux (XDG), `%APPDATA%\nimmux\` on Windows; agent hooks write to `~/.nimmuxterm/`.

## Development Environment

**Shell:** Use Git Bash (Bash tool) for all shell commands on Windows — not PowerShell.

**Linux testing:** Use WSL (`wsl` prefix or `wsl bash -c "..."`) to test the Linux build without leaving Windows.

## Build & Dev Commands

Run from the project root (`C:/Users/Gus/coding/nimmux/`):

```sh
nimble test           # run all tests via testament
nimble build          # build nimmux binary
nimble run            # build and run
nim c -r tests/test_scaffold.nim   # compile and run a single test file
```

**First-time setup** (generates `nimble.paths`):
```sh
nimble setup
```

**PoC** lives in `poc/` — built separately with its own nimble file:
```sh
cd poc && nimble build
```

**Linux testing** (from Windows): prefix commands with `wsl` or use the Bash tool inside WSL.
