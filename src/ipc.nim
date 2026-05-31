## IPC client for communicating with the daemon

import std/[os, json, osproc, strutils]

type
  IpcClient* = ref object of RootObj

proc connectToDaemon*(): IpcClient =
  ## Connect to the daemon and return a client
  new(result)

proc sendCommand*(client: IpcClient; cmd: string; args: seq[string] = @[]): string =
  ## Send a command to the daemon and return the response
  when defined(windows):
    # Windows: Use named pipes
    # TODO: Implement Windows named pipe client
    return $(%*{"ok": false, "error": "Windows IPC not implemented"})
  else:
    # POSIX: Use Unix domain socket
    let socketPath = getDaemonSocketPath()
    if not fileExists(socketPath):
      return $(%*{"ok": false, "error": "daemon not running"})
    
    # Create socket and connect
    var addr: sockaddr_un
    addr.sun_family = AF_UNIX
    let pathBytes = socketPath.toUnixPath()
    copyMem(addr.sun_path, pathBytes, min(pathBytes.len, sizeof(addr.sun_path)))
    
    let sock = socket(AF_UNIX, SOCK_STREAM, 0)
    if sock < 0:
      return $(%*{"ok": false, "error": "socket creation failed"})
    
    if connect(sock, cast[ptr sockaddr](addr.addr), sizeof(addr).socklen_t) < 0:
      close(sock)
      return $(%*{"ok": false, "error": "connect failed"})
    
    # Send message
    let msg = %*{"cmd": cmd, "args": args}
    let msgStr = $msg
    let msgLen = msgStr.len
    discard send(sock, msgStr[0].unsafeAddr, msgLen.DWORD, 0)
    
    # Receive response
    var buf: array[4096, byte]
    let n = recv(sock, buf[0].unsafeAddr, 4096.DWORD, 0)
    close(sock)
    
    if n > 0:
      result = $parseJson(cast[string](buf[0..<n]))
    else:
      result = $(%*{"ok": false, "error": "no response"})

proc getDaemonSocketPath*(): string =
  when defined(windows):
    result = getEnv("APPDATA") & "\\nimmux\\ipc.sock"
  else:
    result = getHomeDir() & "/.local/share/nimmux/ipc.sock"