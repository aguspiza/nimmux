## Raylib terminal cell renderer.

import std/[os, unicode]
import raylib
import vterm, layout

const
  DefaultFG: array[3, uint8] = [220'u8, 220, 220]
  DefaultBG: array[3, uint8] = [30'u8,  30,  30]
  CursorColor      = Color(r: 220, g: 220, b: 220, a: 180)
  FocusBorderColor = Color(r: 80,  g: 140, b: 255, a: 255)
  BorderColor      = Color(r: 60,  g:  60, b:  60, a: 255)

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
      return loadFont(path, fontSize, 512)
  getFontDefault()

proc cellDims*(font: Font; fontSize: float32): (float32, float32) =
  let m = measureText(font, "M", fontSize, 0)
  (m.x, m.y)

proc drawPane*(font: Font; cellW, cellH: float32;
               pane: Pane; r: Rect; focused: bool) =
  let cols = int(r.w / cellW)
  let rows = int(r.h / cellH)

  drawRectangleLines(r.x.int32, r.y.int32, r.w.int32, r.h.int32,
                     if focused: FocusBorderColor else: BorderColor)

  let cur = pane.term.cursorPos()

  for row in 0 ..< min(rows, pane.term.rows.int):
    for col in 0 ..< min(cols, pane.term.cols.int):
      let cell = pane.term.cell(row.int32, col.int32)
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
