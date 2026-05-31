## Integration test: connects to nimmux-daemon, spawns a PTY session, and
## verifies that terminal output is forwarded through the data socket.
##
## Requires nimmux-daemon.exe to be present in the project root.
## The daemon is started once for the suite (and stopped at the end if we
## started it) so tests don't race on port availability between runs.

import std/[json, net, nativesockets, os, osproc, strutils, times, unittest]
import daemon  # for DaemonHost, ControlPort, DataPortBase, isDaemonRunning

when defined(windows):
  const testShell = "cmd.exe"
else:
  const testShell = "/bin/sh"

# ── helpers ───────────────────────────────────────────────────────────────────

proc projectRoot(): string =
  currentSourcePath().parentDir() / ".."

proc daemonExePath(): string =
  projectRoot() / (when defined(windows): "nimmux-daemon.exe" else: "nimmux-daemon")

proc newCtrl(): Socket =
  result = newSocket()
  result.connect(DaemonHost, Port(ControlPort), timeout = 3000)

proc sendCtrl(ctrl: Socket; j: JsonNode): JsonNode =
  ctrl.send($j & "\n")
  var line = ""
  ctrl.readLine(line, timeout = 5000)
  parseJson(line)

proc recvBytes(data: Socket; timeoutMs: int): string =
  ## Drain data socket for up to timeoutMs using raw non-blocking recv.
  data.getFd().setBlocking(false)
  let deadline = getTime() + initDuration(milliseconds = timeoutMs)
  while getTime() < deadline:
    var chunk: array[4096, byte]
    let n = nativesockets.recv(data.getFd(), cast[cstring](addr chunk[0]), 4096, 0).int
    if n > 0:
      result.add(cast[string](chunk[0 ..< n]))
    elif n == 0:
      break  # connection closed
    else:
      os.sleep(10)

proc spawnShell(ctrl: Socket; cmd: string): tuple[id, port: int] =
  ## Ask the daemon to spawn a one-shot shell command; return (sessionId, dataPort).
  let resp = sendCtrl(ctrl, %*{"cmd": "spawn", "shell": cmd,
                                "cwd": "", "cols": 80, "rows": 24})
  doAssert resp["ok"].getBool(), "spawn failed: " & $resp
  (resp["sessionId"].getInt(), resp["dataPort"].getInt())

# ── suite-level daemon lifecycle ──────────────────────────────────────────────

var suiteProc: Process  # non-nil only when THIS test started the daemon

proc ensureDaemon() =
  if isDaemonRunning(): return
  let exe = daemonExePath()
  if not fileExists(exe):
    echo "SKIP: nimmux-daemon binary not found at " & exe
    quit(0)
  suiteProc = startProcess(exe, options = {poDaemon})
  for _ in 0 ..< 40:
    os.sleep(100)
    if isDaemonRunning(): return
  echo "FAIL: daemon did not start within 4 s"
  quit(1)

proc teardownDaemon() =
  if suiteProc != nil:
    try: suiteProc.terminate() except CatchableError: discard
    suiteProc.close()
    suiteProc = nil

# ── suite ─────────────────────────────────────────────────────────────────────

suite "daemon IPC":

  ensureDaemon()

  test "status returns running":
    let ctrl = newCtrl()
    defer: ctrl.close()
    let resp = sendCtrl(ctrl, %*{"cmd": "status"})
    check resp["ok"].getBool()
    check resp["daemon"].getStr() == "running"

  test "spawn returns sessionId and dataPort":
    let ctrl = newCtrl()
    defer: ctrl.close()
    let resp = sendCtrl(ctrl, %*{"cmd": "spawn", "shell": testShell,
                                  "cwd": "", "cols": 80, "rows": 24})
    check resp["ok"].getBool()
    let id = resp["sessionId"].getInt()
    check id >= 0
    check resp["dataPort"].getInt() >= DataPortBase
    discard sendCtrl(ctrl, %*{"cmd": "close", "sessionId": id})

  test "list shows spawned session as alive":
    let ctrl = newCtrl()
    defer: ctrl.close()
    let spawnResp = sendCtrl(ctrl, %*{"cmd": "spawn", "shell": testShell,
                                       "cwd": "", "cols": 80, "rows": 24})
    let id = spawnResp["sessionId"].getInt()
    let listResp = sendCtrl(ctrl, %*{"cmd": "list"})
    check listResp["ok"].getBool()
    var found = false
    for sess in listResp["sessions"]:
      if sess["id"].getInt() == id:
        check sess["alive"].getBool()
        found = true
    check found
    discard sendCtrl(ctrl, %*{"cmd": "close", "sessionId": id})

  test "alive returns true for live session":
    let ctrl = newCtrl()
    defer: ctrl.close()
    let spawnResp = sendCtrl(ctrl, %*{"cmd": "spawn", "shell": testShell,
                                       "cwd": "", "cols": 80, "rows": 24})
    let id = spawnResp["sessionId"].getInt()
    let aliveResp = sendCtrl(ctrl, %*{"cmd": "alive", "sessionId": id})
    check aliveResp["ok"].getBool()
    check aliveResp["alive"].getBool()
    discard sendCtrl(ctrl, %*{"cmd": "close", "sessionId": id})

  test "data socket receives PTY output":
    ## Spawn an interactive shell, connect to the data port, send an echo
    ## command, and verify the output arrives through the daemon's proxy.
    ## We use an interactive shell (not a one-shot command) so it stays
    ## alive while we connect; the daemon's serveData coroutine needs a
    ## moment to accept() our TCP connection before we write.
    let ctrl = newCtrl()
    defer: ctrl.close()

    let (id, port) = spawnShell(ctrl, testShell)
    defer: discard sendCtrl(ctrl, %*{"cmd": "close", "sessionId": id})

    var data = newSocket()
    data.connect(DaemonHost, Port(port), timeout = 3000)
    defer: data.close()

    # Check whether the initial shell prompt arrives (proves data forwarding works).
    let prompt = recvBytes(data, 1500)
    checkpoint "initial prompt bytes: " & $prompt.len

    # Verify the session is still alive before sending input.
    let aliveCheck = sendCtrl(ctrl, %*{"cmd": "alive", "sessionId": id})
    checkpoint "alive before send: " & $aliveCheck["alive"].getBool()

    # Send the echo command and wait for the response.
    when defined(windows):
      data.send("echo nimmux_test_output\r\n")
    else:
      data.send("echo nimmux_test_output\n")

    let output = recvBytes(data, 3000)
    checkpoint "output length: " & $output.len
    check "nimmux_test_output" in output

  test "reconnect: re-attach to existing session after data socket close":
    ## Simulates the session-restore flow: app spawns a session, saves the ID,
    ## closes (data socket dropped), restarts, and re-connects.
    ## The daemon must keep the session alive and accept a new data connection.
    let ctrl = newCtrl()
    defer: ctrl.close()

    # First "app run": spawn a session and disconnect the data socket.
    let (id, port) = spawnShell(ctrl, testShell)
    var data1 = newSocket()
    data1.connect(DaemonHost, Port(port), timeout = 3000)
    discard recvBytes(data1, 500)  # drain initial prompt
    data1.close()                  # simulate app exit

    # Session must still be alive in the daemon.
    let alive = sendCtrl(ctrl, %*{"cmd": "alive", "sessionId": id})
    check alive["alive"].getBool()

    # Second "app run": re-attach using the saved session ID.
    let listResp = sendCtrl(ctrl, %*{"cmd": "list"})
    var found = false
    var foundPort = 0
    for sess in listResp["sessions"]:
      if sess["id"].getInt() == id:
        found = true
        foundPort = sess["dataPort"].getInt()
    check found
    check foundPort == port

    # Re-connect a new data socket to the same port and verify I/O still works.
    var data2 = newSocket()
    data2.connect(DaemonHost, Port(foundPort), timeout = 3000)
    defer: data2.close()
    defer: discard sendCtrl(ctrl, %*{"cmd": "close", "sessionId": id})

    when defined(windows):
      data2.send("echo reconnect_ok\r\n")
    else:
      data2.send("echo reconnect_ok\n")

    let out2 = recvBytes(data2, 3000)
    check "reconnect_ok" in out2

  test "control channel stays responsive while data client is connected":
    ## Regression: on Linux, accepted data sockets were blocking; a stalled
    ## recv in pollPtyOutput would block the event loop and make the control
    ## channel unresponsive. Verify status round-trips in < 500 ms.
    let ctrl = newCtrl()
    defer: ctrl.close()

    let (id, port) = spawnShell(ctrl, testShell)
    defer: discard sendCtrl(ctrl, %*{"cmd": "close", "sessionId": id})

    var data = newSocket()
    data.connect(DaemonHost, Port(port), timeout = 3000)
    defer: data.close()

    # Drain initial prompt so the data socket has no pending bytes.
    discard recvBytes(data, 800)

    # Now hit the control channel; it must respond quickly (not time out).
    let t0 = getTime()
    let resp = sendCtrl(ctrl, %*{"cmd": "status"})
    let elapsed = (getTime() - t0).inMilliseconds
    checkpoint "control response time: " & $elapsed & " ms"
    check resp["ok"].getBool()
    check elapsed < 500

  teardownDaemon()
