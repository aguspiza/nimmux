## nimmux PoC — Raylib + libvterm terminal multiplexer.
##
## Ctrl+D          → vertical split
## Ctrl+Shift+D    → horizontal split
## Tab             → cycle focus

import raylib
import vterm, layout, renderer
when defined(windows): import pty_win
else:                   import pty_posix

const
  WinW   = 1280
  WinH   = 720
  FontSz = 16'f32

proc main() =
  setConfigFlags(flags(ConfigFlags.VsyncHint, ConfigFlags.WindowResizable))
  initWindow(WinW, WinH, "nimmux PoC")
  setTargetFPS(60)

  let font       = loadTermFont(FontSz.int32)
  let (cw, ch)   = cellDims(font, FontSz)
  let initCols   = int32(WinW.float32 / cw)
  let initRows   = int32(WinH.float32 / ch)

  var paneCount = 0

  proc greet(p: Pane) =
    inc paneCount
    p.pty.write("echo off\r\n")
    p.pty.write("echo === nimmux PoC  Pane " & $paneCount & " ===\r\n")
    p.pty.write("echo Ctrl+D: vertical split   Ctrl+Shift+D: horizontal split   Tab: cycle focus\r\n")

  var root    = newLeafPane(initCols, initRows)
  var focused = root
  greet(root)

  # wire vterm keyboard output → pty for every pane
  proc onOutput(s: ConstCStr; size: uint64; user: pointer) {.cdecl.} =
    let pane = cast[Pane](user)
    if size > 0:
      var buf = newString(size.int)
      copyMem(buf[0].addr, s, size.int)
      pane.pty.write(buf)

  proc wireOutput(p: Pane) =
    vterm_output_set_callback(p.term.vt, onOutput, cast[pointer](p))

  wireOutput(root)

  while not windowShouldClose():
    let ctrl  = isKeyDown(KeyboardKey.LeftControl)  or isKeyDown(KeyboardKey.RightControl)
    let shift = isKeyDown(KeyboardKey.LeftShift)    or isKeyDown(KeyboardKey.RightShift)

    # ── split ────────────────────────────────────────────────────────────────
    if ctrl and isKeyPressed(KeyboardKey.D):
      let dir     = if shift: Horizontal else: Vertical
      let sibling = splitPane(root, focused, dir)
      wireOutput(sibling)
      greet(sibling)
      focused = sibling

    # ── cycle focus ──────────────────────────────────────────────────────────
    if isKeyPressed(KeyboardKey.Tab) and not ctrl:
      let all = leaves(root)
      if all.len > 1:
        var idx = 0
        for i, p in all:
          if p == focused: idx = i
        focused = all[(idx + 1) mod all.len]

    # ── special keys → focused pane ──────────────────────────────────────────
    if isKeyPressed(KeyboardKey.Enter):    focused.term.sendKey(VTermKey.Enter)
    if isKeyPressed(KeyboardKey.Backspace):focused.term.sendKey(VTermKey.Backspace)
    if isKeyPressed(KeyboardKey.Escape):   focused.term.sendKey(VTermKey.Escape)
    if isKeyPressed(KeyboardKey.Up):       focused.term.sendKey(VTermKey.Up)
    if isKeyPressed(KeyboardKey.Down):     focused.term.sendKey(VTermKey.Down)
    if isKeyPressed(KeyboardKey.Left):     focused.term.sendKey(VTermKey.Left)
    if isKeyPressed(KeyboardKey.Right):    focused.term.sendKey(VTermKey.Right)
    if isKeyPressed(KeyboardKey.Delete):   focused.term.sendKey(VTermKey.Delete)
    if isKeyPressed(KeyboardKey.Home):     focused.term.sendKey(VTermKey.Home)
    if isKeyPressed(KeyboardKey.End):      focused.term.sendKey(VTermKey.End)
    if isKeyPressed(KeyboardKey.PageUp):   focused.term.sendKey(VTermKey.PageUp)
    if isKeyPressed(KeyboardKey.PageDown): focused.term.sendKey(VTermKey.PageDown)

    # printable chars
    var cp = getCharPressed()
    while cp != 0:
      let mods = if ctrl: VTermModifier.Ctrl else: VTermModifier.None
      focused.term.sendChar(cp.uint32, mods)
      cp = getCharPressed()

    # ── read PTY output → feed libvterm ──────────────────────────────────────
    for pane in leaves(root):
      let n = pane.pty.readAvailable(pane.buf)
      if n > 0:
        let lo = pane.buf.len - n
        pane.term.advance(pane.buf.toOpenArray(lo, pane.buf.len - 1))
        pane.buf.setLen(0)

    # ── render ───────────────────────────────────────────────────────────────
    beginDrawing()
    clearBackground(Color(r: 20, g: 20, b: 20, a: 255))

    let sw = getScreenWidth().float32
    let sh = getScreenHeight().float32

    for (pane, rect) in leafRects(root, Rect(x: 0, y: 0, w: sw, h: sh)):
      drawPane(font, cw, ch, pane, rect, pane == focused)

    endDrawing()

  closeAll(root)
  closeWindow()

main()
