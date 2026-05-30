import std/unittest
import workspace

suite "workspace":
  test "new workspace has one leaf":
    let ws = newWorkspace()
    check ws.root.kind == Leaf
    check ws.root.id == 0
    check ws.leaves() == @[0]

  test "split returns new pane id":
    var ws = newWorkspace()
    let newId = ws.split(0, Vertical)
    check newId == 1

  test "split vertical creates Split node with two leaves":
    var ws = newWorkspace()
    discard ws.split(0, Vertical)
    check ws.root.kind == Split
    check ws.root.dir == Vertical
    check ws.leaves() == @[0, 1]

  test "split horizontal":
    var ws = newWorkspace()
    discard ws.split(0, Horizontal)
    check ws.root.kind == Split
    check ws.root.dir == Horizontal

  test "ratio defaults to 0.5":
    var ws = newWorkspace()
    discard ws.split(0, Vertical)
    check ws.root.ratio == 0.5'f32

  test "nested split":
    var ws = newWorkspace()
    discard ws.split(0, Vertical)   # [0 | 1]
    discard ws.split(1, Horizontal) # [0 | (1 / 2)]
    check ws.leaves() == @[0, 1, 2]

  test "close right pane collapses to left":
    var ws = newWorkspace()
    discard ws.split(0, Vertical)  # [0 | 1]
    ws.close(1)
    check ws.root.kind == Leaf
    check ws.root.id == 0

  test "close left pane collapses to right":
    var ws = newWorkspace()
    discard ws.split(0, Vertical)  # [0 | 1]
    ws.close(0)
    check ws.root.kind == Leaf
    check ws.root.id == 1

  test "close focused pane moves focus to remaining leaf":
    var ws = newWorkspace()
    discard ws.split(0, Vertical)
    ws.setFocus(1)
    ws.close(1)
    check ws.focused == 0

  test "close nested leaf":
    var ws = newWorkspace()
    discard ws.split(0, Vertical)   # [0 | 1]
    discard ws.split(1, Horizontal) # [0 | (1 / 2)]
    ws.close(1)
    check ws.leaves() == @[0, 2]

  test "close only pane is no-op":
    var ws = newWorkspace()
    ws.close(0)
    check ws.root.kind == Leaf
    check ws.root.id == 0
