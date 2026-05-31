## IPC socket server.
## Unix domain socket on Linux, named pipe on Windows.
## Allows CLI commands like `nimmux notify` to communicate with running instance.

import std/[os, net, json, monotimes]

when defined(windows):
  import std/win95
else:
  import std/posix

type
  IpcMessage* = object
    cmd*: string
    args*: seq[string]
    timestamp*: int64

  IpcServer* = ref object
    socketPath*: string
    server*: socket
    running*: bool

proc getIpcPath*(): string =
  ## Get platform-specific IPC socket path
  when defined(windows):
    result = getEnv("APPDATA") & "\\nimmux\\ipc.sock"
  else:
    result = getHomeDir() & "/.local/share/nimmux/ipc.sock"

proc ensureIpcDir*() =
  ## Ensure IPC directory exists
  let path = getIpcPath()
  let dir = path.parentDir()
  if not dir.existsDir():
    createDir(dir)

proc startIpcServer*(path: string): IpcServer =
  ## Start the IPC server
  var server = IpcServer(socketPath: path, running: true)
  
  when defined(windows):
    # Windows: named pipe
    let pipeName = "\\\\.\\pipe\\" & path
    # TODO: Implement named pipe server
    echo "Windows named pipe: ", pipeName
  else:
    # Linux: Unix domain socket
    if fileExists(path):
      delFile(path)
    
    server.server = newSocket()
    server.server.setSockOpt(SOL_SOCKET, SO_REUSEADDR, 1)
    server.server.bind(path, AddressFamily.UNIX)
    server.server.listen(5)
    echo "IPC server listening on: ", path
  
  return server

proc stopIpcServer*(server: var IpcServer) =
  ## Stop the IPC server
  server.running = false
  server.server.close()
  
  when not defined(windows):
    if fileExists(server.socketPath):
      delFile(server.socketPath)

proc parseMessage*(data: string): IpcMessage =
  ## Parse a JSON IPC message
  try:
    let j = parseJson(data)
    result.cmd = j["cmd"].getString()
    if j.hasKey("args"):
      for arg in j["args"]:
        result.args.add(arg.getString())
    result.timestamp = getMonoTime().inMilliseconds()
  except:
    result.cmd = "error"
    result.args = @[data]

proc handleNotify*(msg: IpcMessage): string =
  ## Handle 'notify' command
  ## Format: {"cmd": "notify", "paneId": 1, "body": "text"}
  let j = %*{"ok": true, "cmd": "notify"}
  return $j

proc handleSplit*(msg: IpcMessage): string =
  ## Handle 'split' command
  let j = %*{"ok": true, "cmd": "split", "paneId": msg.args[0]}
  return $j

proc handleCmd*(server: IpcServer; data: string): string =
  ## Handle an IPC command
  let msg = parseMessage(data)
  case msg.cmd
  of "notify": return handleNotify(msg)
  of "split":  return handleSplit(msg)
  else:        return %*{"ok": false, "error": "unknown command"}

proc acceptConnections*(server: IpcServer; handler: proc(data: string): string) =
  ## Accept and handle IPC connections
  while server.running:
    try:
      var client: Socket
      var addr: Address
      
      when defined(windows):
        # Windows named pipe implementation needed
        continue
      else:
        client = server.server.accept(addr)
      
      # Read request
      var buf = newStringOfCap(4096)
      while true:
        let n = client.recv(buf, 4096)
        if n > 0:
          buf.add(n)
        if n <= 0 or buf.len > 0 and buf[^1] == '\n':
          break
      
      # Handle and respond
      let response = handler(buf)
      client.send(response)
      client.close()
    except:
      continue