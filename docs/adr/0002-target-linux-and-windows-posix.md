# Target Linux and Windows (POSIX)

* Status: accepted
* Date: 2026-05-30

## Context and Problem Statement

The original cmux targets macOS exclusively, relying on AppKit, libghostty, Sparkle (auto-update), and macOS-specific APIs. The port must decide which platforms to support and how to handle the platform surface area (PTY, sockets, filesystem paths, windowing).

## Considered Options

* Linux only
* Linux + Windows via POSIX compatibility layer (WSL2 / MSYS2 / native Win32 POSIX APIs)
* Linux + macOS (keep macOS, drop Windows)
* All three (Linux + Windows + macOS)

## Decision Outcome

Chosen option: **Linux + Windows (POSIX)**, because:
- The primary motivation for the port is non-macOS support; keeping macOS would just duplicate the original.
- Windows has a POSIX compatibility surface (MSYS2/MinGW, WSL2, and Win32's own POSIX subset) sufficient for PTY handling (ConPTY) and Unix-domain sockets (AF_UNIX on Win10+).
- Supporting both platforms from the start prevents Linux-only assumptions from hardening into the codebase.

**Minimum Windows version: 10 1903 (May 2019).** Required for:
- ConPTY (`CreatePseudoConsole`) — Win10 1809+
- AF_UNIX sockets — Win10 1803+
- UTF-8 active code page via app manifest — Win10 1903+

### UTF-8 only

nimmux uses UTF-8 exclusively on both platforms. On Windows this is enabled by:
1. Declaring `<activeCodePage>UTF-8</activeCodePage>` in the app manifest — all narrow Win32 APIs treat strings as UTF-8.
2. ConPTY communicates over pipes (byte streams), so UTF-8 flows through without conversion.
3. Raylib renders via Unicode codepoints; the only step needed is UTF-8 decode → codepoint.
4. Nim 2.x handles UTF-8↔UTF-16 conversion internally for Win32 calls; application code stays UTF-8 throughout.

No wide-string (`*W`) Win32 APIs, no code page detection, no `winpty` fallback.

### Consequences

* Good — covers the two main non-macOS developer platforms.
* Good — Nim's cross-compilation and `os` / `posix` stdlib modules handle most differences transparently.
* Good — UTF-8 only simplifies string handling across the entire codebase.
* Bad — Windows 10 1903+ floor; older Windows versions are not supported.
* Bad — ConPTY adds a platform-specific PTY abstraction layer vs `openpty`/`forkpty` on Linux.
* Bad — windowing/rendering differences (X11/Wayland vs Win32) require platform-conditional code in the UI layer (handled by Raylib).

## Platform-Specific Notes

| Concern | Linux | Windows (10 1903+) |
|---|---|---|
| PTY | `openpty` / `forkpty` (POSIX) | ConPTY (`CreatePseudoConsole`) |
| Encoding | UTF-8 | UTF-8 (active code page via manifest) |
| IPC socket | AF_UNIX | AF_UNIX (Win10 1803+) |
| Config dir | `$XDG_CONFIG_HOME/nimmux` | `%APPDATA%\nimmux` |
| Data dir | `$XDG_DATA_HOME/nimmux` | `%APPDATA%\nimmux` |
| Agent hooks dir | `~/.nimmuxterm/` | `%USERPROFILE%\.nimmuxterm\` |
