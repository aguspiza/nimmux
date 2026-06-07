## nimmux — terminal multiplexer.
## Ctrl+D           split vertical
## Ctrl+Shift+D     split horizontal
## Ctrl+Shift+]     next pane
## Ctrl+Shift+[     previous pane
## Ctrl+W           close pane
## Ctrl+=           increase font size
## Ctrl+-           decrease font size
## Ctrl+F           zoom focused pane (toggle)

import raylib
import std/[tables, os, osproc, streams, strutils, times]
import workspace, term, renderer, session, daemon, ipc

const
  SidebarWidth  = 200.0'f32
  CacheInterval = 3.0  # seconds between background subprocess refreshes

type PaneState = ref object
  trm:      Terminal
  pt:       DaemonPty
  buf:      seq[byte]
  fontSize: float32

const
  WinW     = 1280
  WinH     = 720
  FontSz   = 16'f32   ## default per-pane font size
  FontMin  = 8'f32
  FontMax  = 32'f32
  FontStep = 2'f32
  BaseFontSz = 32'i32 ## load atlas at 2× default size; bilinear handles the 2× downscale cleanly

proc defaultShell(): string =
  when defined(windows):
    let c = getEnv("COMSPEC")
    if c.len > 0: c else: "cmd.exe"
  else:
    let s = getEnv("SHELL")
    if s.len > 0: s else: "/bin/sh"

# ── git branch (non-blocking per-cwd) ─────────────────────────────────────────

var gitBranchCache = initTable[string, tuple[branch: string; t: float]]()
var gitProcs       = initTable[string, Process]()

proc getGitBranch(cwd: string): string =
  if cwd.len == 0: return ""
  let now = epochTime()
  if cwd in gitProcs:
    let p = gitProcs[cwd]
    if p.peekExitCode() != -1:
      var branch = p.outputStream.readAll().strip()
      p.close()
      gitProcs.del(cwd)
      if branch == "HEAD": branch = ""
      gitBranchCache[cwd] = (branch: branch, t: now)
  if cwd in gitBranchCache:
    result = gitBranchCache[cwd].branch
    if now - gitBranchCache[cwd].t >= CacheInterval and cwd notin gitProcs:
      try:
        gitProcs[cwd] = startProcess("git",
          args = ["-C", cwd, "rev-parse", "--abbrev-ref", "HEAD"],
          options = {poUsePath, poStdErrToStdOut, poDaemon})
      except: discard
  elif cwd notin gitProcs:
    try:
      gitProcs[cwd] = startProcess("git",
        args = ["-C", cwd, "rev-parse", "--abbrev-ref", "HEAD"],
        options = {poUsePath, poStdErrToStdOut, poDaemon})
    except: discard

# ── port detection (non-blocking) ─────────────────────────────────────────────

when defined(windows):
  var winNetstatOut  = ""
  var winNetstatTime = epochTime()  # defer first run by CacheInterval
  var winNetstatProc: Process

  var winParentOf    = initTable[int, int]()  # pid → parent pid
  var winProcMapTime = epochTime()  # defer first run by CacheInterval
  var winProcMapProc: Process

  proc pollWinNetstat() =
    if winNetstatProc != nil and winNetstatProc.peekExitCode() != -1:
      winNetstatOut  = winNetstatProc.outputStream.readAll()
      winNetstatProc.close()
      winNetstatProc = nil
      winNetstatTime = epochTime()
    if winNetstatProc == nil and epochTime() - winNetstatTime >= CacheInterval:
      try:
        winNetstatProc = startProcess("netstat.exe", args = ["-ano"],
                                      options = {poUsePath, poStdErrToStdOut, poDaemon})
      except: discard

  proc pollWinProcMap() =
    if winProcMapProc != nil and winProcMapProc.peekExitCode() != -1:
      let csv = winProcMapProc.outputStream.readAll()
      winProcMapProc.close()
      winProcMapProc = nil
      winParentOf.clear()
      for line in csv.splitLines():
        let s = line.strip()
        if s.len == 0 or s.startsWith("Node"): continue
        let parts = s.split(',')
        if parts.len < 3: continue
        let ppid = try: parseInt(parts[1].strip()) except: continue
        let pid  = try: parseInt(parts[2].strip()) except: continue
        winParentOf[pid] = ppid
      winProcMapTime = epochTime()
    if winProcMapProc == nil and epochTime() - winProcMapTime >= CacheInterval:
      try:
        winProcMapProc = startProcess("wmic",
          args = ["process", "get", "ProcessId,ParentProcessId", "/format:csv"],
          options = {poUsePath, poStdErrToStdOut, poDaemon})
      except: discard

  proc isInFamily(pid, rootPid: int): bool =
    var cur = pid
    for _ in 0 ..< 20:
      if cur == rootPid: return true
      let p = winParentOf.getOrDefault(cur, -1)
      if p <= 0 or p == cur: return false
      cur = p

else:
  var ssCacheOutput = ""
  var ssCacheTime   = epochTime()  # defer first run by CacheInterval
  var ssProc: Process

  proc pollSsCache() =
    if ssProc != nil and ssProc.peekExitCode() != -1:
      ssCacheOutput = ssProc.outputStream.readAll()
      ssProc.close()
      ssProc = nil
      ssCacheTime = epochTime()
    if ssProc == nil and epochTime() - ssCacheTime >= CacheInterval:
      try:
        ssProc = startProcess("ss", args = ["-Htlnp"],
                              options = {poUsePath, poStdErrToStdOut})
      except: discard

  proc sessionId(pid: int): int =
    let data = try: readFile("/proc/" & $pid & "/stat") except: return -1
    let rp = data.rfind(')')
    if rp < 0: return -1
    let fields = data[rp + 2 .. ^1].splitWhitespace()
    if fields.len < 4: return -1
    try: parseInt(fields[3]) except: -1

proc getPanePorts(pt: DaemonPty): seq[string] =
  when defined(windows):
    let shellPid = pt.shellPid()
    if shellPid == 0: return @[]
    for line in winNetstatOut.splitLines():
      if "LISTENING" notin line: continue
      let parts = line.splitWhitespace()
      if parts.len < 5: continue
      let pid = try: parseInt(parts[4]) except: continue
      if pid != shellPid and not isInFamily(pid, shellPid): continue
      let colon = parts[1].rfind(':')
      if colon < 0: continue
      let port = parts[1][colon + 1 .. ^1]
      if port.len > 0 and port notin result:
        result.add(port)
  else:
    let sid = sessionId(pt.pid.int)
    if sid <= 0: return @[]
    for line in ssCacheOutput.splitLines():
      if "pid=" notin line: continue
      let pidStart = line.find("pid=")
      let afterPid = line[pidStart + 4 .. ^1]
      let endIdx = afterPid.find({',', ')'})
      if endIdx < 0: continue
      let procPid = try: parseInt(afterPid[0 ..< endIdx]) except: continue
      if sessionId(procPid) != sid: continue
      let parts = line.splitWhitespace()
      if parts.len < 4: continue
      let colon = parts[3].rfind(':')
      if colon < 0: continue
      let port = parts[3][colon + 1 .. ^1]
      if port.len > 0 and port != "*" and port notin result:
        result.add(port)

proc main() =
  # Start daemon for PTY persistence. Wait up to 500ms for it to be ready.
  var daemonWasRunning = false
  try:
    daemonWasRunning = isDaemonRunning()
    if not daemonWasRunning:
      discard spawnDaemon()
      for _ in 0 ..< 5:  # wait up to 500ms
        os.sleep(100)
        if isDaemonRunning(): break
    connectDaemon()  # 500ms timeout, non-fatal on failure
  except CatchableError:
    discard

  setTraceLogLevel(TraceLogLevel.Error)
  setConfigFlags(flags(ConfigFlags.VsyncHint, ConfigFlags.WindowResizable))
  initWindow(WinW, WinH, "nimmux")
  defer: closeWindow()
  setTargetFPS(60)

  var fonts            = loadTermFont(BaseFontSz)
  let (initCw, initCh) = cellDims(fonts.primary, FontSz)
  let initCols         = int32(WinW.float32 / initCw)
  let initRows         = int32(WinH.float32 / initCh)
  let shell            = defaultShell()

  var sessionData = loadSession()
  # Only restore the saved layout when reconnecting; a fresh daemon has no
  # live sessions to attach to, so restoring a split just spawns N identical shells.
  if not daemonWasRunning:
    sessionData = SessionData(workspace: newWorkspace(),
                              ptyStates: ptyStatesEmpty())
  var ws = sessionData.workspace
  var states      = initTable[int, PaneState]()
  var showWelcome = not daemonWasRunning
  var sidebar     = initSidebar(SidebarWidth)

  proc onOutput(s: ConstCStr; size: uint64; user: pointer) {.cdecl.} =
    if size == 0: return
    let ps = cast[PaneState](user)
    var data = newString(size.int)
    copyMem(data[0].addr, s, size.int)
    ps.pt.write(data)

  proc addPane(id: int; cols, rows: int32; cwd = ""; fontSize = FontSz;
               savedDaemonId = -1) =
    var pt: DaemonPty
    if savedDaemonId >= 0:
      try: pt = attachSession(savedDaemonId)
      except: pt = spawnSession(shell, cwd, cols, rows)
    else:
      pt = spawnSession(shell, cwd, cols, rows)
    let ps = PaneState(trm: termNew(cols, rows), pt: pt, buf: @[], fontSize: fontSize)
    vterm_output_set_callback(ps.trm.vt, onOutput, cast[pointer](ps))
    states[id] = ps

  proc reflowPane(id: int) =
    let sw = getScreenWidth().float32
    let sh = getScreenHeight().float32
    for (pid, rect) in ws.leafRects(Rect(x: 0, y: 0, w: sw, h: sh)):
      if pid == id:
        let (cw, ch) = cellDims(fonts.primary, states[id].fontSize)
        let ncols = max(1'i32, int32(rect.w / cw))
        let nrows = max(1'i32, int32(rect.h / ch))
        states[id].trm.termResize(ncols, nrows)
        states[id].pt.resize(ncols, nrows)
        break

  for id in ws.leaves():
    let saved = sessionData.ptyStates.getOrDefault(id, PtyState())
    addPane(id, initCols, initRows, saved.cwd,
            savedDaemonId = if saved.daemonSessionId >= 0: saved.daemonSessionId else: -1)

  var selPane      = -1
  var selDragging  = false
  var selActive    = false
  var selRect      = Rect()
  var selCellW     = 0.0'f32
  var selCellH     = 0.0'f32
  var selStartRow  = 0
  var selStartCol  = 0
  var selEndRow    = 0
  var selEndCol    = 0

  proc pixelToCell(pos: Vector2; rect: Rect; cw, ch: float32): (int, int) =
    (int((pos.y - rect.y) / ch), int((pos.x - rect.x) / cw))

  proc normalizeSel(r1, c1, r2, c2: int): SelectionRange =
    if r1 < r2 or (r1 == r2 and c1 <= c2):
      SelectionRange(active: true, r1: r1, c1: c1, r2: r2, c2: c2)
    else:
      SelectionRange(active: true, r1: r2, c1: c2, r2: r1, c2: c1)

  var shouldQuit      = false
  var shellsExited    = false
  var zoomed          = false
  var prevZoomed      = false
  var sidebarExpanded = true
  var prevSidebarExpanded = true
  var prevW           = 0.0'f32
  var prevH           = 0.0'f32
  var ipcTick         = 0
  var dirty           = true   # first frame always renders
  var lastRenderTime  = 0.0    # epochTime of last render (for cursor blink)
  var prevMousePos    = getMousePosition()

  while not windowShouldClose() and not shouldQuit:
    # pollInputEvents() is called either by endDrawing() (dirty frames) or
    # explicitly below (non-dirty frames). Never both — double-call advances
    # previousKeyState twice and loses key presses.
    inc ipcTick

    let ctrl  = isKeyDown(KeyboardKey.LeftControl)  or isKeyDown(KeyboardKey.RightControl)
    let shift = isKeyDown(KeyboardKey.LeftShift)    or isKeyDown(KeyboardKey.RightShift)

    # mark dirty on any keyboard or mouse input
    if getKeyPressed() != KeyboardKey.Null or
       isMouseButtonPressed(MouseButton.Left) or isMouseButtonReleased(MouseButton.Left) or
       isMouseButtonPressed(MouseButton.Right) or isMouseButtonReleased(MouseButton.Right) or
       isMouseButtonPressed(MouseButton.Middle):
      dirty = true
    let curMousePos = getMousePosition()
    if curMousePos.x != prevMousePos.x or curMousePos.y != prevMousePos.y:
      dirty = true
      prevMousePos = curMousePos

    # split
    if ctrl and isKeyPressed(KeyboardKey.D):
      let dir      = if shift: Horizontal else: Vertical
      let focusFs  = states[ws.focused].fontSize
      let ps       = states[ws.focused]
      let newId    = ws.split(ws.focused, dir)
      let ncols    = if dir == Vertical:   ps.trm.cols div 2 else: ps.trm.cols
      let nrows    = if dir == Horizontal: ps.trm.rows div 2 else: ps.trm.rows
      addPane(newId, ncols, nrows, fontSize = focusFs)
      ws.setFocus(newId)
      showWelcome = false

    # close focused pane: Ctrl+W
    if ctrl and isKeyPressed(KeyboardKey.W):
      let id = ws.focused
      if ws.leaves().len == 1:
        shouldQuit = true
      else:
        sidebar.removePaneInfo(id)
        termFree(states[id].trm)
        # NOTE: NOT closing PTY - processes continue running in background
        # This allows session restore to reconnect to existing processes
        states.del(id)
        ws.close(id)

    # zoom focused pane: Ctrl+F toggles full-screen for the active pane
    if ctrl and isKeyPressed(KeyboardKey.F):
      zoomed = not zoomed

    # toggle sidebar: Ctrl+Shift+S
    if ctrl and shift and isKeyPressed(KeyboardKey.S):
      sidebarExpanded = not sidebarExpanded

    # font size: Ctrl+= increase  Ctrl+- decrease
    if ctrl and isKeyPressed(KeyboardKey.Equal):
      states[ws.focused].fontSize = min(FontMax, states[ws.focused].fontSize + FontStep)
      reflowPane(ws.focused)
    if ctrl and isKeyPressed(KeyboardKey.Minus):
      states[ws.focused].fontSize = max(FontMin, states[ws.focused].fontSize - FontStep)
      reflowPane(ws.focused)

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

    # special keys → focused terminal (initial press + OS repeat)
    template termKey(k: KeyboardKey; v: VTermKey) =
      if isKeyPressed(k) or isKeyPressedRepeat(k):
        states[ws.focused].trm.termSendKey(v)
    termKey KeyboardKey.Enter,    VTermKey.Enter
    termKey KeyboardKey.Backspace,VTermKey.Backspace
    termKey KeyboardKey.Escape,   VTermKey.Escape
    termKey KeyboardKey.Up,       VTermKey.Up
    termKey KeyboardKey.Down,     VTermKey.Down
    termKey KeyboardKey.Left,     VTermKey.Left
    termKey KeyboardKey.Right,    VTermKey.Right
    termKey KeyboardKey.Delete,   VTermKey.Delete
    termKey KeyboardKey.Home,     VTermKey.Home
    termKey KeyboardKey.End,      VTermKey.End
    termKey KeyboardKey.PageUp,   VTermKey.PageUp
    termKey KeyboardKey.PageDown, VTermKey.PageDown
    if isKeyPressed(KeyboardKey.Tab) or isKeyPressedRepeat(KeyboardKey.Tab):
      states[ws.focused].pt.write("\t")
      showWelcome = false

    var cp = getCharPressed()
    while cp != 0:
      let mods = if ctrl: VTermModifier.Ctrl else: VTermModifier.None
      states[ws.focused].trm.termSendChar(cp.uint32, mods)
      cp = getCharPressed()
      showWelcome = false

    # Raylib filters control chars from GetCharPressed, so Ctrl+letter
    # combinations never appear there. Send the raw byte directly.
    # D(split), F(zoom), W(close) are reserved by nimmux.
    if ctrl and not shift:
      template ctrlKey(k: KeyboardKey; b: int) =
        if isKeyPressed(k) or isKeyPressedRepeat(k):
          states[ws.focused].pt.write($char(b))
          showWelcome = false
      ctrlKey KeyboardKey.A,  1
      ctrlKey KeyboardKey.B,  2
      ctrlKey KeyboardKey.C,  3  # SIGINT
      ctrlKey KeyboardKey.E,  5
      ctrlKey KeyboardKey.G,  7
      ctrlKey KeyboardKey.H,  8
      ctrlKey KeyboardKey.J, 10
      ctrlKey KeyboardKey.K, 11
      ctrlKey KeyboardKey.L, 12  # clear screen
      ctrlKey KeyboardKey.M, 13
      ctrlKey KeyboardKey.N, 14
      ctrlKey KeyboardKey.O, 15
      ctrlKey KeyboardKey.P, 16
      ctrlKey KeyboardKey.Q, 17
      ctrlKey KeyboardKey.R, 18  # reverse search
      ctrlKey KeyboardKey.S, 19
      ctrlKey KeyboardKey.T, 20
      ctrlKey KeyboardKey.U, 21
      ctrlKey KeyboardKey.V, 22
      ctrlKey KeyboardKey.X, 24
      ctrlKey KeyboardKey.Y, 25
      ctrlKey KeyboardKey.Z, 26  # SIGTSTP

    # read PTY output → libvterm
    for id in ws.leaves():
      let ps = states[id]
      let n = ps.pt.readAvailable(ps.buf)
      if n > 0:
        ps.trm.termAdvance(ps.buf.toOpenArray(ps.buf.len - n, ps.buf.len - 1))
        ps.buf.setLen(0)
        ps.trm.termScrollReset()
        dirty = true

    # close panes whose shell has exited (IPC check ~1 Hz)
    var deadPanes: seq[int]
    if ipcTick mod 60 == 0:
      for id in ws.leaves():
        if not states[id].pt.isAlive():
          deadPanes.add(id)
    for id in deadPanes:
      if ws.leaves().len == 1:
        shouldQuit   = true
        shellsExited = true
        break
      termFree(states[id].trm)
      states[id].pt.close()
      states.del(id)
      ws.close(id)
      dirty = true

    # poll background subprocesses (never blocks)
    when defined(windows):
      pollWinNetstat()
      pollWinProcMap()
    else:
      pollSsCache()

    # update sidebar info (~1 Hz to avoid IPC on every frame)
    let curW = getScreenWidth().float32
    let curH = getScreenHeight().float32
    let sidebarW = if sidebarExpanded: SidebarWidth else: 0.0'f32
    if ipcTick mod 60 == 0:
      for id in ws.leaves():
        let cwd = states[id].pt.currentCwd()
        let branch = getGitBranch(cwd)
        let ports = getPanePorts(states[id].pt)
        sidebar.updatePaneInfo(id, cwd, branch, ports, 0)
      dirty = true  # sidebar info refreshed

    # scroll wheel: scroll the pane under the mouse
    let pArea = Rect(x: sidebarW, y: 0, w: curW - sidebarW, h: curH)
    let wheel = getMouseWheelMove()
    if wheel != 0:
      var scrollTarget = -1
      if zoomed:
        scrollTarget = ws.focused
      else:
        for (id, rect) in ws.leafRects(pArea):
          if curMousePos.x >= rect.x and curMousePos.x < rect.x + rect.w and
             curMousePos.y >= rect.y and curMousePos.y < rect.y + rect.h:
            scrollTarget = id
            break
      if scrollTarget >= 0 and scrollTarget in states:
        states[scrollTarget].trm.termScroll(int(wheel) * 3)
        dirty = true

    # selection: left-button drag → copy text to clipboard on release
    if isMouseButtonPressed(MouseButton.Left):
      selActive = false
      selDragging = false
      if zoomed:
        let id = ws.focused
        if id in states:
          let (cw, ch) = cellDims(fonts.primary, states[id].fontSize)
          let rect = Rect(x: sidebarW, y: 0, w: curW - sidebarW, h: curH)
          let (row, col) = pixelToCell(curMousePos, rect, cw, ch)
          selPane = id; selRect = rect; selCellW = cw; selCellH = ch
          selStartRow = clamp(row, 0, states[id].trm.rows.int - 1)
          selStartCol = clamp(col, 0, states[id].trm.cols.int - 1)
          selEndRow = selStartRow; selEndCol = selStartCol
          selDragging = true
      else:
        for (id, rect) in ws.leafRects(pArea):
          if curMousePos.x >= rect.x and curMousePos.x < rect.x + rect.w and
             curMousePos.y >= rect.y and curMousePos.y < rect.y + rect.h:
            let (cw, ch) = cellDims(fonts.primary, states[id].fontSize)
            let (row, col) = pixelToCell(curMousePos, rect, cw, ch)
            selPane = id; selRect = rect; selCellW = cw; selCellH = ch
            selStartRow = clamp(row, 0, states[id].trm.rows.int - 1)
            selStartCol = clamp(col, 0, states[id].trm.cols.int - 1)
            selEndRow = selStartRow; selEndCol = selStartCol
            selDragging = true
            break

    if selDragging and isMouseButtonDown(MouseButton.Left) and selPane in states:
      let (row, col) = pixelToCell(curMousePos, selRect, selCellW, selCellH)
      let r = clamp(row, 0, states[selPane].trm.rows.int - 1)
      let c = clamp(col, 0, states[selPane].trm.cols.int - 1)
      if r != selEndRow or c != selEndCol:
        selEndRow = r; selEndCol = c; dirty = true

    if isMouseButtonReleased(MouseButton.Left) and selDragging:
      selDragging = false
      let sel = normalizeSel(selStartRow, selStartCol, selEndRow, selEndCol)
      if (sel.r1 != sel.r2 or sel.c1 != sel.c2) and selPane in states:
        let text = termGetText(states[selPane].trm, sel.r1, sel.c1, sel.r2, sel.c2)
        if text.strip().len > 0:
          setClipboardText(text)
          selActive = true

    # clear selection on any keystroke
    if getKeyPressed() != KeyboardKey.Null:
      selActive = false; selDragging = false

    # middle mouse button: paste clipboard into focused pane
    if isMouseButtonPressed(MouseButton.Middle):
      let clip = getClipboardText()
      if clip.len > 0:
        states[ws.focused].pt.write(clip)
        showWelcome = false

    # reflow on window resize, sidebar toggle, or zoom toggle
    if curW != prevW or curH != prevH or sidebarExpanded != prevSidebarExpanded or zoomed != prevZoomed:
      dirty = true
      prevW = curW; prevH = curH; prevSidebarExpanded = sidebarExpanded; prevZoomed = zoomed
      let paneW = curW - sidebarW
      if zoomed:
        let id = ws.focused
        let (cw, ch) = cellDims(fonts.primary, states[id].fontSize)
        let ncols = max(1'i32, int32(paneW / cw))
        let nrows = max(1'i32, int32(curH / ch))
        states[id].trm.termResize(ncols, nrows)
        states[id].pt.resize(ncols, nrows)
      else:
        for (id, rect) in ws.leafRects(Rect(x: sidebarW, y: 0, w: paneW, h: curH)):
          let (cw, ch) = cellDims(fonts.primary, states[id].fontSize)
          let ncols = max(1'i32, int32(rect.w / cw))
          let nrows = max(1'i32, int32(rect.h / ch))
          states[id].trm.termResize(ncols, nrows)
          states[id].pt.resize(ncols, nrows)

    # cursor blink: force a redraw every 500 ms even when otherwise idle
    let now = epochTime()
    if now - lastRenderTime >= 0.5:
      dirty = true

    if dirty:
      dirty = false
      lastRenderTime = epochTime()
      beginDrawing()
      clearBackground(Color(r: 20, g: 20, b: 20, a: 255))
      let sw = getScreenWidth().float32
      let sh = getScreenHeight().float32
      let paneW = sw - sidebarW
      if zoomed:
        let id = ws.focused
        let zSel = if (selDragging or selActive) and id == selPane:
                     normalizeSel(selStartRow, selStartCol, selEndRow, selEndCol)
                   else: SelectionRange()
        drawPane(fonts, states[id].fontSize, states[id].trm,
                 Rect(x: sidebarW, y: 0, w: paneW, h: sh), true, zSel)
      else:
        for (id, rect) in ws.leafRects(Rect(x: sidebarW, y: 0, w: paneW, h: sh)):
          let pSel = if (selDragging or selActive) and id == selPane:
                       normalizeSel(selStartRow, selStartCol, selEndRow, selEndCol)
                     else: SelectionRange()
          drawPane(fonts, states[id].fontSize, states[id].trm, rect, id == ws.focused, pSel)
      if sidebarExpanded:
        let clickedPane = drawSidebar(fonts.primary, initCh, Rect(x: 0, y: 0, w: sidebarW, h: sh), sidebar, ws.focused)
        if clickedPane != -1 and clickedPane in states:
          ws.setFocus(clickedPane)
          showWelcome = false
          dirty = true
      if showWelcome:
        drawWelcome(fonts.primary, initCh, sw, sh)
      endDrawing()
    else:
      pollInputEvents()  # advance input state when skipping endDrawing
      waitTime(0.002)    # 2 ms — short enough to not miss rapid keystrokes

  for id in ws.leaves():
    ws.setLeafCwd(id, states[id].pt.currentCwd())
  var ptyStates = ptyStatesEmpty()
  for id in ws.leaves():
    ptyStates[id] = PtyState(
      pid:             states[id].pt.pid,
      masterFd:        0,
      cwd:             states[id].pt.currentCwd(),
      daemonSessionId: if states[id].pt.isDaemon: states[id].pt.sessionId else: -1
    )
  saveSession(SessionData(workspace: ws, ptyStates: ptyStates))
  if shellsExited:
    shutdownDaemon()
  for id in ws.leaves():
    termFree(states[id].trm)

  # clean up any running background processes
  for _, p in gitProcs:
    try: p.terminate() except: discard
    p.close()
  when defined(windows):
    if winNetstatProc != nil:
      try: winNetstatProc.terminate() except: discard
      winNetstatProc.close()
    if winProcMapProc != nil:
      try: winProcMapProc.terminate() except: discard
      winProcMapProc.close()
  else:
    if ssProc != nil:
      try: ssProc.terminate() except: discard
      ssProc.close()

main()
