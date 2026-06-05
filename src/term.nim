## libvterm bindings + terminal wrapper.
## Compiles libvterm 0.3.3 from bundled vendor/libvterm source.

import std/os

const vtermSrc = currentSourcePath().parentDir / ".." / "vendor" / "libvterm" / "src"
const vtermInc = currentSourcePath().parentDir / ".." / "vendor" / "libvterm" / "include"

{.passC: "-I" & vtermInc.}
{.passC: "-I" & vtermSrc.}

{.compile: vtermSrc / "vterm.c".}
{.compile: vtermSrc / "encoding.c".}
{.compile: vtermSrc / "keyboard.c".}
{.compile: vtermSrc / "mouse.c".}
{.compile: vtermSrc / "parser.c".}
{.compile: vtermSrc / "pen.c".}
{.compile: vtermSrc / "screen.c".}
{.compile: vtermSrc / "state.c".}
{.compile: vtermSrc / "unicode.c".}

# ── raw C types ───────────────────────────────────────────────────────────────

type
  ConstCStr* {.importc: "const char *".} = cstring

  VTermColorRGB {.union.} = object
    `type`*: uint8
    r*, g*, b*: uint8

  VTermColorIndexed {.union.} = object
    `type`*: uint8
    idx*: uint8

  VTermMouseProp* {.size: sizeof(int32), pure.} = enum
    None = 0, Click, Drag, Move

{.push header: "<vterm.h>".}
type
  VTerm*        {.importc: "struct $1".} = object
  VTermState*   {.importc: "struct $1".} = object
  VTermScreen*  {.importc: "struct $1".} = object
  VTermRect*    {.importc.} = object
    start_row*, end_row*, start_col*, end_col*: int32

  VTermModifier* {.importc: "VTermModifier", size: sizeof(uint8), pure.} = enum
    None = 0x00, Shift = 0x01, Alt = 0x02, Ctrl = 0x04, AllMods = 0x07

  VTermKey* {.importc, pure.} = enum
    None, Enter, Tab, Backspace, Escape,
    Up, Down, Left, Right,
    Insert, Delete, Home, End, PageUp, PageDown,
    Function0 = 256, FunctionMax = 511,
    Keypad0, Keypad1, Keypad2, Keypad3, Keypad4,
    Keypad5, Keypad6, Keypad7, Keypad8, Keypad9,
    KeypadMult, KeypadPlus, KeypadComma, KeypadMinus,
    KeypadPeriod, KeypadDivide, KeypadEnter, KeypadEqual, KeyMax

  VTermStringFragment* {.importc.} = object
    str*: cstring
    len*: uint64
    initial*, final*: bool

  VTermPos* {.importc: "$1".} = object
    row*, col*: int32

  VTermProp* {.importc: "$1", pure.} = enum
    CursorVisible = 1, CursorBlink, AltScreen, Title, IconName,
    Reverse, CursorShape, Mouse, FocusReport, NProps

  VTermColor* {.importc, union.} = object
    `type`*: uint8
    rgb*: VTermColorRGB
    indexed*: VTermColorIndexed

  VTermValue* {.importc: "$1".} = object
    boolean*: bool
    number*: int32
    string*: VTermStringFragment
    color*: VTermColor

  VTermScreenCellAttrs* {.importc: "$1".} = object
    bold*, underline*, italic*, blink*, reverse*, conceal*: uint8
    strike*, font*, dwl*, dhl*, small*, baseline*: uint8

  VTermScreenCell* {.importc: "$1".} = object
    chars*: array[6, uint32]
    width*: uint8
    attrs*: VTermScreenCellAttrs
    fg*, bg*: VTermColor

  VTermScreenCallbacks* {.importc.} = object
    damage*:      proc(rect: VTermRect, user: pointer): int32 {.cdecl.}
    moverect*:    proc(dest, src: VTermRect, user: pointer): int32 {.cdecl.}
    movecursor*:  proc(pos, oldpos: VTermPos, visible: int32, user: pointer): int32 {.cdecl.}
    settermprop*: proc(prop: VTermProp, val: ptr VTermValue, user: pointer): int32 {.cdecl.}
    bell*:        proc(user: pointer): int32 {.cdecl.}
    resize*:      proc(rows, cols: int32, user: pointer): int32 {.cdecl.}
    sb_pushline*: proc(cols: int32, cells: ptr VTermScreenCell, user: pointer): int32 {.cdecl.}
    sb_popline*:  proc(cols: int32, cells: ptr VTermScreenCell, user: pointer): int32 {.cdecl.}
    sb_clear*:    proc(user: pointer): int32 {.cdecl.}

  VTermColorType* {.importc, pure.} = enum
    RGB = 0x00, Indexed = 0x01, DefaultFG = 0x02, DefaultBG = 0x04, DefaultMask = 0x06

{.push importc.}
proc vterm_new*(rows, cols: int32): ptr VTerm
proc vterm_free*(vt: ptr VTerm)
proc vterm_set_utf8*(vt: ptr VTerm, state: bool)
proc vterm_obtain_state*(vt: ptr VTerm): ptr VTermState
proc vterm_obtain_screen*(vt: ptr VTerm): ptr VTermScreen
proc vterm_input_write*(vt: ptr VTerm, bytes: ptr char, len: uint64): uint64
proc vterm_keyboard_unichar*(vt: ptr VTerm, c: uint32, modifier: VTermModifier)
proc vterm_keyboard_key*(vt: ptr VTerm, key: VTermKey, modifier: VTermModifier)
proc vterm_state_get_cursorpos*(state: ptr VTermState, cursorpos: ptr VTermPos)
proc vterm_screen_flush_damage*(vts: ptr VTermScreen)
proc vterm_screen_reset*(vts: ptr VTermScreen, hard: int32)
proc vterm_screen_get_cell*(screen: ptr VTermScreen, pos: VTermPos, cell: ptr VTermScreenCell): int32
proc vterm_screen_set_callbacks*(screen: ptr VTermScreen, callbacks: ptr VTermScreenCallbacks, user: pointer)
proc vterm_set_size*(vt: ptr VTerm, rows, cols: int32)
proc vterm_get_size*(vt: ptr VTerm, rows, cols: ptr int32)
proc vterm_output_set_callback*(vt: ptr VTerm, fn: proc(s: ConstCStr, size: uint64, user: pointer) {.cdecl.}, user: pointer)
{.pop.}
{.pop.}

# ── color helpers ─────────────────────────────────────────────────────────────

func isRGB*(c: VTermColor): bool =
  (cast[uint8](c.`type`) and 0x01'u8) == cast[uint8](VTermColorType.RGB)

func isIndexed*(c: VTermColor): bool =
  (cast[uint8](c.`type`) and 0x01'u8) == cast[uint8](VTermColorType.Indexed)

func isDefaultFG*(c: VTermColor): bool =
  cast[bool](cast[uint8](c.`type`) and cast[uint8](VTermColorType.DefaultFG))

func isDefaultBG*(c: VTermColor): bool =
  cast[bool](cast[uint8](c.`type`) and cast[uint8](VTermColorType.DefaultBG))

func r*(c: VTermColor): uint8 = {.emit: "`result` = `c`.rgb.red;".}
func g*(c: VTermColor): uint8 = {.emit: "`result` = `c`.rgb.green;".}
func b*(c: VTermColor): uint8 = {.emit: "`result` = `c`.rgb.blue;".}
func idx*(c: VTermColor): uint8 = {.emit: "`result` = `c`.indexed.idx;".}

const xterm256*: array[256, array[3, uint8]] = [
  [0'u8,0,0],[128,0,0],[0,128,0],[128,128,0],[0,0,128],[128,0,128],[0,128,128],[192,192,192],
  [128,128,128],[255,0,0],[0,255,0],[255,255,0],[0,0,255],[255,0,255],[0,255,255],[255,255,255],
  [0,0,0],[0,0,95],[0,0,135],[0,0,175],[0,0,215],[0,0,255],
  [0,95,0],[0,95,95],[0,95,135],[0,95,175],[0,95,215],[0,95,255],
  [0,135,0],[0,135,95],[0,135,135],[0,135,175],[0,135,215],[0,135,255],
  [0,175,0],[0,175,95],[0,175,135],[0,175,175],[0,175,215],[0,175,255],
  [0,215,0],[0,215,95],[0,215,135],[0,215,175],[0,215,215],[0,215,255],
  [0,255,0],[0,255,95],[0,255,135],[0,255,175],[0,255,215],[0,255,255],
  [95,0,0],[95,0,95],[95,0,135],[95,0,175],[95,0,215],[95,0,255],
  [95,95,0],[95,95,95],[95,95,135],[95,95,175],[95,95,215],[95,95,255],
  [95,135,0],[95,135,95],[95,135,135],[95,135,175],[95,135,215],[95,135,255],
  [95,175,0],[95,175,95],[95,175,135],[95,175,175],[95,175,215],[95,175,255],
  [95,215,0],[95,215,95],[95,215,135],[95,215,175],[95,215,215],[95,215,255],
  [95,255,0],[95,255,95],[95,255,135],[95,255,175],[95,255,215],[95,255,255],
  [135,0,0],[135,0,95],[135,0,135],[135,0,175],[135,0,215],[135,0,255],
  [135,95,0],[135,95,95],[135,95,135],[135,95,175],[135,95,215],[135,95,255],
  [135,135,0],[135,135,95],[135,135,135],[135,135,175],[135,135,215],[135,135,255],
  [135,175,0],[135,175,95],[135,175,135],[135,175,175],[135,175,215],[135,175,255],
  [135,215,0],[135,215,95],[135,215,135],[135,215,175],[135,215,215],[135,215,255],
  [135,255,0],[135,255,95],[135,255,135],[135,255,175],[135,255,215],[135,255,255],
  [175,0,0],[175,0,95],[175,0,135],[175,0,175],[175,0,215],[175,0,255],
  [175,95,0],[175,95,95],[175,95,135],[175,95,175],[175,95,215],[175,95,255],
  [175,135,0],[175,135,95],[175,135,135],[175,135,175],[175,135,215],[175,135,255],
  [175,175,0],[175,175,95],[175,175,135],[175,175,175],[175,175,215],[175,175,255],
  [175,215,0],[175,215,95],[175,215,135],[175,215,175],[175,215,215],[175,215,255],
  [175,255,0],[175,255,95],[175,255,135],[175,255,175],[175,255,215],[175,255,255],
  [215,0,0],[215,0,95],[215,0,135],[215,0,175],[215,0,215],[215,0,255],
  [215,95,0],[215,95,95],[215,95,135],[215,95,175],[215,95,215],[215,95,255],
  [215,135,0],[215,135,95],[215,135,135],[215,135,175],[215,135,215],[215,135,255],
  [215,175,0],[215,175,95],[215,175,135],[215,175,175],[215,175,215],[215,175,255],
  [215,215,0],[215,215,95],[215,215,135],[215,215,175],[215,215,215],[215,215,255],
  [215,255,0],[215,255,95],[215,255,135],[215,255,175],[215,255,215],[215,255,255],
  [255,0,0],[255,0,95],[255,0,135],[255,0,175],[255,0,215],[255,0,255],
  [255,95,0],[255,95,95],[255,95,135],[255,95,175],[255,95,215],[255,95,255],
  [255,135,0],[255,135,95],[255,135,135],[255,135,175],[255,135,215],[255,135,255],
  [255,175,0],[255,175,95],[255,175,135],[255,175,175],[255,175,215],[255,175,255],
  [255,215,0],[255,215,95],[255,215,135],[255,215,175],[255,215,215],[255,215,255],
  [255,255,0],[255,255,95],[255,255,135],[255,255,175],[255,255,215],[255,255,255],
  [8,8,8],[18,18,18],[28,28,28],[38,38,38],[48,48,48],[58,58,58],
  [68,68,68],[78,78,78],[88,88,88],[98,98,98],[108,108,108],[118,118,118],
  [128,128,128],[138,138,138],[148,148,148],[158,158,158],[168,168,168],[178,178,178],
  [188,188,188],[198,198,198],[208,208,208],[218,218,218],[228,228,228],[238,238,238],
]

proc toRGB*(c: VTermColor; defaultRGB: array[3, uint8]): array[3, uint8] =
  if c.isRGB:       [c.r, c.g, c.b]
  elif c.isIndexed: xterm256[c.idx]
  else:             defaultRGB

# ── Terminal wrapper ──────────────────────────────────────────────────────────

type Terminal* = object
  vt*:     ptr VTerm
  screen*: ptr VTermScreen
  state*:  ptr VTermState
  cols*, rows*: int32

func ch*(cell: VTermScreenCell): char = char(cell.chars[0])

proc termNew*(cols, rows: int32): Terminal =
  result.cols   = cols
  result.rows   = rows
  result.vt     = vterm_new(rows, cols)
  vterm_set_utf8(result.vt, true)
  result.screen = vterm_obtain_screen(result.vt)
  result.state  = vterm_obtain_state(result.vt)
  vterm_screen_reset(result.screen, 1)

proc termFree*(t: var Terminal) =
  if t.vt != nil:
    vterm_output_set_callback(t.vt, nil, nil)  # deregister before free
    vterm_free(t.vt)
    t.vt = nil

proc termAdvance*(t: var Terminal; data: openArray[byte]) =
  if data.len > 0:
    discard vterm_input_write(t.vt, cast[ptr char](data[0].unsafeAddr), data.len.uint64)

proc termAdvance*(t: var Terminal; data: string) =
  if data.len > 0:
    discard vterm_input_write(t.vt, cast[ptr char](data[0].unsafeAddr), data.len.uint64)

proc termCell*(t: Terminal; row, col: int32): VTermScreenCell =
  discard vterm_screen_get_cell(t.screen, VTermPos(row: row, col: col), addr result)

proc termCursorPos*(t: Terminal): VTermPos =
  vterm_state_get_cursorpos(t.state, addr result)

proc termCursorRow*(t: Terminal): int32 = t.termCursorPos().row
proc termCursorCol*(t: Terminal): int32 = t.termCursorPos().col

proc termResize*(t: var Terminal; cols, rows: int32) =
  t.cols = cols; t.rows = rows
  vterm_set_size(t.vt, rows, cols)

proc termSendKey*(t: var Terminal; key: VTermKey; mods = VTermModifier.None) =
  vterm_keyboard_key(t.vt, key, mods)

proc termSendChar*(t: var Terminal; c: uint32; mods = VTermModifier.None) =
  vterm_keyboard_unichar(t.vt, c, mods)
