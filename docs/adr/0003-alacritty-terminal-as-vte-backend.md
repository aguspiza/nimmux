# Use libvterm as VTE Backend

* Status: accepted
* Date: 2026-05-30

## Context and Problem Statement

nimmux needs a terminal emulator core: a component that reads raw PTY output, parses VT/ANSI/OSC escape sequences, maintains a terminal grid (cells, attributes, scrollback), and exposes that state for rendering. The original cmux uses libghostty, which is macOS-only.

## Considered Options

* `alacritty_terminal` Rust crate (exposed as a C-compatible shared library)
* libvterm (C library, used by Neovim)
* VTE (GTK's terminal widget, C)
* Implement VTE parsing in Nim from scratch

## Decision Outcome

Chosen option: **libvterm**, because it is a stable C library with a clean public API, requires no Rust toolchain, binds directly from Nim via `{.importc.}`, and has been validated in production by both Neovim and the [nitty](https://github.com/xTrayambak/nitty) Nim terminal emulator (~1000 lines). The previous candidate (`alacritty_terminal`) was dropped due to the cost of maintaining a custom Rust cdylib shim against an unstable internal API.

OSC 9/99/777 notification sequences are not parsed by libvterm out of the box but are handled by the OSC parser in `src/osc.nim` (see migration-plan Phase 3), which processes the raw byte stream before it is fed to libvterm.

### Integration approach

1. Bind libvterm's C API directly from Nim via `{.importc, header: "vterm.h".}` declarations in `src/term.nim`.
2. On Linux: link against the system `libvterm` (`pkg-config --libs vterm`).
3. On Windows: compile libvterm from source as a static library and link it in; libvterm is pure C with no platform dependencies.
4. Rendering is driven by Raylib (see ADR-0004); `src/term.nim` exposes the cell grid and libvterm handles state.

### Consequences

* Good — stable, public C API; no shim to maintain as upstream evolves.
* Good — no Rust toolchain dependency; pure Nim + C build.
* Good — used in production by Neovim and nitty — well-tested VTE implementation.
* Good — pure C with no platform dependencies; builds on Linux and Windows unchanged.
* Bad — OSC 9/99/777 not handled natively; requires the separate `src/osc.nim` parser in the PTY read path.
* Bad — no built-in scrollback beyond what libvterm provides; may need supplementing for large history.

## Pros and Cons of the Options

### libvterm (chosen)
* Good, because stable C API, direct Nim FFI, no extra toolchain.
* Good, because used in production by Neovim and nitty (Nim terminal emulator).
* Good, because pure C — compiles unchanged on Linux and Windows.
* Bad, because OSC 9/99/777 not built-in; handled by `src/osc.nim`.

### alacritty_terminal
* Good, because full-featured, cross-platform, OSC-aware, actively maintained.
* Bad, because requires a custom Rust cdylib shim (`nimmux-term-bridge`) and adds `cargo` to the build.
* Bad, because no stable public C API; shim must be updated as alacritty internals change.

### VTE (GTK)
* Good, because GTK widget handles rendering too.
* Bad, because pulls in the entire GTK stack; not suitable for a non-GTK UI.
* Bad, because Linux-first; Windows support is fragile.

### Implement in Nim from scratch
* Good, because zero external dependencies.
* Bad, because VTE is a large, complex spec; reimplementing it correctly is months of work and a major ongoing maintenance burden.
