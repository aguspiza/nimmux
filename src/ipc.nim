## IPC client — DaemonPty wraps a daemon session over TCP.
## Implements the same interface as Pty so nimmux.nim needs minimal changes.

import std/[json, net]
import daemon

# ── module-level control connection (shared across all DaemonPty instances) ───

var daemonCtrl: Socket

proc connectDaemon*() =
  daemonCtrl = newSocket()
  daemonCtrl.connect(DaemonHost, Port(ControlPort), timeout = 3000)

proc isDaemonConnected*(): bool =
  daemonCtrl != nil

proc sendCmd(j: JsonNode): JsonNode =
  daemonCtrl.send($j & "\n")
  var line = ""
  daemonCtrl.readLine(line, timeout = 5000)
  parseJson(line)

# ── DaemonPty type ────────────────────────────────────────────────────────────

type DaemonPty* = ref object
  sessionId*: int
  pid*:       int
  masterFd*:  int   ## always 0 for daemon-backed sessions
  dataPort:   int
  data:       Socket

proc spawnSession*(shell, cwd: string; cols = 80'i32; rows = 24'i32): DaemonPty =
  let resp = sendCmd(%*{"cmd": "spawn", "shell": shell, "cwd": cwd,
                        "cols": cols, "rows": rows})
  if not resp{"ok"}.getBool():
    raise newException(IOError, "daemon spawn failed: " & resp{"error"}.getStr())
  let id   = resp["sessionId"].getInt()
  let pid  = resp["pid"].getInt()
  let port = resp["dataPort"].getInt()
  var data = newSocket()
  data.connect(DaemonHost, Port(port), timeout = 3000)
  DaemonPty(sessionId: id, pid: pid, masterFd: 0, dataPort: port, data: data)

proc attachSession*(sessionId: int): DaemonPty =
  ## Reconnect to an existing daemon session.
  let resp = sendCmd(%*{"cmd": "list"})
  for sess in resp{"sessions"}:
    if sess["id"].getInt() != sessionId: continue
    let pid  = sess["pid"].getInt()
    let port = sess["dataPort"].getInt()
    var data = newSocket()
    data.connect(DaemonHost, Port(port), timeout = 3000)
    return DaemonPty(sessionId: sessionId, pid: pid, masterFd: 0,
                     dataPort: port, data: data)
  raise newException(KeyError, "daemon session not found: " & $sessionId)

proc listDaemonSessions*(): seq[tuple[id, pid: int; cwd: string]] =
  let resp = sendCmd(%*{"cmd": "list"})
  for sess in resp{"sessions"}:
    result.add((id: sess["id"].getInt(), pid: sess["pid"].getInt(),
                cwd: sess["cwd"].getStr()))

# ── DaemonPty interface (mirrors Pty) ─────────────────────────────────────────

proc readAvailable*(dp: DaemonPty; buf: var seq[byte]): int =
  if dp.data == nil: return 0
  var data = newString(4096)
  var n = 0
  try: n = dp.data.recv(data, 4096, timeout = 0)
  except TimeoutError: return 0
  except CatchableError: return 0
  if n > 0:
    let before = buf.len
    buf.setLen(before + n)
    copyMem(addr buf[before], addr data[0], n)
  n

proc write*(dp: DaemonPty; data: string) =
  if data.len == 0 or dp.data == nil: return
  try: dp.data.send(data) except: discard

proc resize*(dp: DaemonPty; cols, rows: int32) =
  try:
    discard sendCmd(%*{"cmd": "resize", "sessionId": dp.sessionId,
                       "cols": cols, "rows": rows})
  except: discard

proc isAlive*(dp: DaemonPty): bool =
  try:
    let resp = sendCmd(%*{"cmd": "alive", "sessionId": dp.sessionId})
    resp{"alive"}.getBool()
  except: false

proc currentCwd*(dp: DaemonPty): string =
  try:
    let resp = sendCmd(%*{"cmd": "cwd", "sessionId": dp.sessionId})
    resp{"cwd"}.getStr("")
  except: ""

proc close*(dp: DaemonPty) =
  ## Detach from session — session and shell stay alive in daemon.
  if dp.data != nil:
    try: dp.data.close() except: discard
    dp.data = nil

proc shellPid*(dp: DaemonPty): int = dp.pid
