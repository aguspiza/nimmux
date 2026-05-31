# nimmux

A terminal multiplexer built for running AI coding agents in parallel — a port of [cmux](https://github.com/manaflow-ai/cmux) from Swift/macOS to Nim, targeting Linux and Windows.

Split your terminal into panes, run a Claude Code session in each, and get notified when an agent is waiting for you.

## Status

MVP 1.0 is working: panes split, shells run, sessions restore across restarts.
MVP 1.1 is in progress: notification system, workspace tabs, CLI, and hooks.

## Keybindings

| Key | Action |
|-----|--------|
| `Ctrl+D` | Split pane vertically |
| `Ctrl+Shift+D` | Split pane horizontally |
| `Ctrl+W` | Close focused pane |
| `Ctrl+Shift+]` | Next pane |
| `Ctrl+Shift+[` | Previous pane |

## Building

```sh
nimble setup   # first time only
nimble build
nimble run
```

Requires Nim 2.2+ and [naylib](https://github.com/planetis-m/naylib) (`nimble install naylib`).

## Running tests

```sh
nimble test
# or a single file:
testament run tests/test_workspace.nim
```

## Architecture

| Layer | Library |
|-------|---------|
| Terminal emulation | libvterm 0.3.3 (bundled) |
| PTY | ConPTY (Windows) · openpty (Linux) |
| Rendering | Raylib via naylib |

## Roadmap

See [`docs/migration-plan.md`](docs/migration-plan.md) for the full phase breakdown.
MVP 1.1 brings: OSC notifications, workspace tabs with sidebar metadata, `nimmux notify` CLI, and agent hooks for Claude Code / Codex / OpenCode.
