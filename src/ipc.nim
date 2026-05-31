## IPC client — DaemonPty wraps either a daemon TCP session or a direct Pty.
## If the daemon is unavailable, all operations fall through to direct PTY.

import std/[json, net, nativesockets, os, times]
import daemon
import pty

# ── module-level control connection ──────────────────────────────────────────

var daemonCtrl: Socket  ## nil when daemon is unavailable

proc connectDaemon*() =
  ## Try to connect to the daemon. If unreachable, silently sets daemonCtrl=nil
  ## so that all subsequent calls fall back to direct PTY.
  try:
    var s = newSocket()
    s.connect(DaemonHost, Port(ControlPort), timeout = 500)
    s.getFd().setBlocking(false)
    daemonCtrl = s
  except CatchableError:
    daemonCtrl = nil

proc isDaemonConnected*(): bool = daemonCtrl != nil

proc sendCmd(j: JsonNode): JsonNode =
  let msg = $j & "\n"
  discard nativesockets.send(daemonCtrl.getFd(), cast[cstring](unsafeAddr msg[0]), msg.len.cint, 0)
  var line = ""
  let deadline = getTime() + initDuration(milliseconds = 5000)
  while getTime() < deadline:
    var chunk: array[4096, byte]
    let n = nativesockets.recv(daemonCtrl.getFd(), cast[cstring](addr chunk[0]), 4096, 0).int
    if n > 0:
      for i in 0 ..< n:
        if chunk[i] == byte('\n'):
          return parseJson(line)
        line.add(char(chunk[i]))
    elif n == 0:
      raise newException(IOError, "daemon disconnected")
    os.sleep(1)
  raise newException(TimeoutError, "daemon timeout")

# ── DaemonPty type ────────────────────────────────────────────────────────────
# When isDaemon=true:  data socket carries terminal bytes to/from the daemon.
# When isDaemon=false: directPt is used for direct PTY I/O (daemon unavailable).

type DaemonPty* = ref object
  sessionId*: int
  pid*:       int
  masterFd*:  int
  isDaemon*:  bool
  # daemon path
  dataPort:   int
  data:       Socket
  # direct PTY fallback path
  directPt:   Pty

proc shutdownDaemon*() =
  if daemonCtrl == nil: return
  try: discard sendCmd(%*{"cmd": "shutdown"})
  except CatchableError: discard
  daemonCtrl = nil

proc spawnSession*(shell, cwd: string; cols = 80'i32; rows = 24'i32): DaemonPty =
  if daemonCtrl == nil:
    let pt = ptySpawn(shell, @[], cols, rows, cwd)
    return DaemonPty(isDaemon: false, directPt: pt,
                     pid: pt.pid, masterFd: pt.masterFd)
  let resp = sendCmd(%*{"cmd": "spawn", "shell": shell, "cwd": cwd,
                        "cols": cols, "rows": rows})
  if not resp{"ok"}.getBool():
    raise newException(IOError, "daemon spawn: " & resp{"error"}.getStr())
  let id   = resp["sessionId"].getInt()
  let pid  = resp["pid"].getInt()
  let port = resp["dataPort"].getInt()
  var data = newSocket()
  data.connect(DaemonHost, Port(port), timeout = 3000)
  data.getFd().setBlocking(false)
  DaemonPty(isDaemon: true, sessionId: id, pid: pid, masterFd: 0,
            dataPort: port, data: data)

proc attachSession*(sessionId: int): DaemonPty =
  ## Reconnect to an existing daemon session; raises if not found.
  if daemonCtrl == nil:
    raise newException(IOError, "daemon not connected")
  let resp = sendCmd(%*{"cmd": "list"})
  for sess in resp{"sessions"}:
    if sess["id"].getInt() != sessionId: continue
    let pid  = sess["pid"].getInt()
    let port = sess["dataPort"].getInt()
    var data = newSocket()
    data.connect(DaemonHost, Port(port), timeout = 3000)
    data.getFd().setBlocking(false)
    return DaemonPty(isDaemon: true, sessionId: sessionId, pid: pid,
                     masterFd: 0, dataPort: port, data: data)
  raise newException(KeyError, "daemon session not found: " & $sessionId)

proc listDaemonSessions*(): seq[tuple[id, pid: int; cwd: string]] =
  if daemonCtrl == nil: return @[]
  let resp = sendCmd(%*{"cmd": "list"})
  for sess in resp{"sessions"}:
    result.add((id: sess["id"].getInt(), pid: sess["pid"].getInt(),
                cwd: sess["cwd"].getStr()))

# ── DaemonPty interface (mirrors Pty) ─────────────────────────────────────────

proc readAvailable*(dp: DaemonPty; buf: var seq[byte]): int =
  if not dp.isDaemon:
    return dp.directPt.readAvailable(buf)
  if dp.data == nil: return 0
  var chunk: array[4096, byte]
  let n = nativesockets.recv(dp.data.getFd(), cast[cstring](addr chunk[0]), 4096, 0).int
  if n > 0:
    let before = buf.len
    buf.setLen(before + n)
    copyMem(addr buf[before], addr chunk[0], n)
    return n
  0

proc write*(dp: DaemonPty; data: string) =
  if data.len == 0: return
  if not dp.isDaemon:
    dp.directPt.write(data)
  elif dp.data != nil:
    discard nativesockets.send(dp.data.getFd(), cast[cstring](unsafeAddr data[0]), data.len.cint, 0)

proc resize*(dp: DaemonPty; cols, rows: int32) =
  if not dp.isDaemon:
    dp.directPt.resize(cols, rows)
    return
  if daemonCtrl == nil: return
  try:
    discard sendCmd(%*{"cmd": "resize", "sessionId": dp.sessionId,
                       "cols": cols, "rows": rows})
  except CatchableError: discard

proc isAlive*(dp: DaemonPty): bool =
  if not dp.isDaemon:
    return dp.directPt.isAlive()
  if daemonCtrl == nil: return false
  try:
    let resp = sendCmd(%*{"cmd": "alive", "sessionId": dp.sessionId})
    resp{"alive"}.getBool()
  except CatchableError: false

proc currentCwd*(dp: DaemonPty): string =
  if not dp.isDaemon:
    return dp.directPt.currentCwd()
  if daemonCtrl == nil: return ""
  try:
    let resp = sendCmd(%*{"cmd": "cwd", "sessionId": dp.sessionId})
    resp{"cwd"}.getStr("")
  except CatchableError: ""

proc close*(dp: DaemonPty) =
  ## Daemon mode: detach from session (session stays alive in daemon).
  ## Direct mode: close the PTY (process continues running).
  if not dp.isDaemon:
    dp.directPt.close()
    return
  if dp.data != nil:
    try: dp.data.close()
    except CatchableError: discard
    dp.data = nil

proc shellPid*(dp: DaemonPty): int = dp.pid
