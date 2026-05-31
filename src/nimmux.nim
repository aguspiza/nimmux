## nimmux — terminal multiplexer.
## Ctrl+D           split vertical
## Ctrl+Shift+D     split horizontal
## Ctrl+Shift+]     next pane
## Ctrl+Shift+[     previous pane
## Ctrl+W           close pane
## Ctrl+=           increase font size
## Ctrl+-           decrease font size
## Ctrl+Z           zoom focused pane (toggle)

import raylib
import std/[tables, os, osproc, streams, strutils, times]
import workspace, term, pty, renderer, session, daemon

const
  SidebarWidth  = 200.0'f32
  CacheInterval = 3.0  # seconds between background subprocess refreshes

type PaneState = ref object
  trm:      Terminal
  pt:       Pty
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
          options = {poUsePath, poStdErrToStdOut})
      except: discard
  elif cwd notin gitProcs:
    try:
      gitProcs[cwd] = startProcess("git",
        args = ["-C", cwd, "rev-parse", "--abbrev-ref", "HEAD"],
        options = {poUsePath, poStdErrToStdOut})
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
                                      options = {poUsePath, poStdErrToStdOut})
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
          options = {poUsePath, poStdErrToStdOut})
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

proc getPanePorts(pt: Pty): seq[string] =
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
  # Ensure daemon is running for PTY persistence
  ensureDaemonDir()
  if not fileExists(getDaemonSocketPath()):
    discard spawnDaemon()
  
  setTraceLogLevel(TraceLogLevel.Error)
  setConfigFlags(flags(ConfigFlags.VsyncHint, ConfigFlags.WindowResizable))
  initWindow(WinW, WinH, "nimmux")
  defer: closeWindow()
  setTargetFPS(60)

  let font             = loadTermFont(BaseFontSz)
  let (initCw, initCh) = cellDims(font, FontSz)
  let initCols         = int32(WinW.float32 / initCw)
  let initRows         = int32(WinH.float32 / initCh)
  let shell            = defaultShell()

  var sessionData = loadSession()
  var ws = sessionData.workspace
  var states      = initTable[int, PaneState]()
  var showWelcome = true
  var sidebar     = initSidebar(SidebarWidth)

  proc onOutput(s: ConstCStr; size: uint64; user: pointer) {.cdecl.} =
    if size == 0: return
    let ps = cast[PaneState](user)
    var data = newString(size.int)
    copyMem(data[0].addr, s, size.int)
    ps.pt.write(data)

  proc addPane(id: int; cols, rows: int32; cwd = ""; fontSize = FontSz; ptyState: PtyState = PtyState()) =
    let ps = PaneState(
      trm:      termNew(cols, rows),
      pt:       ptySpawn(shell, @[], cols, rows, cwd, ptyState),
      buf:      @[],
      fontSize: fontSize)
    vterm_output_set_callback(ps.trm.vt, onOutput, cast[pointer](ps))
    states[id] = ps

  proc reflowPane(id: int) =
    let sw = getScreenWidth().float32
    let sh = getScreenHeight().float32
    for (pid, rect) in ws.leafRects(Rect(x: 0, y: 0, w: sw, h: sh)):
      if pid == id:
        let (cw, ch) = cellDims(font, states[id].fontSize)
        let ncols = max(1'i32, int32(rect.w / cw))
        let nrows = max(1'i32, int32(rect.h / ch))
        states[id].trm.termResize(ncols, nrows)
        states[id].pt.resize(ncols, nrows)
        break

  for id in ws.leaves():
    addPane(id, initCols, initRows, ws.leafCwd(id), ptyState = sessionData.ptyStates.getOrDefault(id, PtyState()))

  var shouldQuit = false
  var zoomed     = false
  var sidebarExpanded     = true
  var prevSidebarExpanded = true
  var prevW = 0.0'f32
  var prevH = 0.0'f32
  while not windowShouldClose() and not shouldQuit:
    let ctrl  = isKeyDown(KeyboardKey.LeftControl)  or isKeyDown(KeyboardKey.RightControl)
    let shift = isKeyDown(KeyboardKey.LeftShift)    or isKeyDown(KeyboardKey.RightShift)

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
        termFree(states[id].trm)
        # NOTE: NOT closing PTY - processes continue running in background
        # This allows session restore to reconnect to existing processes
        states.del(id)
        ws.close(id)

    # zoom focused pane: Ctrl+Z toggles full-screen for the active pane
    if ctrl and isKeyPressed(KeyboardKey.Z):
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

    var cp = getCharPressed()
    while cp != 0:
      let mods = if ctrl: VTermModifier.Ctrl else: VTermModifier.None
      states[ws.focused].trm.termSendChar(cp.uint32, mods)
      cp = getCharPressed()
      showWelcome = false

    # read PTY output → libvterm
    for id in ws.leaves():
      let ps = states[id]
      let n = ps.pt.readAvailable(ps.buf)
      if n > 0:
        ps.trm.termAdvance(ps.buf.toOpenArray(ps.buf.len - n, ps.buf.len - 1))
        ps.buf.setLen(0)

    # close panes whose shell has exited
    var deadPanes: seq[int]
    for id in ws.leaves():
      if not states[id].pt.isAlive():
        deadPanes.add(id)
    for id in deadPanes:
      if ws.leaves().len == 1:
        shouldQuit = true
        break
      termFree(states[id].trm)
      states[id].pt.close()
      states.del(id)
      ws.close(id)

    # poll background subprocesses (never blocks)
    when defined(windows):
      pollWinNetstat()
      pollWinProcMap()
    else:
      pollSsCache()

    # update sidebar info
    let curW = getScreenWidth().float32
    let curH = getScreenHeight().float32
    let sidebarW = if sidebarExpanded: SidebarWidth else: 0.0'f32
    for id in ws.leaves():
      let cwd = states[id].pt.currentCwd()
      let branch = getGitBranch(cwd)
      let ports = getPanePorts(states[id].pt)
      sidebar.updatePaneInfo(id, cwd, branch, ports, 0)

    # reflow on window resize or sidebar toggle
    if curW != prevW or curH != prevH or sidebarExpanded != prevSidebarExpanded:
      prevW = curW; prevH = curH; prevSidebarExpanded = sidebarExpanded
      let paneW = curW - sidebarW
      for (id, rect) in ws.leafRects(Rect(x: sidebarW, y: 0, w: paneW, h: curH)):
        let (cw, ch) = cellDims(font, states[id].fontSize)
        let ncols = max(1'i32, int32(rect.w / cw))
        let nrows = max(1'i32, int32(rect.h / ch))
        states[id].trm.termResize(ncols, nrows)
        states[id].pt.resize(ncols, nrows)

    # render
    beginDrawing()
    clearBackground(Color(r: 20, g: 20, b: 20, a: 255))
    let sw = getScreenWidth().float32
    let sh = getScreenHeight().float32
    let paneW = sw - sidebarW
    if zoomed:
      drawPane(font, states[ws.focused].fontSize, states[ws.focused].trm,
               Rect(x: sidebarW, y: 0, w: paneW, h: sh), true)
    else:
      for (id, rect) in ws.leafRects(Rect(x: sidebarW, y: 0, w: paneW, h: sh)):
        drawPane(font, states[id].fontSize, states[id].trm, rect, id == ws.focused)
    if sidebarExpanded:
      let clickedPane = drawSidebar(font, initCh, Rect(x: 0, y: 0, w: sidebarW, h: sh), sidebar, ws.focused)
      if clickedPane != -1:
        ws.setFocus(clickedPane)
        showWelcome = false
    if showWelcome:
      drawWelcome(font, initCh, sw, sh)
    endDrawing()

  for id in ws.leaves():
    ws.setLeafCwd(id, states[id].pt.currentCwd())
  # Save PTY state for each pane
  var ptyStates = ptyStatesEmpty()
  for id in ws.leaves():
    ptyStates[id] = PtyState(
      pid: states[id].pt.pid,
      masterFd: states[id].pt.masterFd,
      cwd: states[id].pt.currentCwd()
    )
  saveSession(SessionData(workspace: ws, ptyStates: ptyStates))
  for id in ws.leaves():
    termFree(states[id].trm)
    # NOTE: NOT closing PTY - processes continue running in background
    # This allows session restore to reconnect to existing processes

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
