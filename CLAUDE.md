# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

nimmux is a port of [cmux](https://github.com/manaflow-ai/cmux) from Swift/AppKit (macOS) to Nim for Linux and Windows (Posix). The original cmux is a Ghostty-based terminal multiplexer with vertical tabs, notification rings, and an in-app browser designed for running AI coding agents in parallel.

The Nim port targets Linux and Windows, replacing:
- Swift/AppKit → Nim
- libghostty → libvterm 0.3.3 (bundled C source, `{.compile.}`) for VTE parsing
- macOS native UI → Raylib via naylib for GPU-accelerated cross-platform rendering

## Feature Status

✅ done · 🔲 MVP 1.1 · ⬜ later

| | Feature |
|--|---------|
| ✅ | Split panes — `Ctrl+D` vertical, `Ctrl+Shift+D` horizontal, `Ctrl+W` close |
| ✅ | Pane focus — `Ctrl+Shift+]` / `Ctrl+Shift+[` |
| ✅ | **Processes persist on close** (PTYs not terminated, session saved) |
| ⚠️ | Shell exit closes pane; last pane exits app |
| ✅ | Window resize reflows all panes |
| ✅ | Config — `nimmux.json`, unknown keys ignored |
| ✅ | Sidebar toggle — `Ctrl+Shift+S` collapse/expand (hidden when collapsed) |
| ⚠️ | OSC 9/99/777 parser (modular, not yet integrated) |
| ⚠️ | Workspace tabs + sidebar (git branch, CWD, notification badge, LEFT side, click to focus) |
| ⚠️ | Notification state (parser integrated, no UI panel yet) |
| ⚠️ | Jump-to-unread — `Ctrl+Shift+U` (implemented, needs pane highlight) |
| 🔲 | **IPC socket** (gates CLI and hooks) |
| 🔲 | CLI — `nimmux notify`, `nimmux split`, `nimmux hooks setup [agent]` |
| 🔲 | Hooks — resume hooks for Claude Code, Codex, OpenCode |
| ⬜ | In-app browser (scriptable: click, fill, JS eval) |
| ⬜ | SSH workspaces — `nimmux ssh user@remote` |
| ⬜ | Claude Code Teams — `nimmux claude-teams` |

### PTY Persistence (MVP 1.1)

**Current behavior:**
- **Start nimmux** → Shell spawns with PID X
- **Close nimmux** → Shell persists (PID X continues running)
- **Restart nimmux** → New shell spawns with PID Y

**Windows limitation:** ConPTY uses HPCON handles which cannot be transferred between processes. This means:
- Old shells continue running (not killed) ✅
- New shells are spawned on restart (not reconnected) ⚠️

**For true session persistence on Windows**, we need the daemon architecture where:
- Daemon owns PTY processes
- Main app connects via IPC
- Daemon can reconnect to existing PTYs

**Daemon architecture** (`src/daemon.nim`):
- `nimmux-daemon.exe` is now built
- Separate process for PTY management
- IPC socket server (Unix socket on Linux, named pipe on Windows)
- Currently: Infrastructure ready, PTY management not yet integrated
- Future: Main app delegates PTY spawning to daemon

## Architecture Decision Records

Decisions are recorded in [`docs/adr/`](docs/adr/) using [MADR](https://adr.github.io/madr/) format. Name new files `NNNN-short-title.md`.

## Architecture

- **Terminal emulation** — libvterm 0.3.3, compiled from bundled source in `vendor/libvterm/` via `{.compile.}` pragmas. No system dependency. Bindings live in `src/term.nim`.
- **PTY** — `src/pty.nim`: `openpty`/`fork`/`execvp` on Linux; `CreatePseudoConsole` (ConPTY) on Windows.
- **Rendering** — Raylib via naylib (`naylib >= 5.0.0`). `src/renderer.nim` draws terminal cells and UI chrome. `src/nimmux.nim` is the main loop.
- **OSC sequences** — notification system uses OSC 9/99/777, parsed separately from libvterm output (libvterm strips them). Parser lives in `src/osc.nim` (MVP 1.1).
- **IPC** — Unix domain socket on Linux, named pipe on Windows. `src/ipc.nim` (MVP 1.1).
- **Session state** — `~/.local/share/nimmux/session.json` on Linux, `%APPDATA%\nimmux\session.json` on Windows.
- **Config** — `~/.config/nimmux/nimmux.json` on Linux, `%APPDATA%\nimmux\nimmux.json` on Windows. Unknown keys are silently ignored.

## Keybindings

All keybindings currently assume **US keyboard layout** (Raylib `KeyboardKey` is position-based). Symbols like `[`, `]`, `=`, `-` are matched by physical key position, so they differ on non-US keyboards. Configurable keybindings are planned for MVP 1.1 (phase G).

## Test-Driven Development

**All new logic must be written test-first.** Before implementing a feature or fix:

1. Write a failing test in `tests/test_<module>.nim`
2. Run it to confirm it fails for the right reason
3. Implement the minimum code to make it pass
4. Run the full suite (`nimble test`) — **tests must pass before every commit and push**

Tests that cannot be automated (Raylib rendering, PTY I/O) are exempt — everything else is not.

## Development Environment

**Shell:** Use Git Bash (Bash tool) for all shell commands on Windows — not PowerShell.

**Linux testing:** Use WSL (`wsl` prefix or `wsl bash -c "..."`) to test the Linux build without leaving Windows.

## Build & Dev Commands

```sh
nimble test                      # run all tests via testament
nimble build                     # build nimmux binary
nimble run                       # build and run
testament run tests/test_workspace.nim  # run a single test file
```

**First-time setup** (generates `nimble.paths`, machine-local — not committed):
```sh
nimble setup
```

**Linux testing** (from Windows): prefix commands with `wsl` or use the Bash tool inside WSL.
