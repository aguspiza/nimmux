## Raylib terminal cell renderer.

import std/[os, unicode]
import raylib
import term, workspace

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

proc loadTermFont*(fontSize: int32): Font =
  const candidates = when defined(windows): [
      r"C:\Windows\Fonts\consola.ttf",
      r"C:\Windows\Fonts\lucon.ttf",
      r"C:\Windows\Fonts\cour.ttf",
    ] else: [
      "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
      "/usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf",
      "/usr/share/fonts/truetype/ubuntu/UbuntuMono-R.ttf",
    ]
  for path in candidates:
    if fileExists(path):
      result = loadFont(path, fontSize, 512)
      setTextureFilter(result.texture, TextureFilter.Bilinear)
      return result
  getFontDefault()

proc cellDims*(font: Font; fontSize: float32): (float32, float32) =
  let m = measureText(font, "M", fontSize, 0)
  (m.x, m.y)

proc drawPane*(font: Font; fontSize: float32;
               t: Terminal; r: Rect; focused: bool) =
  let (cellW, cellH) = cellDims(font, fontSize)
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
      if cp > 31:
        drawTextCodepoint(font, Rune(cp),
                          Vector2(x: px, y: py),
                          cellH, toRColor(cell.fg.toRGB(DefaultFG)))

proc drawWelcome*(font: Font; cellH: float32; sw, sh: float32) =
  const
    panelW = 440'f32
    panelH = 330'f32
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
      ("Ctrl+Z",        "zoom focused pane"),
    ]

  let px = (sw - panelW) * 0.5'f32
  let py = (sh - panelH) * 0.5'f32

  drawRectangle(Rectangle(x: px, y: py, width: panelW, height: panelH), WelcomePanelBG)
  drawRectangleLines(px.int32, py.int32, panelW.int32, panelH.int32, FocusBorderColor)

  let titleSz = cellH * 1.6'f32
  drawText(font, "nimmux", Vector2(x: px + pad, y: py + pad), titleSz, 0, FocusBorderColor)

  let sepY = py + pad + titleSz + 10
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

  SidebarState* = object
    width*: float32
    panes*: seq[PaneInfo]

proc initSidebar*(width: float32): SidebarState =
  result.width = width
  result.panes = @[]

proc updatePaneInfo*(sb: var SidebarState; id: int; cwd, branch: string; 
                      ports: seq[string]; notifCount: int) =
  for i in 0..<sb.panes.len:
    if sb.panes[i].id == id:
      sb.panes[i].cwd = cwd
      sb.panes[i].branch = branch
      sb.panes[i].ports = ports
      sb.panes[i].notifCount = notifCount
      return
  sb.panes.add PaneInfo(id: id, cwd: cwd, branch: branch, 
                         ports: ports, notifCount: notifCount)

proc drawSidebar*(font: Font; cellH: float32; r: Rect; sb: SidebarState; focusedId: int) =
  let sh = r.y + r.h
  let sidebarW = sb.width
  
  # Background (left side)
  drawRectangle(Rectangle(x: r.x, y: r.y, width: sidebarW, height: sh), Color(r: 24, g: 24, b: 32, a: 255))
  drawRectangleLines(Rectangle(x: r.x, y: r.y, width: sidebarW, height: sh), 1.0'f32, SidebarBorder)
  
  var y = 8.0'f32
  let entryH = cellH + 4
  
  for pane in sb.panes:
    let isFocused = pane.id == focusedId
    let bgColor = if isFocused: Color(r: 40, g: 50, b: 70, a: 255) else: Color(r: 0, g: 0, b: 0, a: 120)
    drawRectangle(Rectangle(x: r.x, y: y, width: sidebarW, height: entryH), bgColor)
    
    # Pane ID
    let idStr = $pane.id & " "
    drawText(font, idStr, Vector2(x: r.x + 8, y: y + 2), cellH, 0, SidebarDimText)
    
    # CWD (basename only)
    let cwdName = if pane.cwd.len > 0: extractFilename(pane.cwd) else: "~"
    drawText(font, cwdName, Vector2(x: r.x + 50, y: y + 2), cellH, 0, SidebarText)
    
    # Git branch
    if pane.branch.len > 0:
      drawText(font, " (" & pane.branch & ")", Vector2(x: r.x + 160, y: y + 2), cellH, 0, SidebarDimText)
    
    # Notification badge
    if pane.notifCount > 0:
      let badge = $pane.notifCount
      drawCircle(Vector2(x: r.x + sidebarW - 16, y: y + entryH/2), 10.0'f32, NotifBadgeColor)
      drawText(font, badge, Vector2(x: r.x + sidebarW - 28, y: y + 2), cellH * 0.75, 0, Color(r: 255, g: 255, b: 255, a: 255))
    
    y += entryH + 2
