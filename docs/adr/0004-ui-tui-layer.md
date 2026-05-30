# UI / TUI Layer

* Status: accepted
* Date: 2026-05-30

## Context and Problem Statement

nimmux needs a UI layer to render split panes, handle keyboard input (e.g. `Ctrl+D`, `Ctrl+Shift+D`), and display the sidebar. The original cmux is a native macOS GUI app (Swift/AppKit). For the Nim port we must decide between building a standalone GUI window or running as a TUI inside an existing terminal.

This decision directly affects whether ADR-0003 (`alacritty_terminal` FFI) is needed: a TUI approach renders via the host terminal and does not require an embedded VTE engine.

**Reference:** OpenCode (a comparable AI terminal agent tool written in Go) uses the Charmbracelet stack — **bubbletea** (Elm-style TUI loop) + **lipgloss** (layout/styling) + **bubbles** (components). This is a proven pattern for rich terminal UIs.

## Decision Drivers

* MVP scope is narrow: vertical/horizontal splits + session restore
* Must run on Linux and Windows without a display server dependency
* Minimal external dependencies preferred for the PoC phase
* Long-term: sidebar, notification badges, and in-app browser pane require richer layout control

## Considered Options

1. TUI — illwill (Nim ncurses-like)
2. TUI — custom Elm-loop in Nim (bubbletea-inspired)
3. GUI — Raylib + libvterm (own window, GPU-accelerated)
4. GUI — wgpu via Alacritty's renderer (stay in Rust for rendering)
5. GUI — Webview (HTML/CSS chrome + xterm.js panes)

## Decision Outcome

Chosen option: **Option 3 — Raylib + libvterm**, validated by Phase 0 PoC on Windows (2026-05-30). The PoC compiled and ran successfully: Raylib 5.6 window opened, Consolas font loaded, `cmd.exe` spawned via ConPTY, and terminal output rendered in the window.

### Consequences (if Option 3 — Raylib + libvterm)

* Good — own window; faithful to original cmux; GPU-accelerated via OpenGL.
* Good — libvterm handles VTE state; pure C, no Rust toolchain needed.
* Good — Raylib statically links everything; no system library dependencies on Linux/Windows.
* Good — built-in font rendering and texture atlas; no extra libs for text (unlike SDL2).
* Good — active Nim bindings via `naylib`; validated by nitty (Nim terminal emulator).
* Bad — OSC 9/99/777 not built-in to libvterm; handled by `src/osc.nim` in the PTY read path.
* Bad — higher complexity for MVP; more surface area in Phase 0 PoC.

### Consequences (if Option 2 — custom Elm-loop TUI)

* Good — pure Nim, no Rust or GPU dependency; fastest path to MVP.
* Good — aligns with OpenCode's proven bubbletea pattern.
* Good — works in any terminal on Linux and Windows out of the box.
* Bad — runs inside an existing terminal emulator, not a standalone window.
* Bad — ADR-0003 (`alacritty_terminal`) becomes obsolete; PTY management moves to Nim directly.
* Bad — rich UI features (sidebar, notification rings, browser pane) are harder in a TUI.

## Pros and Cons of the Options

### Option 1 — illwill (Nim)
* Good, because it is a ready-made Nim TUI library; no custom framework needed.
* Bad, because low-level (ncurses-like); layout and split rendering require significant manual work.
* Bad, because less actively maintained than the bubbletea ecosystem.

### Option 2 — Custom Elm-loop TUI in Nim (bubbletea-inspired)
* Good, because pure Nim; the Elm `Model / Update / View` pattern scales well (proven by OpenCode).
* Good, because can start minimal and grow; no external TUI library lock-in.
* Bad, because requires building the framework primitives (event loop, layout engine) from scratch.

### Option 3 — Raylib + libvterm `[PoC candidate]`
* Good, because single C library with static linking — no system deps, simple distribution.
* Good, because built-in monospace font rendering and glyph atlas; maps directly to terminal cell rendering.
* Good, because simpler API than SDL2; no need for SDL2_ttf/SDL2_image add-ons.
* Good, because active Nim bindings (`naylib`); validated by nitty (Nim GPU terminal emulator).
* Good, because GPU-accelerated (OpenGL); handles 80×24+ cell redraws at 60fps easily.
* Good, because libvterm is pure C — direct Nim FFI, no Rust toolchain.
* Bad, because Raylib is game-oriented; some terminal-specific concerns (IME, Unicode combining chars) need custom handling.

### Option 4 — wgpu via Alacritty's renderer
* Good, because zero-impedance with `alacritty_terminal` (same codebase).
* Bad, because pulls the rendering entirely into Rust, reducing the Nim surface area.
* Bad, because Alacritty's renderer is not designed as a reusable library; API is unstable.

### Option 5 — Webview
* Good, because HTML/CSS/JS enables rich sidebar and notification UI with little effort.
* Good, because xterm.js handles terminal rendering inside the browser pane.
* Bad, because webview bundles a browser engine — heavy dependency and slow startup.
* Bad, because cross-process IPC between Nim host and JS UI adds latency and complexity.
