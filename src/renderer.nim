## Raylib terminal cell renderer.

import std/[os, sets, unicode]
import raylib
import term, workspace, fontcodepoints, fontprobe

const
  DefaultFG: array[3, uint8] = [220'u8, 220, 220]
  DefaultBG: array[3, uint8] = [30'u8,  30,  30]
  CursorColor      = Color(r: 220, g: 220, b: 220, a: 180)
  FocusBorderColor = Color(r: 80,  g: 140, b: 255, a: 255)
  BorderColor      = Color(r: 60,  g:  60, b:  60, a: 255)
  WelcomePanelBG   = Color(r: 12,  g:  16, b:  24, a: 245)
  WelcomeDimFG     = Color(r: 100, g: 100, b: 110, a: 255)
  SidebarBorder    = Color(r: 50,  g:  50, b:  60, a: 255)
  SidebarText      = Color(r: 180, g: 180, b: 190, a: 255)
  SidebarDimText   = Color(r: 100, g: 100, b: 120, a: 255)
  NotifBadgeColor  = Color(r: 255, g:  80, b:  80, a: 255)

proc toRColor(rgb: array[3, uint8]): Color =
  Color(r: rgb[0], g: rgb[1], b: rgb[2], a: 255)

type TermFonts* = object
  primary*: Font
  fallback*: Font
  ext*: Font
  primCoverage*: HashSet[int32]
  fallCoverage*: HashSet[int32]

proc loadOneFont(path: string; fontSize: int32; cps: seq[int32]): Font =
  result = loadFont(path, fontSize, cps)
  setTextureFilter(result.texture, TextureFilter.Bilinear)

proc findFont(candidates: openArray[string]): string =
  for p in candidates:
    if fileExists(p): return p
  ""

proc loadTermFont*(fontSize: int32): TermFonts =
  ## Loads up to 3 fonts: primary (best TUI coverage), fallback (math/symbols),
  ## ext (comprehensive BMP fallback). Each font only loads codepoints it
  ## actually has, as determined by TrueType cmap parsing.
  const primCandidates = when defined(windows): [
      r"C:\Windows\Fonts\CascadiaMono.ttf",
      r"C:\Windows\Fonts\consola.ttf",
      r"C:\Windows\Fonts\lucon.ttf",
    ] else: [
      "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
      "/usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf",
      "/usr/share/fonts/truetype/ubuntu/UbuntuMono-R.ttf",
    ]
  const fallCandidates = when defined(windows): [
      r"C:\Windows\Fonts\DejaVuSansMono.ttf",
      r"C:\Windows\Fonts\cour.ttf",
    ] else: [
      "/usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf",
      "/usr/share/fonts/truetype/ubuntu/UbuntuMono-R.ttf",
    ]
  const extCandidates = when defined(windows): [
      r"C:\Windows\Fonts\seguisym.ttf",
    ] else: [
      "/usr/share/fonts/truetype/ancient-fonts/Symbola.ttf",
      "/usr/share/fonts/opentype/noto/NotoSansSymbols2-Regular.otf",
    ]
  let allCps   = buildTermCodepoints()
  let primPath = findFont(primCandidates)
  let fallPath = findFont(fallCandidates)
  let extPath  = findFont(extCandidates)

  let primCov = if primPath != "": fontCoverage(primPath) else: @[]
  let fallCov = if fallPath != "": fontCoverage(fallPath) else: @[]
  result.primCoverage = primCov.toHashSet()
  result.fallCoverage = fallCov.toHashSet()

  var primCps, fallCps, extCps: seq[int32]
  for cp in allCps:
    if cp in result.primCoverage:   primCps.add(cp)
    elif cp in result.fallCoverage: fallCps.add(cp)
    else:                           extCps.add(cp)

  if primPath != "": result.primary  = loadOneFont(primPath, fontSize, primCps)
  if fallPath != "" and fallCps.len > 0:
    result.fallback = loadOneFont(fallPath, fontSize, fallCps)
  if extPath != "" and extCps.len > 0:
    result.ext = loadOneFont(extPath, fontSize, extCps)

  if not isFontValid(result.primary): result.primary = getFontDefault()

proc cellDims*(font: Font; fontSize: float32): (float32, float32) =
  let m = measureText(font, "M", fontSize, 0)
  (m.x, m.y)

proc drawPane*(tf: var TermFonts; fontSize: float32; t: Terminal; r: Rect; focused: bool) =
  let (cellW, cellH) = cellDims(tf.primary, fontSize)
  let cols = int(r.w / cellW)
  let rows = int(r.h / cellH)

  drawRectangleLines(r.x.int32, r.y.int32, r.w.int32, r.h.int32,
                     if focused: FocusBorderColor else: BorderColor)

  let cur = termCursorPos(t)

  for row in 0 ..< min(rows, t.rows.int):
    for col in 0 ..< min(cols, t.cols.int):
      let cell = termCell(t, row.int32, col.int32)
      let px = r.x + col.float32 * cellW
      let py = r.y + row.float32 * cellH

      drawRectangle(
        Rectangle(x: px, y: py, width: cellW, height: cellH),
        toRColor(cell.bg.toRGB(DefaultBG)))

      if focused and row == cur.row.int and col == cur.col.int:
        drawRectangle(
          Rectangle(x: px, y: py, width: cellW, height: cellH),
          CursorColor)

      let cp = cell.chars[0]
      if cp > 31'u32 and cp <= 0x10FFFF'u32:
        let rune  = Rune(cp)
        let color = toRColor(cell.fg.toRGB(DefaultFG))
        if cp.int32 in tf.primCoverage:
          drawTextCodepoint(tf.primary, rune, Vector2(x: px, y: py), cellH, color)
        elif cp.int32 in tf.fallCoverage:
          drawTextCodepoint(tf.fallback, rune, Vector2(x: px, y: py), cellH, color)
        elif isFontValid(tf.ext):
          drawTextCodepoint(tf.ext, rune, Vector2(x: px, y: py), cellH, color)
        else:
          drawTextCodepoint(tf.primary, rune, Vector2(x: px, y: py), cellH, color)

proc drawWelcome*(font: Font; cellH: float32; sw, sh: float32) =
  const
    panelW = 440'f32
    panelH = 350'f32
    pad    = 28'f32
    rowH   = 28'f32
    hints  = [
      ("Ctrl+D",        "split vertical"),
      ("Ctrl+Shift+D",  "split horizontal"),
      ("Ctrl+Shift+]",  "next pane"),
      ("Ctrl+Shift+[",  "previous pane"),
      ("Ctrl+W",        "close pane"),
      ("Ctrl+=",        "increase font size"),
      ("Ctrl+-",        "decrease font size"),
      ("Ctrl+F",        "zoom focused pane"),
    ]

  let px = (sw - panelW) * 0.5'f32
  let py = (sh - panelH) * 0.5'f32

  drawRectangle(Rectangle(x: px, y: py, width: panelW, height: panelH), WelcomePanelBG)
  drawRectangleLines(px.int32, py.int32, panelW.int32, panelH.int32, FocusBorderColor)

  let titleSz = cellH * 1.6'f32
  drawText(font, "nimmux", Vector2(x: px + pad, y: py + pad), titleSz, 0, FocusBorderColor)

  let subtitleSz = cellH * 0.85'f32
  drawText(font, "keybindings assume US layout (configurable in 1.1)",
           Vector2(x: px + pad, y: py + pad + titleSz + 2), subtitleSz, 0, WelcomeDimFG)

  let sepY = py + pad + titleSz + subtitleSz + 14
  drawRectangle(Rectangle(x: px + pad, y: sepY, width: panelW - pad * 2, height: 1), BorderColor)

  let hintY0 = sepY + 14
  for i, (key, desc) in hints:
    let y = hintY0 + float32(i) * rowH
    drawText(font, key,  Vector2(x: px + pad,       y: y), cellH, 0, Color(r: 210, g: 210, b: 215, a: 255))
    drawText(font, desc, Vector2(x: px + pad + 175, y: y), cellH, 0, WelcomeDimFG)

# ── Sidebar Types ───────────────────────────────────────────────────────────────

type
  PaneInfo* = object
    id*: int
    cwd*: string
    branch*: string
    ports*: seq[string]
    notifCount*: int
    source*: string  # "local" or "ssh://user@host"

  SidebarState* = object
    width*: float32
    panes*: seq[PaneInfo]

proc initSidebar*(width: float32): SidebarState =
  result.width = width
  result.panes = @[]

proc removePaneInfo*(sb: var SidebarState; id: int) =
  for i in 0..<sb.panes.len:
    if sb.panes[i].id == id:
      sb.panes.delete(i)
      return

proc updatePaneInfo*(sb: var SidebarState; id: int; cwd, branch: string;
                      ports: seq[string]; notifCount: int; source = "local") =
  for i in 0..<sb.panes.len:
    if sb.panes[i].id == id:
      sb.panes[i].cwd = cwd
      sb.panes[i].branch = branch
      sb.panes[i].ports = ports
      sb.panes[i].notifCount = notifCount
      sb.panes[i].source = source
      return
  sb.panes.add PaneInfo(id: id, cwd: cwd, branch: branch,
                         ports: ports, notifCount: notifCount, source: source)

proc drawSidebar*(font: Font; cellH: float32; r: Rect; sb: SidebarState; focusedId: int): int =
  ## Returns the pane ID under the mouse cursor, or -1 if none
  result = -1
  let sh = r.y + r.h
  let sidebarW = sb.width
  
  # Background (left side)
  drawRectangle(Rectangle(x: r.x, y: r.y, width: sidebarW, height: sh), Color(r: 24, g: 24, b: 32, a: 255))
  drawRectangleLines(Rectangle(x: r.x, y: r.y, width: sidebarW, height: sh), 1.0'f32, SidebarBorder)
  
  # Separator line between sidebar and panes
  drawLine(Vector2(x: r.x + sidebarW, y: r.y), Vector2(x: r.x + sidebarW, y: sh), SidebarBorder)
  
  var y = 8.0'f32
  let entryH   = cellH * 2 + 8   # two lines per entry
  let branchSz = cellH * 0.85'f32
  # max branch chars that fit between left pad (14) and badge area (20)
  let charW    = measureText(font, "M", branchSz, 0).x
  let maxBranchW = sidebarW - 14 - 20
  let maxBranchChars = max(1, int(maxBranchW / charW))

  let mousePos = getMousePosition()

  for pane in sb.panes:
    let isFocused = pane.id == focusedId
    let bgColor = if isFocused: Color(r: 40, g: 50, b: 70, a: 255)
                  else:         Color(r: 0,  g:  0, b:  0, a: 120)
    let entryRect = Rectangle(x: r.x, y: y, width: sidebarW, height: entryH)
    drawRectangle(entryRect, bgColor)

    if sidebarW > 0 and checkCollisionPointRec(mousePos, entryRect) and
        isMouseButtonPressed(MouseButton.Left):
      result = pane.id

    # Line 1: pane ID + CWD basename + notification badge
    let idStr   = $pane.id
    let cwdName = if pane.cwd.len > 0: extractFilename(pane.cwd) else: "~"
    drawText(font, idStr,   Vector2(x: r.x + 8,  y: y + 3), cellH, 0, SidebarDimText)
    let idW = measureText(font, idStr, cellH, 0).x
    drawText(font, cwdName, Vector2(x: r.x + 8 + idW + 6, y: y + 3), cellH, 0, SidebarText)

    if pane.notifCount > 0:
      let badge = $pane.notifCount
      drawCircle(Vector2(x: r.x + sidebarW - 14, y: y + cellH / 2 + 3), 9.0'f32, NotifBadgeColor)
      drawText(font, badge, Vector2(x: r.x + sidebarW - 22, y: y + 3), cellH * 0.75, 0,
               Color(r: 255, g: 255, b: 255, a: 255))

    # Line 2: git branch + remote source badge (suppressed for "local")
    let line2Y = y + cellH + 6
    if pane.source.len > 0 and pane.source != "local":
      let srcLabel = pane.source
      let srcW = measureText(font, srcLabel, branchSz, 0).x
      drawText(font, srcLabel, Vector2(x: r.x + sidebarW - srcW - 6, y: line2Y),
               branchSz, 0, Color(r: 100, g: 180, b: 255, a: 200))
    if pane.branch.len > 0:
      let branch = if pane.branch.len <= maxBranchChars: pane.branch
                   else: pane.branch[0 ..< maxBranchChars - 1] & "…"
      drawText(font, branch, Vector2(x: r.x + 14, y: line2Y), branchSz, 0, SidebarDimText)

    y += entryH + 2
