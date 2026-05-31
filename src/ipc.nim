## IPC socket server.
## Unix domain socket on Linux, named pipe on Windows.
## Allows CLI commands like `nimmux notify` to communicate with running instance.

import std/[os, net, json, monotimes]

when not defined(windows):
  import std/posix

type
  IpcMessage* = object
    cmd*: string
    args*: seq[string]
    timestamp*: int64

  IpcServer* = ref object
    socketPath*: string
    server*: Socket
    running*: bool

proc getIpcPath*(): string =
  when defined(windows):
    result = getEnv("APPDATA") & "\\nimmux\\ipc.sock"
  else:
    result = getHomeDir() & "/.local/share/nimmux/ipc.sock"

proc ensureIpcDir*() =
  let path = getIpcPath()
  let dir = path.parentDir()
  if not dir.existsDir():
    createDir(dir)

proc startIpcServer*(path: string): IpcServer =
  var server = IpcServer(socketPath: path, running: true)
  when defined(windows):
    # TODO: Windows named pipe implementation
    discard
  else:
    if fileExists(path):
      delFile(path)
    server.server = newSocket(Domain.AF_UNIX, SockType.SOCK_STREAM, Protocol.IPPROTO_IP)
    server.server.getFd().SocketHandle.bindUnix(path)
    server.server.listen(5)
  return server

proc stopIpcServer*(server: var IpcServer) =
  server.running = false
  when not defined(windows):
    if server.server != nil:
      server.server.close()
    if fileExists(server.socketPath):
      delFile(server.socketPath)

proc parseMessage*(data: string): IpcMessage =
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
  $(%*{"ok": true, "cmd": "notify"})

proc handleSplit*(msg: IpcMessage): string =
  $(%*{"ok": true, "cmd": "split", "paneId": msg.args[0]})

proc handleCmd*(server: IpcServer; data: string): string =
  let msg = parseMessage(data)
  case msg.cmd
  of "notify": return handleNotify(msg)
  of "split":  return handleSplit(msg)
  else:        return $(%*{"ok": false, "error": "unknown command"})

proc acceptConnections*(server: IpcServer; handler: proc(data: string): string) =
  when defined(windows):
    discard  # TODO: Windows named pipe
  else:
    while server.running:
      try:
        var client: Socket
        var address = ""
        server.server.acceptAddr(client, address)
        var buf = newString(4096)
        let n = client.recv(buf, 4096)
        if n > 0:
          buf.setLen(n)
          let response = handler(buf)
          client.send(response)
        client.close()
      except:
        continue
