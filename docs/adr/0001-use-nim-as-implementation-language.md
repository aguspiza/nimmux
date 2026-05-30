# Use Nim as Implementation Language

* Status: accepted
* Date: 2026-05-30

## Context and Problem Statement

The original cmux is written in Swift, which is macOS/Apple-platform-only. Porting to Linux and Windows requires choosing a systems language that compiles natively on both platforms, supports C FFI (needed to bind Alacritty's terminal library and other C libs), and can produce a lean native binary without a heavy runtime.

## Considered Options

* Nim
* Rust
* C / C++
* Go

## Decision Outcome

Chosen option: **Nim**, because it compiles to C and therefore to any platform a C compiler targets, has first-class C FFI, produces small native binaries, and offers high-level expressiveness that keeps the codebase manageable for a small team. It also interoperates cleanly with the Rust-compiled `alacritty_terminal` cdylib via its C ABI.

### Consequences

* Good — single-language codebase for all platform-specific multiplexer logic (tabs, sidebar, notifications, IPC, session restore).
* Good — C FFI is straightforward; binding the Alacritty cdylib and any OS libs (X11, Wayland, Win32) requires only `{.importc.}` declarations.
* Bad — smaller ecosystem than Rust or Go; fewer ready-made libraries for GUI, clipboard, and platform integration.
* Bad — team must learn Nim if coming from Swift/Rust background.

## Pros and Cons of the Options

### Nim
* Good, because compiles to native code via C; no GC pauses (ARC/ORC memory model).
* Good, because excellent C/C++ FFI without a build system bridge.
* Bad, because smaller community and fewer platform-integration libraries.

### Rust
* Good, because `alacritty_terminal` is already Rust; no FFI layer needed.
* Good, because strong safety guarantees and large ecosystem.
* Bad, because significantly steeper learning curve and slower compile times.

### C / C++
* Good, because maximum control and zero-cost FFI with everything.
* Bad, because high boilerplate; manual memory management increases bug surface.

### Go
* Good, because large stdlib and easy cross-compilation.
* Bad, because GC and goroutine runtime are poorly suited to tight terminal rendering loops; CGo FFI is cumbersome.
