# nimmux Migration Plan

Port of cmux (Swift/macOS) → Nim (Linux/Windows). TDD throughout: write a failing test, implement the minimum to pass, refactor.

---

## MVP 1.0 Scope

| Feature | Keybinding | Phase |
|---------|-----------|-------|
| Split pane vertically | `Ctrl+D` | 0, 7, 11 |
| Split pane horizontally | `Ctrl+Shift+D` | 0, 7, 11 |
| Session restore (exit + recover) | — | 8 |

Everything else (notifications, browser, SSH, hooks, IPC API, config) is post-MVP.

**MVP done when:** user can open nimmux, split vertically with `Ctrl+D`, split horizontally with `Ctrl+Shift+D`, close the app, reopen it, and get their session back.

---

## Phase 0 — PoC: Alacritty Integration + Splits

**Goal:** validate that `alacritty_terminal` can be called from Nim and that multiple terminal instances can be rendered in vertical and horizontal split layouts. This phase gates the entire architecture — if it fails, ADR-0003 must be revisited.

> This is exploratory, not TDD. Code is throwaway. Success = the demo runs.

**Steps:**

1. **libvterm bindings** — write minimal Nim `{.importc.}` bindings to libvterm:
   - `term_new(cols, rows) → VTerm`
   - `term_free(t)`
   - `vterm_input_write(t, bytes, len)` — feed raw PTY output
   - `vterm_screen_get_cell(screen, pos) → VTermScreenCell` — read a character cell

2. **Nim PTY** — spawn two PTYs (one per pane), each feeding into its own `VTerm`

3. **Split renderer** — render two `VTerm` grids side by side in a Raylib window:
   - Vertical split: pane A left | pane B right
   - Horizontal split: pane A top / pane B bottom
   - Use the simplest available rendering surface (SDL2, OpenGL, or even a terminal via ANSI codes for a first pass)

4. **Interactive demo** — both panes run a real shell; keyboard input routes to the focused pane

**PoC exit criteria:**
- [ ] Two live shell panes render in a vertical split
- [ ] Two live shell panes render in a horizontal split
- [ ] Switching focus between panes works
- [ ] Runs on Linux
- [ ] Runs on Windows (stretch goal for PoC)

**If PoC fails:** open a new ADR to choose an alternative VTE backend (see ADR-0003 options).

---

## Phase 1 — Project Scaffold `[MVP]`

**Goal:** a clean Nim project replacing the PoC throwaway code, with CI and a passing test.

- [ ] `nimble init` — create `nimmux.nimble`, `src/`, `tests/`
- [ ] Test framework — `testament`
- [ ] CI — GitHub Actions matrix: `ubuntu-latest` + `windows-latest`
- [ ] Promote the PoC Rust shim from `bridge/poc/` to `bridge/` as the real shim
- [ ] First test: `tests/test_scaffold.nim` — assert `1 == 1`

**Verify:** `nimble test` green on both platforms.

---

## Phase 2 — Config Parser `[post-MVP]`

Pure logic, no I/O — ideal TDD starting point.

**Tests first:**
```nim
# tests/test_config.nim
test "default config is valid":
  let cfg = defaultConfig()
  check cfg.terminal.autoResumeAgentSessions == true

test "parses nimmux.json":
  let cfg = parseConfig("""{"terminal":{"autoResumeAgentSessions":false}}""")
  check cfg.terminal.autoResumeAgentSessions == false

test "unknown keys are ignored":
  check parseConfig("""{"unknown":1}""") == defaultConfig()
```

**Implement:** `src/config.nim` — types + JSON deserialisation (`std/json`).

---

## Phase 3 — OSC Sequence Parser `[post-MVP]`

The notification system is entirely driven by OSC 9/99/777. Parsing these sequences is pure logic.

**Tests first:**
```nim
# tests/test_osc.nim
test "detects OSC 9 notification":
  let n = parseOsc("\e]9;Agent waiting\a")
  check n.kind == oscNotify
  check n.body == "Agent waiting"

test "detects OSC 777":
  let n = parseOsc("\e]777;notify;Title;Body\a")
  check n.title == "Title"
  check n.body == "Body"

test "ignores unrelated sequences":
  check parseOsc("\e]2;window title\a").kind == oscOther
```

**Implement:** `src/osc.nim` — state machine parser for OSC sequences in a byte stream.

---

## Phase 4 — libvterm Bindings `[MVP]`

Promote the PoC libvterm bindings into the real, tested module.

**Tests first:**
```nim
# tests/test_term.nim
test "advances terminal state":
  let t = termNew(80, 24)
  termAdvance(t, "hello")
  check termCell(t, 0, 0).ch == 'h'
  termFree(t)

test "cursor advances after input":
  let t = termNew(80, 24)
  termAdvance(t, "hi")
  check termCursorCol(t) == 2
  termFree(t)
```

**Implement:** `src/term.nim` — Nim `{.importc.}` bindings to libvterm's C API (`vterm.h`).
- Linux: link via `pkg-config --libs vterm`
- Windows: compile libvterm from source as a static lib

---

## Phase 5 — PTY Layer `[MVP]`

**Tests first:**
```nim
# tests/test_pty.nim
test "spawns a shell and reads output":
  let pty = ptySpawn("/bin/sh", @["-c", "echo hi"])
  check "hi" in pty.read(timeout = 500)
  pty.close()

test "writes to stdin":
  let pty = ptySpawn("/bin/sh", @[])
  pty.write("echo hello\n")
  check "hello" in pty.read(timeout = 500)
  pty.close()
```

**Implement:** `src/pty.nim`
- Linux: `openpty` / `forkpty` via `posix` module
- Windows: `CreatePseudoConsole` (ConPTY) via Win32 FFI

---

## Phase 6 — Notification State Machine `[post-MVP]`

**Tests first:**
```nim
# tests/test_notifications.nim
test "new notification marks pane unread":
  var ns = initNotifState()
  ns.add(paneId = 1, body = "waiting")
  check ns.unread(1) == true

test "jump to latest unread":
  var ns = initNotifState()
  ns.add(paneId = 2, body = "a")
  ns.add(paneId = 3, body = "b")
  check ns.latestUnread() == 3

test "marking read clears badge":
  var ns = initNotifState()
  ns.add(paneId = 1, body = "x")
  ns.markRead(1)
  check ns.unread(1) == false
```

**Implement:** `src/notifications.nim` — pure state, no I/O.

---

## Phase 7 — Workspace / Pane Model `[MVP]`

**Tests first:**
```nim
# tests/test_workspace.nim
test "new workspace has one pane":
  check newWorkspace().panes.len == 1

test "split right adds a pane":
  var ws = newWorkspace()
  ws.splitRight(ws.focusedPane)
  check ws.panes.len == 2

test "close pane removes it":
  var ws = newWorkspace()
  let p = ws.splitRight(ws.focusedPane)
  ws.closePane(p)
  check ws.panes.len == 1
```

**Implement:** `src/workspace.nim` — split-tree data structure, no rendering.

---

## Phase 8 — Session Restore `[MVP]`

**Tests first:**
```nim
# tests/test_session.nim
test "round-trips workspace layout":
  var ws = newWorkspace()
  ws.splitRight(ws.focusedPane)
  let restored = restoreWorkspace(ws.snapshot())
  check restored.panes.len == ws.panes.len

test "snapshot is valid JSON":
  check parseJson(newWorkspace().snapshot()).kind == JObject
```

**Implement:** `src/session.nim` — snapshot/restore using `std/json`.

---

## Phase 9 — CLI `[post-MVP]`

**Tests first (subprocess-level):**
```sh
# run via testament exec
nimmux notify "test body"   # exits 0
nimmux --version             # prints semver
nimmux hooks list            # exits 0
```

**Implement:** `src/cli.nim` — argument parsing with `std/parseopt`.
Sub-commands: `notify`, `hooks setup [agent]`, `ssh`, `restore-session`, `surface resume`.

---

## Phase 10 — IPC Socket Server `[post-MVP]`

**Tests first:**
```nim
# tests/test_ipc.nim
test "creates workspace via socket":
  let client = ipcConnect()
  client.send("""{"cmd":"new_workspace"}""")
  check parseJson(client.recv())["ok"].getBool == true

test "split pane via socket":
  let client = ipcConnect()
  client.send("""{"cmd":"split","direction":"right"}""")
  check parseJson(client.recv())["ok"].getBool == true
```

**Implement:** `src/ipc.nim` — async socket server using `std/asyncnet`.

---

## Phase 11 — UI Layer `[MVP]`

> Gated on [ADR-0004](adr/0004-ui-tui-layer.md) — resolved by Phase 0 PoC outcome: Raylib + libvterm (GUI) or custom Elm-loop TUI. Must bind `Ctrl+D` and `Ctrl+Shift+D` for splits.

---

## Phase 12 — In-App Browser `[post-MVP]`

> ADR required: choose browser embedding strategy (webview2 on Windows, WebKitGTK on Linux, or Electron/Tauri bridge).

---

## Phase 13 — SSH Workspaces `[post-MVP]`

`nimmux ssh user@remote` — remote PTY with browser proxy routing.
**Tests:** integration tests against a local SSH server (e.g., OpenSSH in Docker).

---

## Dependency Order

MVP path marked with `*`.

```
Phase 0 * (PoC — Alacritty + splits)  ← architecture gate
  └─ Phase 1 * (scaffold)
       ├─ Phase 2   (config)
       ├─ Phase 3   (OSC parser)
       └─ Phase 4 * (FFI bridge — real)
            └─ Phase 5 * (PTY)
                 ├─ Phase 6   (notifications)
                 └─ Phase 7 * (workspace model)
                      ├─ Phase 8 * (session restore)  ← MVP done
                      ├─ Phase 9   (CLI)
                      └─ Phase 10  (IPC)
                           └─ Phase 11 * (UI — keybindings Ctrl+D / Ctrl+Shift+D)  ← ADR gate
                                ├─ Phase 12  (browser)  ← ADR gate
                                └─ Phase 13  (SSH)
```
