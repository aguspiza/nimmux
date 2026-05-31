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

## MVP 1.1 Scope

| Phase | Feature | Blocks |
|-------|---------|--------|
| A | OSC sequence parser | C |
| B | Workspace tabs + sidebar | — |
| C | Notification state | D |
| D | Notification panel overlay | — |
| E | IPC socket server | F |
| F | CLI (`nimmux notify`, `nimmux split`, …) | G |
| G | Hooks integration (`nimmux hooks setup`) | — |
| H | In-app browser | — |
| I | SSH workspaces | — |
| J | Claude Code Teams | — |

**Parallel tracks — none of these rows block each other:**
```
A ──► C ──► D
B
E ──► F ──► G
H
I
J
```

E (IPC socket) is the only gate: F (CLI) and G (hooks) cannot start until E is done.
Everything else — A, B, C, D, H, I, J — is independent and can be worked in any order.

**MVP 1.1 done when:** a Claude Code agent running inside a nimmux pane can send a notification that lights up the tab, a human can jump to it with a keybind, and the session survives across restarts with hooks auto-resuming the agent.

---

## Phase 0 — PoC: Alacritty Integration + Splits ✓ DONE (2026-05-30)

**Goal:** validate that libvterm + Raylib can be called from Nim and that multiple terminal instances can be rendered in vertical and horizontal split layouts.

**Result:** All Windows exit criteria passed on first run.
- [x] Two live shell panes render in a vertical split
- [x] Two live shell panes render in a horizontal split
- [x] Switching focus between panes works (Tab)
- [x] Runs on Linux — WSL2 Ubuntu 24.04, Mesa llvmpipe, X11/GLFW
- [x] Runs on Windows

**Stack validated:** libvterm 0.3.3 (bundled C source, `{.compile.}`) + ConPTY + Raylib 5.6 (`naylib`) + Nim 2.2.10 on Windows MSVC. PoC code lives in `poc/`.

---

## Phase 1 — Project Scaffold `[MVP]`

**Goal:** a clean Nim project replacing the PoC throwaway code, with CI and a passing test.

- [x] `nimble init` — create `nimmux.nimble`, `src/`, `tests/`
- [x] Test framework — `testament`
- [x] CI — GitHub Actions matrix: `ubuntu-latest` + `windows-latest` (`.github/workflows/ci.yml`)
- [x] First test: `tests/test_scaffold.nim` — `check 1 == 1` — passes locally
- [x] CI green on both platforms (ubuntu 9s, windows 29s — 2026-05-30)

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

## Phase 3 — OSC Sequence Parser `[MVP 1.1 / A]`

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

## Phase 6 — Notification State Machine `[MVP 1.1 / C]`

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

## Phase 9 — CLI `[MVP 1.1 / F]`

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

## Phase 10 — IPC Socket Server `[MVP 1.1 / E]`

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

## Phase 12 — In-App Browser `[MVP 1.1 / H]`

> ADR required: choose browser embedding strategy (webview2 on Windows, WebKitGTK on Linux, or Electron/Tauri bridge).

---

## Phase 13 — SSH Workspaces `[MVP 1.1 / I]`

`nimmux ssh user@remote` — remote PTY with browser proxy routing.
**Tests:** integration tests against a local SSH server (e.g., OpenSSH in Docker).

---

## Phase 14 — Workspace Tabs + Sidebar `[MVP 1.1 / B]`

The vertical tab strip on the left showing all open workspaces. Each tab displays:
git branch, working directory, listening ports, latest notification text, and an unread indicator ring.

**Keybindings:** `Ctrl+T` new workspace, `Ctrl+Shift+W` close workspace, `Ctrl+1`…`9` jump to workspace N.

**Tests first:**
```nim
# tests/test_tabs.nim
test "new tab creates a fresh workspace":
  var tm = initTabManager()
  let id = tm.addTab()
  check tm.tabs.len == 2

test "close tab removes it and focuses adjacent":
  var tm = initTabManager()
  let id = tm.addTab()
  tm.closeTab(id)
  check tm.tabs.len == 1

test "tab metadata reflects workspace state":
  var tm = initTabManager()
  tm.setMeta(tm.activeTab, cwd = "/home/user/project", branch = "main")
  check tm.meta(tm.activeTab).branch == "main"
```

**Implement:** `src/tabs.nim` — tab list + per-tab `Workspace`; `renderer.nim` extended with sidebar strip.

---

## Phase 15 — Notification Panel `[MVP 1.1 / D]`

Full-screen overlay listing every pending notification across all workspaces, newest first.
`Ctrl+Shift+U` toggles the panel; selecting an entry jumps to that pane and marks it read.

**Tests first:**
```nim
# tests/test_notif_panel.nim
test "panel lists all unread notifications":
  var ns = initNotifState()
  ns.add(paneId = 1, body = "a")
  ns.add(paneId = 2, body = "b")
  check ns.allUnread().len == 2

test "selecting entry marks it read":
  var ns = initNotifState()
  ns.add(paneId = 1, body = "x")
  ns.markRead(1)
  check ns.allUnread().len == 0
```

**Implement:** `renderer.nim` — `drawNotifPanel(…)` overlay; `nimmux.nim` — toggle state + keyboard nav.

---

## Phase 16 — Hooks Integration `[MVP 1.1 / G]`

`nimmux hooks setup [agent]` installs a resume hook for the named agent (claude-code, codex, opencode).
The hook calls `nimmux notify "agent is waiting"` so the pane gets a notification ring.

**Agents supported:** `claude-code` (writes `~/.claude/hooks/`), `codex`, `opencode`.

**Tests first:**
```nim
# tests/test_hooks.nim
test "generates claude-code hook script":
  let script = hookScript("claude-code")
  check "nimmux notify" in script

test "hook install writes file":
  let dir = getTempDir() / "nimmux_hook_test"
  installHook("claude-code", hooksDir = dir)
  check fileExists(dir / "stop.sh")
```

**Implement:** `src/hooks.nim` — template per agent; `src/cli.nim` extended with `hooks setup` sub-command.

---

## Phase 17 — Claude Code Teams `[MVP 1.1 / J]`

`nimmux claude-teams` spawns multiple Claude Code sessions as native splits within a workspace,
each with sidebar metadata (task description, status, branch).

**Tests first:**
```nim
# tests/test_teams.nim
test "spawns N agent panes":
  var ws = newWorkspace()
  spawnTeam(ws, count = 3, cmd = "echo agent")
  check ws.leaves().len == 3
```

**Implement:** `src/teams.nim` — splits workspace N ways, launches agent command in each pane,
hooks into notification state for per-agent status display.

---

## Dependency Order

MVP 1.0 path marked with `*`. MVP 1.1 path marked with `†`.

```
Phase 0  * (PoC — Alacritty + splits)  ← architecture gate
  └─ Phase 1  * (scaffold)
       ├─ Phase 2    (config)                                   ✓ DONE
       ├─ Phase 3  † (OSC parser / A)
       └─ Phase 4  * (FFI bridge — real)
            └─ Phase 5  * (PTY)
                 ├─ Phase 6  † (notification state / C)
                 │    └─ Phase 15 † (notification panel / D)
                 └─ Phase 7  * (workspace model)
                      ├─ Phase 8  * (session restore)           ← MVP 1.0 done ✓
                      ├─ Phase 14 † (workspace tabs+sidebar / B)
                      ├─ Phase 9  † (CLI / F)
                      │    └─ Phase 16 † (hooks / G)
                      └─ Phase 10 † (IPC / E)  ← gates F and G
                           └─ Phase 11 * (UI)                   ✓ DONE
                                ├─ Phase 12 † (browser / H)    ← ADR gate
                                ├─ Phase 13 † (SSH / I)
                                └─ Phase 17 † (Claude Code Teams / J)
```
