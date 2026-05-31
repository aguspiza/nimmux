## Daemon process — owns all PTY sessions so they survive GUI restarts.
## Invoked as: nimmux --daemon
## Control channel: TCP 127.0.0.1:31337 (newline-delimited JSON)
## Data channels:   TCP 127.0.0.1:(31338 + sessionId), one per session

import std/[json, net, os, osproc, tables, strutils]
import asyncnet, asyncdispatch
import pty

const
  DaemonHost*   = "127.0.0.1"
  ControlPort*  = 31337
  DataPortBase* = 31338

# ── types ─────────────────────────────────────────────────────────────────────

type
  DaemonSession = ref object
    id:          int
    pt:          Pty
    dataServer:  AsyncSocket
    dataClients: seq[AsyncSocket]

# ── global daemon state ───────────────────────────────────────────────────────

var sessions = initTable[int, DaemonSession]()
var nextId   = 0

proc defaultShell(): string =
  when defined(windows):
    let c = getEnv("COMSPEC"); if c.len > 0: c else: "cmd.exe"
  else:
    let s = getEnv("SHELL"); if s.len > 0: s else: "/bin/sh"

# ── command handlers ──────────────────────────────────────────────────────────

proc cmdSpawn(j: JsonNode): JsonNode =
  let shell = j{"shell"}.getStr(defaultShell())
  let cwd   = j{"cwd"}.getStr("")
  let cols  = j{"cols"}.getInt(80).int32
  let rows  = j{"rows"}.getInt(24).int32
  let id    = nextId; inc nextId
  let pt    = ptySpawn(shell, @[], cols, rows, cwd)
  var srv   = newAsyncSocket()
  srv.setSockOpt(OptReuseAddr, true)
  srv.bindAddr(Port(DataPortBase + id), DaemonHost)
  srv.listen(5)
  sessions[id] = DaemonSession(id: id, pt: pt, dataServer: srv, dataClients: @[])
  %*{"ok": true, "sessionId": id, "pid": pt.pid, "dataPort": DataPortBase + id}

proc cmdResize(j: JsonNode): JsonNode =
  let id   = j{"sessionId"}.getInt(-1)
  let cols = j{"cols"}.getInt(80).int32
  let rows = j{"rows"}.getInt(24).int32
  if id notin sessions: return %*{"ok": false, "error": "not found"}
  sessions[id].pt.resize(cols, rows)
  %*{"ok": true}

proc cmdClose(j: JsonNode): JsonNode =
  let id = j{"sessionId"}.getInt(-1)
  if id notin sessions: return %*{"ok": false, "error": "not found"}
  let sess = sessions[id]
  for c in sess.dataClients:
    try: c.close()
    except CatchableError: discard
  try: sess.dataServer.close()
  except CatchableError: discard
  sess.pt.close()
  sessions.del(id)
  %*{"ok": true}

proc cmdCwd(j: JsonNode): JsonNode =
  let id = j{"sessionId"}.getInt(-1)
  if id notin sessions: return %*{"ok": false, "error": "not found"}
  %*{"ok": true, "cwd": sessions[id].pt.currentCwd()}

proc cmdAlive(j: JsonNode): JsonNode =
  let id = j{"sessionId"}.getInt(-1)
  if id notin sessions: return %*{"ok": false, "alive": false}
  %*{"ok": true, "alive": sessions[id].pt.isAlive()}

proc cmdList(j: JsonNode): JsonNode =
  var arr = newSeq[JsonNode]()
  for id, sess in sessions:
    arr.add(%*{"id": id, "pid": sess.pt.pid, "alive": sess.pt.isAlive(),
               "cwd": sess.pt.currentCwd(), "dataPort": DataPortBase + id})
  %*{"ok": true, "sessions": arr}

proc cmdStatus(j: JsonNode): JsonNode =
  %*{"ok": true, "daemon": "running", "sessions": sessions.len}

proc dispatch(cmd: string; j: JsonNode): JsonNode =
  case cmd
  of "spawn":  cmdSpawn(j)
  of "resize": cmdResize(j)
  of "close":  cmdClose(j)
  of "cwd":    cmdCwd(j)
  of "alive":  cmdAlive(j)
  of "list":   cmdList(j)
  of "status": cmdStatus(j)
  else: %*{"ok": false, "error": "unknown: " & cmd}

# ── async handlers ────────────────────────────────────────────────────────────

proc handleCtrlClient(client: AsyncSocket) {.async.} =
  while true:
    var line = ""
    try:
      line = await client.recvLine()
    except CatchableError:
      break
    if line.len == 0: break
    var resp: JsonNode
    try:
      let j = parseJson(line.strip())
      resp = dispatch(j{"cmd"}.getStr(""), j)
    except CatchableError as e:
      resp = %*{"ok": false, "error": e.msg}
    try:
      await client.send($resp & "\n")
    except CatchableError:
      break
  try: client.close()
  except CatchableError: discard

proc serveCtrl(server: AsyncSocket) {.async.} =
  while true:
    let client = await server.accept()
    asyncCheck handleCtrlClient(client)

proc handleDataClient(id: int; client: AsyncSocket) {.async.} =
  while id in sessions:
    var data = ""
    try:
      data = await client.recv(4096)
    except CatchableError:
      break
    if data.len == 0: break
    if id in sessions:
      sessions[id].pt.write(data)
  try: client.close()
  except CatchableError: discard

proc serveData(sess: DaemonSession) {.async.} =
  while sess.id in sessions:
    var client: AsyncSocket
    try:
      client = await sess.dataServer.accept()
    except CatchableError:
      break
    sess.dataClients.add(client)
    asyncCheck handleDataClient(sess.id, client)

proc pollPtyOutput() {.async.} =
  while true:
    var deadSessions: seq[int]
    for id, sess in sessions:
      var buf: seq[byte]
      discard sess.pt.readAvailable(buf)
      if buf.len > 0:
        let s = cast[string](buf)
        var dead: seq[int]
        for i, c in sess.dataClients:
          try:
            await c.send(s)
          except CatchableError:
            dead.add(i)
        for i in countdown(dead.len - 1, 0):
          try: sess.dataClients[i].close()
          except CatchableError: discard
          sess.dataClients.del(i)
      if not sess.pt.isAlive():
        deadSessions.add(id)
    for id in deadSessions:
      let sess = sessions[id]
      for c in sess.dataClients:
        try: c.close()
        except CatchableError: discard
      try: sess.dataServer.close()
      except CatchableError: discard
      sessions.del(id)
    await sleepAsync(1)

# ── public API ────────────────────────────────────────────────────────────────

proc getDaemonSocketPath*(): string =
  ## Returns path of the daemon PID file (readiness indicator).
  when defined(windows):
    getEnv("APPDATA") / "nimmux" / "daemon.pid"
  else:
    getEnv("HOME") / ".local" / "share" / "nimmux" / "daemon.pid"

proc ensureDaemonDir*() =
  createDir(getDaemonSocketPath().parentDir())

proc spawnDaemon*(): Process =
  ## Spawn the nimmux-daemon binary from the same directory as the running exe.
  ensureDaemonDir()
  let daemonExe = when defined(windows): getAppDir() / "nimmux-daemon.exe"
                  else: getAppDir() / "nimmux-daemon"
  if not fileExists(daemonExe): return nil
  startProcess(daemonExe, options = {poDaemon})

proc isDaemonRunning*(): bool =
  ## Probe by attempting a TCP connection to the control port.
  try:
    var s = newSocket()
    defer: s.close()
    s.connect(DaemonHost, Port(ControlPort), timeout = 200)
    true
  except CatchableError: false

proc daemonMain*() =
  ensureDaemonDir()
  writeFile(getDaemonSocketPath(), $getCurrentProcessId())

  var ctrlServer = newAsyncSocket()
  ctrlServer.setSockOpt(OptReuseAddr, true)
  ctrlServer.bindAddr(Port(ControlPort), DaemonHost)
  ctrlServer.listen(20)

  asyncCheck serveCtrl(ctrlServer)
  asyncCheck pollPtyOutput()
  runForever()
