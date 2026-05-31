## Daemon process that manages PTY sessions independently of the main app.
## Allows PTY processes to survive when the main app closes.

import std/[os, json, tables, strutils]
import osproc

type
  DaemonMessage* = object
    cmd*: string
    args*: seq[string]
    sessionId*: int

  PtySession* = ref object
    id*: int
    pid*: int
    masterFd*: int
    cwd*: string
    cols*: int32
    rows*: int32
  
  DaemonState* = ref object
    sessions*: Table[int, PtySession]
    nextId*: int

# Global daemon state
var daemonState*: DaemonState

proc initDaemonState*() =
  if daemonState == nil:
    daemonState = new(DaemonState)
    daemonState.sessions = initTable[int, PtySession]()
    daemonState.nextId = 0

proc getDaemonPath*(): string =
  when defined(windows):
    # Use the same directory as the main executable
    result = getAppDir() & "\\nimmux-daemon.exe"
  else:
    result = getHomeDir() & "/.local/share/nimmux/nimmux-daemon"

proc getDaemonSocketPath*(): string =
  when defined(windows):
    result = getEnv("APPDATA") & "\\nimmux\\ipc.sock"
  else:
    result = getHomeDir() & "/.local/share/nimmux/ipc.sock"

proc ensureDaemonDir*() =
  let path = getDaemonPath()
  let dir = path.parentDir()
  if not dir.dirExists():
    createDir(dir)

proc parseMessage*(data: string): DaemonMessage =
  try:
    let j = parseJson(data)
    result.cmd = j["cmd"].str
    if j.hasKey("args"):
      for arg in j["args"]:
        result.args.add(arg.str)
    if j.hasKey("sessionId"):
      result.sessionId = j["sessionId"].getInt()
  except:
    result.cmd = "error"
    result.args = @[data]

proc handleSpawn*(args: seq[string]): string =
  ## Spawn a new PTY session
  # args: [shell, cwd, cols, rows]
  if args.len < 1:
    return $(%*{"ok": false, "error": "missing shell argument"})
  
  let shell = args[0]
  let cwd = if args.len > 1: args[1] else: ""
  let cols = if args.len > 2: int32(parseInt(args[2])) else: 80'i32
  let rows = if args.len > 3: int32(parseInt(args[3])) else: 24'i32
  
  # Spawn the PTY
  var session = PtySession(
    id: daemonState.nextId,
    pid: 0,
    masterFd: 0,
    cwd: cwd,
    cols: cols,
    rows: rows
  )
  
  try:
    # For now, return the session ID and let main process handle PTY
    # In full implementation, daemon would spawn PTY directly
    let sessionId = daemonState.nextId
    daemonState.nextId.inc
    daemonState.sessions[sessionId] = session
    
    return $(%*{"ok": true, "sessionId": sessionId, "pid": 0})
  except:
    return $(%*{"ok": false, "error": "failed to spawn session"})

proc handleConnect*(sessionIdStr: string): string =
  ## Connect to an existing session
  let sessionId = parseInt(sessionIdStr)
  if not daemonState.sessions.hasKey(sessionId):
    return $(%*{"ok": false, "error": "session not found"})
  
  let session = daemonState.sessions[sessionId]
  return $(%*{
    "ok": true, 
    "sessionId": sessionId,
    "pid": session.pid,
    "cwd": session.cwd,
    "cols": session.cols,
    "rows": session.rows
  })

proc handleList*(): string =
  ## List all PTY sessions
  var sessions = newSeq[JsonNode]()
  for id, session in daemonState.sessions:
    sessions.add(%*{
      "id": id,
      "pid": session.pid,
      "cwd": session.cwd
    })
  result = $(%*{"ok": true, "sessions": sessions})

proc handleStatus*(): string =
  ## Return daemon status
  result = $(%*{"ok": true, "daemon": "running", "sessions": daemonState.sessions.len})

proc daemonMain*() =
  ## Main daemon loop - runs as a separate process
  ## Listens for IPC commands and manages PTY sessions
  initDaemonState()
  
  when defined(windows):
    echo "Daemon starting on Windows..."
    # TODO: Implement Windows named pipe server
    # For now, just keep the process alive
    while true:
      sleep(1000)
  else:
    let socketPath = getDaemonSocketPath()
    if fileExists(socketPath):
      delFile(socketPath)
    
    let server = newSocket(Domain.AF_UNIX, SockType.SOCK_STREAM, Protocol.IPPROTO_IP)
    server.getFd().SocketHandle.bindUnix(socketPath)
    server.listen(5)
    echo "Daemon listening on: " & socketPath
    
    while true:
      try:
        var client: Socket
        var address = ""
        server.acceptAddr(client, address)
        var buf = newString(4096)
        let n = client.recv(buf, 4096)
        if n > 0:
          buf.setLen(n)
          let msg = parseMessage(buf)
          echo "Received command: " & msg.cmd
          let response = case msg.cmd
          of "status": handleStatus()
          of "list": handleList()
          of "spawn": handleSpawn(msg.args)
          of "connect": 
            if msg.args.len > 0: handleConnect(msg.args[0])
            else: $(%*{"ok": false, "error": "missing sessionId"})
          else: $(%*{"ok": false, "error": "unknown command"})
          client.send(response)
        client.close()
      except e:
        echo "Error: " & e.msg

proc spawnDaemon*(): Process =
  ## Spawn the daemon as a background process
  let daemonPath = getDaemonPath()
  if not fileExists(daemonPath):
    return nil
  
  result = startProcess(daemonPath, args = @["--daemon"])

when isMainModule:
  if paramCount() > 0 and paramStr(1) == "--daemon":
    daemonMain()
  else:
    # Check if daemon is already running
    let socketPath = getDaemonSocketPath()
    var daemonRunning = false
    when not defined(windows):
      daemonRunning = fileExists(socketPath)
    
    if not daemonRunning:
      # Spawn daemon
      let daemon = spawnDaemon()
      if daemon != nil:
        echo "Daemon started"
    else:
      echo "Daemon already running"