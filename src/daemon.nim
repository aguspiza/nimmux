## Daemon process — owns all PTY sessions so they survive GUI restarts.
## Invoked as: nimmux --daemon
## Control channel: TCP 127.0.0.1:31337 (newline-delimited JSON)
## Data channels:   TCP 127.0.0.1:(31338 + sessionId), one per session

import std/[json, net, nativesockets, os, osproc, tables, strutils]
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
    dataServer:  Socket         ## non-blocking listen socket
    dataClients: seq[Socket]    ## non-blocking accepted sockets
    pendingBuf:  string         ## PTY output buffered before first client connects

# ── global daemon state ───────────────────────────────────────────────────────

var sessions = initTable[int, DaemonSession]()
var nextId   = 0

proc defaultShell(): string =
  when defined(windows):
    let c = getEnv("COMSPEC"); if c.len > 0: c else: "cmd.exe"
  else:
    let s = getEnv("SHELL"); if s.len > 0: s else: "/bin/sh"

proc rawSend(c: Socket; s: string) =
  ## Send via raw syscall — bypasses Nim's selectRead quirks on Windows.
  if s.len > 0:
    discard nativesockets.send(c.getFd(), cast[cstring](addr s[0]), s.len.cint, 0)

# ── command handlers ──────────────────────────────────────────────────────────

proc cmdSpawn(j: JsonNode): JsonNode =
  let shell = j{"shell"}.getStr(defaultShell())
  let cwd   = j{"cwd"}.getStr("")
  let cols  = j{"cols"}.getInt(80).int32
  let rows  = j{"rows"}.getInt(24).int32
  let id    = nextId; inc nextId
  let pt    = ptySpawn(shell, @[], cols, rows, cwd)
  var srv   = newSocket()
  srv.setSockOpt(OptReuseAddr, true)
  srv.bindAddr(Port(DataPortBase + id), DaemonHost)
  srv.listen(5)
  srv.getFd().setBlocking(false)
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
  of "spawn":    cmdSpawn(j)
  of "resize":   cmdResize(j)
  of "close":    cmdClose(j)
  of "cwd":      cmdCwd(j)
  of "alive":    cmdAlive(j)
  of "list":     cmdList(j)
  of "status":   cmdStatus(j)
  of "shutdown": %*{"ok": true}
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
    var isShutdown = false
    try:
      let j = parseJson(line.strip())
      resp = dispatch(j{"cmd"}.getStr(""), j)
      isShutdown = j{"cmd"}.getStr("") == "shutdown"
    except CatchableError as e:
      resp = %*{"ok": false, "error": e.msg}
    try:
      await client.send($resp & "\n")
    except CatchableError:
      break
    if isShutdown: quit(0)
  try: client.close()
  except CatchableError: discard

proc serveCtrl(server: AsyncSocket) {.async.} =
  while true:
    let client = await server.accept()
    asyncCheck handleCtrlClient(client)

proc pollPtyOutput() {.async.} =
  while true:
    var deadSessions: seq[int]
    for id, sess in sessions:
      # Accept any newly connected data clients (non-blocking)
      try:
        var client: Socket
        var address = ""
        sess.dataServer.acceptAddr(client, address)
        sess.dataClients.add(client)
        if sess.pendingBuf.len > 0:
          rawSend(client, sess.pendingBuf)
          sess.pendingBuf = ""
      except CatchableError:
        discard  # EWOULDBLOCK — no pending connection

      # Read input from data clients and forward to PTY
      var deadInput: seq[int]
      for i, c in sess.dataClients:
        var buf: array[4096, byte]
        let n = nativesockets.recv(c.getFd(), cast[cstring](addr buf[0]), 4096, 0).int
        if n > 0:
          sess.pt.write(cast[string](buf[0 ..< n]))
        elif n == 0:
          deadInput.add(i)
        # n < 0: WSAEWOULDBLOCK — no data yet
      for i in countdown(deadInput.len - 1, 0):
        try: sess.dataClients[deadInput[i]].close()
        except CatchableError: discard
        sess.dataClients.del(deadInput[i])

      # Read PTY output and forward to data clients
      var ptBuf: seq[byte]
      discard sess.pt.readAvailable(ptBuf)
      if ptBuf.len > 0:
        let s = cast[string](ptBuf)
        if sess.dataClients.len == 0:
          sess.pendingBuf.add(s)
        else:
          var dead: seq[int]
          for i, c in sess.dataClients:
            let sent = nativesockets.send(c.getFd(), cast[cstring](addr s[0]), s.len.cint, 0).int
            if sent < 0:
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
