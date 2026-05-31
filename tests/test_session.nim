import std/[unittest, os, tables, json]
import workspace, session

suite "session":
  test "leaf workspace roundtrip":
    let ws = newWorkspace()
    let r = fromJson(ws.toJson(ptyStatesEmpty()))
    check r.workspace.root.kind == Leaf
    check r.workspace.root.id == 0
    check r.workspace.focused == 0

  test "split workspace roundtrip":
    var ws = newWorkspace()
    discard ws.split(0, Vertical)
    let r = fromJson(ws.toJson(ptyStatesEmpty()))
    check r.workspace.root.kind == Split
    check r.workspace.root.dir == Vertical
    check r.workspace.leaves() == @[0, 1]

  test "horizontal split preserved":
    var ws = newWorkspace()
    discard ws.split(0, Horizontal)
    let r = fromJson(ws.toJson(ptyStatesEmpty()))
    check r.workspace.root.dir == Horizontal

  test "focused pane preserved":
    var ws = newWorkspace()
    discard ws.split(0, Vertical)
    ws.setFocus(1)
    let r = fromJson(ws.toJson(ptyStatesEmpty()))
    check r.workspace.focused == 1

  test "ratio preserved":
    var ws = newWorkspace()
    discard ws.split(0, Vertical)
    ws.root.ratio = 0.3'f32
    let r = fromJson(ws.toJson(ptyStatesEmpty()))
    check r.workspace.root.ratio == 0.3'f32

  test "nextId continues correctly after restore":
    var ws = newWorkspace()
    discard ws.split(0, Vertical)     # leaves: 0, 1
    var r = fromJson(ws.toJson(ptyStatesEmpty()))
    check r.workspace.split(1, Horizontal) == 2 # next id must be 2

  test "nested split roundtrip":
    var ws = newWorkspace()
    discard ws.split(0, Vertical)
    discard ws.split(1, Horizontal)
    check fromJson(ws.toJson(ptyStatesEmpty())).workspace.leaves() == @[0, 1, 2]

  test "save and load from file":
    var ws = newWorkspace()
    discard ws.split(0, Vertical)
    let path = getTempDir() / "nimmux_test_session.json"
    saveSession(SessionData(workspace: ws, ptyStates: ptyStatesEmpty()), path)
    let loaded = loadSession(path)
    check loaded.workspace.leaves() == @[0, 1]
    removeFile(path)

  test "load missing file returns fresh workspace":
    let path = getTempDir() / "nimmux_no_such_session.json"
    discard tryRemoveFile(path)
    let ws = loadSession(path)
    check ws.workspace.root.kind == Leaf
    check ws.workspace.root.id == 0

  test "pty state roundtrip":
    var ptyStates: Table[int, PtyState] = initTable[int, PtyState]()
    ptyStates[0] = PtyState(pid: 12345, masterFd: 5, cwd: "/home/user")
    ptyStates[1] = PtyState(pid: 67890, masterFd: 7, cwd: "/tmp")
    let json = %*{"focused": 0, "root": {"kind": "leaf", "id": 0}, "ptyStates": ptyStatesToJson(ptyStates)}
    let loaded = fromJson(json)
    check loaded.ptyStates.len == 2
    check loaded.ptyStates[0].pid == 12345
    check loaded.ptyStates[0].cwd == "/home/user"
    check loaded.ptyStates[1].pid == 67890

  test "daemonSessionId zero is preserved (not treated as absent)":
    ## daemonSessionId=0 is a valid session ID; it must survive the roundtrip
    ## as 0, not be coerced to -1. The sentinel for "no daemon session" is -1.
    var ptyStates: Table[int, PtyState] = initTable[int, PtyState]()
    ptyStates[0] = PtyState(pid: 111, masterFd: 3, cwd: "/tmp",
                            daemonSessionId: 0)
    let j = %*{"focused": 0, "root": {"kind": "leaf", "id": 0},
               "ptyStates": ptyStatesToJson(ptyStates)}
    let loaded = fromJson(j)
    check loaded.ptyStates[0].daemonSessionId == 0

  test "daemonSessionId negative one means no daemon session":
    var ptyStates: Table[int, PtyState] = initTable[int, PtyState]()
    ptyStates[0] = PtyState(pid: 222, masterFd: 4, cwd: "/tmp",
                            daemonSessionId: -1)
    let j = %*{"focused": 0, "root": {"kind": "leaf", "id": 0},
               "ptyStates": ptyStatesToJson(ptyStates)}
    let loaded = fromJson(j)
    check loaded.ptyStates[0].daemonSessionId == -1

  test "daemonSessionId absent in JSON defaults to -1":
    ## Old session files may lack the field; treat that as no daemon session.
    let j = %*{"focused": 0, "root": {"kind": "leaf", "id": 0},
               "ptyStates": [{"id": 0, "pid": 333, "masterFd": 5, "cwd": ""}]}
    let loaded = fromJson(j)
    check loaded.ptyStates[0].daemonSessionId == -1

  test "daemonSessionId survives file save/load":
    var ptyStates: Table[int, PtyState] = initTable[int, PtyState]()
    ptyStates[0] = PtyState(pid: 444, masterFd: 6, cwd: "/home",
                            daemonSessionId: 0)
    ptyStates[1] = PtyState(pid: 555, masterFd: 7, cwd: "/tmp",
                            daemonSessionId: 3)
    var ws = newWorkspace()
    discard ws.split(0, Vertical)
    let path = getTempDir() / "nimmux_test_daemon_session.json"
    saveSession(SessionData(workspace: ws, ptyStates: ptyStates), path)
    let loaded = loadSession(path)
    check loaded.ptyStates[0].daemonSessionId == 0
    check loaded.ptyStates[1].daemonSessionId == 3
    removeFile(path)

  test "empty pty states handled":
    let json = %*{"focused": 0, "root": {"kind": "leaf", "id": 0}}
    let loaded = fromJson(json)
    check loaded.ptyStates.len == 0

  test "scrollback preserved across roundtrip":
    var ws = newWorkspace()
    ws.setLeafScrollback(0, "some\x1b[32mcolored\x1b[0m output")
    let r = fromJson(ws.toJson(ptyStatesEmpty()))
    check r.workspace.leafScrollback(0) == "some\x1b[32mcolored\x1b[0m output"

  test "scrollback with raw bytes roundtrip":
    var ws = newWorkspace()
    let raw = "\x00\x01\x1b[2J\xff"
    ws.setLeafScrollback(0, raw)
    check fromJson(ws.toJson(ptyStatesEmpty())).workspace.leafScrollback(0) == raw

  test "scrollback preserved in file save/load":
    var ws = newWorkspace()
    ws.setLeafScrollback(0, "saved scrollback")
    let path = getTempDir() / "nimmux_test_scrollback.json"
    saveSession(SessionData(workspace: ws, ptyStates: ptyStatesEmpty()), path)
    let loaded = loadSession(path)
    check loaded.workspace.leafScrollback(0) == "saved scrollback"
    removeFile(path)
