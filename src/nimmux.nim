## nimmux — terminal multiplexer.
## Ctrl+D           split vertical
## Ctrl+Shift+D     split horizontal
## Ctrl+Shift+]     next pane
## Ctrl+Shift+[     previous pane

import raylib
import std/[tables, os]
import workspace, term, pty, renderer, session

type PaneState = ref object
  trm: Terminal
  pt:  Pty
  buf: seq[byte]

const
  WinW   = 1280
  WinH   = 720
  FontSz = 16'f32

proc defaultShell(): string =
  when defined(windows):
    let c = getEnv("COMSPEC")
    if c.len > 0: c else: "cmd.exe"
  else:
    let s = getEnv("SHELL")
    if s.len > 0: s else: "/bin/sh"

proc main() =
  setConfigFlags(flags(ConfigFlags.VsyncHint, ConfigFlags.WindowResizable))
  initWindow(WinW, WinH, "nimmux")
  setTargetFPS(60)

  let font     = loadTermFont(FontSz.int32)
  let (cw, ch) = cellDims(font, FontSz)
  let initCols = int32(WinW.float32 / cw)
  let initRows = int32(WinH.float32 / ch)
  let shell    = defaultShell()

  var ws          = loadSession()
  var states      = initTable[int, PaneState]()
  var showWelcome = true

  proc onOutput(s: ConstCStr; size: uint64; user: pointer) {.cdecl.} =
    if size == 0: return
    let ps = cast[PaneState](user)
    var data = newString(size.int)
    copyMem(data[0].addr, s, size.int)
    ps.pt.write(data)

  proc addPane(id: int; cols, rows: int32) =
    let ps = PaneState(
      trm: termNew(cols, rows),
      pt:  ptySpawn(shell, @[], cols, rows),
      buf: @[])
    vterm_output_set_callback(ps.trm.vt, onOutput, cast[pointer](ps))
    states[id] = ps

  for id in ws.leaves():
    addPane(id, initCols, initRows)

  while not windowShouldClose():
    let ctrl  = isKeyDown(KeyboardKey.LeftControl)  or isKeyDown(KeyboardKey.RightControl)
    let shift = isKeyDown(KeyboardKey.LeftShift)    or isKeyDown(KeyboardKey.RightShift)

    # split
    if ctrl and isKeyPressed(KeyboardKey.D):
      let dir   = if shift: Horizontal else: Vertical
      let ps    = states[ws.focused]
      let newId = ws.split(ws.focused, dir)
      let ncols = if dir == Vertical:   ps.trm.cols div 2 else: ps.trm.cols
      let nrows = if dir == Horizontal: ps.trm.rows div 2 else: ps.trm.rows
      addPane(newId, ncols, nrows)
      ws.setFocus(newId)
      showWelcome = false

    # cycle focus: Ctrl+Shift+] / Ctrl+Shift+[
    if ctrl and shift:
      let all = ws.leaves()
      if all.len > 1:
        var idx = 0
        for i, id in all:
          if id == ws.focused: idx = i
        if isKeyPressed(KeyboardKey.RightBracket):
          ws.setFocus(all[(idx + 1) mod all.len])
        elif isKeyPressed(KeyboardKey.LeftBracket):
          ws.setFocus(all[(idx - 1 + all.len) mod all.len])

    # special keys → focused terminal
    if isKeyPressed(KeyboardKey.Enter):    states[ws.focused].trm.termSendKey(VTermKey.Enter)
    if isKeyPressed(KeyboardKey.Backspace):states[ws.focused].trm.termSendKey(VTermKey.Backspace)
    if isKeyPressed(KeyboardKey.Escape):   states[ws.focused].trm.termSendKey(VTermKey.Escape)
    if isKeyPressed(KeyboardKey.Up):       states[ws.focused].trm.termSendKey(VTermKey.Up)
    if isKeyPressed(KeyboardKey.Down):     states[ws.focused].trm.termSendKey(VTermKey.Down)
    if isKeyPressed(KeyboardKey.Left):     states[ws.focused].trm.termSendKey(VTermKey.Left)
    if isKeyPressed(KeyboardKey.Right):    states[ws.focused].trm.termSendKey(VTermKey.Right)
    if isKeyPressed(KeyboardKey.Delete):   states[ws.focused].trm.termSendKey(VTermKey.Delete)
    if isKeyPressed(KeyboardKey.Home):     states[ws.focused].trm.termSendKey(VTermKey.Home)
    if isKeyPressed(KeyboardKey.End):      states[ws.focused].trm.termSendKey(VTermKey.End)
    if isKeyPressed(KeyboardKey.PageUp):   states[ws.focused].trm.termSendKey(VTermKey.PageUp)
    if isKeyPressed(KeyboardKey.PageDown): states[ws.focused].trm.termSendKey(VTermKey.PageDown)

    var cp = getCharPressed()
    while cp != 0:
      let mods = if ctrl: VTermModifier.Ctrl else: VTermModifier.None
      states[ws.focused].trm.termSendChar(cp.uint32, mods)
      cp = getCharPressed()
      showWelcome = false

    # read PTY output → libvterm; first output dismisses the welcome overlay
    for id in ws.leaves():
      let ps = states[id]
      let n = ps.pt.readAvailable(ps.buf)
      if n > 0:
        ps.trm.termAdvance(ps.buf.toOpenArray(ps.buf.len - n, ps.buf.len - 1))
        ps.buf.setLen(0)
        showWelcome = false

    # render
    beginDrawing()
    clearBackground(Color(r: 20, g: 20, b: 20, a: 255))
    let sw = getScreenWidth().float32
    let sh = getScreenHeight().float32
    for (id, rect) in ws.leafRects(Rect(x: 0, y: 0, w: sw, h: sh)):
      drawPane(font, cw, ch, states[id].trm, rect, id == ws.focused)
    if showWelcome:
      drawWelcome(font, ch, sw, sh)
    endDrawing()

  saveSession(ws)
  for _, ps in states:
    var p = ps.pt
    p.close()
    var t = ps.trm
    termFree(t)
  closeWindow()

main()
