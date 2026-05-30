import std/[unittest, os]
import workspace, session

suite "session":
  test "leaf workspace roundtrip":
    let ws = newWorkspace()
    let r = fromJson(ws.toJson())
    check r.root.kind == Leaf
    check r.root.id == 0
    check r.focused == 0

  test "split workspace roundtrip":
    var ws = newWorkspace()
    discard ws.split(0, Vertical)
    let r = fromJson(ws.toJson())
    check r.root.kind == Split
    check r.root.dir == Vertical
    check r.leaves() == @[0, 1]

  test "horizontal split preserved":
    var ws = newWorkspace()
    discard ws.split(0, Horizontal)
    let r = fromJson(ws.toJson())
    check r.root.dir == Horizontal

  test "focused pane preserved":
    var ws = newWorkspace()
    discard ws.split(0, Vertical)
    ws.setFocus(1)
    check fromJson(ws.toJson()).focused == 1

  test "ratio preserved":
    var ws = newWorkspace()
    discard ws.split(0, Vertical)
    ws.root.ratio = 0.3'f32
    check fromJson(ws.toJson()).root.ratio == 0.3'f32

  test "nextId continues correctly after restore":
    var ws = newWorkspace()
    discard ws.split(0, Vertical)     # leaves: 0, 1
    var r = fromJson(ws.toJson())
    check r.split(1, Horizontal) == 2 # next id must be 2

  test "nested split roundtrip":
    var ws = newWorkspace()
    discard ws.split(0, Vertical)
    discard ws.split(1, Horizontal)
    check fromJson(ws.toJson()).leaves() == @[0, 1, 2]

  test "save and load from file":
    var ws = newWorkspace()
    discard ws.split(0, Vertical)
    let path = getTempDir() / "nimmux_test_session.json"
    saveSession(ws, path)
    let loaded = loadSession(path)
    check loaded.leaves() == @[0, 1]
    removeFile(path)

  test "load missing file returns fresh workspace":
    let path = getTempDir() / "nimmux_no_such_session.json"
    discard tryRemoveFile(path)
    let ws = loadSession(path)
    check ws.root.kind == Leaf
    check ws.root.id == 0
