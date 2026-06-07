import std/[strutils, unittest]
import term

suite "term":
  test "advances terminal state":
    var t = termNew(80, 24)
    termAdvance(t, "hello")
    check termCell(t, 0, 0).ch == 'h'
    termFree(t)

  test "cursor advances after input":
    var t = termNew(80, 24)
    termAdvance(t, "hi")
    check termCursorCol(t) == 2
    termFree(t)

  test "termSendChar Ctrl+letter produces raw control byte not Alt-escape sequence":
    # VTermModifier.Ctrl must equal VTERM_MOD_CTRL=0x04 (not 0x03=SHIFT|ALT).
    # With wrong value 0x03, libvterm strips SHIFT and is left with ALT (0x02),
    # then emits ESC+letter instead of the control byte 0x01..0x1a.
    var t = termNew(80, 24)
    var out1 = ""
    vterm_output_set_callback(t.vt,
      proc(s: ConstCStr; size: uint64; user: pointer) {.cdecl.} =
        var p = cast[ptr UncheckedArray[char]](s)
        for i in 0..<size.int: cast[ptr string](user)[].add(p[i]),
      addr out1)
    termSendChar(t, 'a'.uint32, VTermModifier.Ctrl)  # Ctrl+A → \x01
    check out1 == "\x01"

    var out2 = ""
    vterm_output_set_callback(t.vt,
      proc(s: ConstCStr; size: uint64; user: pointer) {.cdecl.} =
        var p = cast[ptr UncheckedArray[char]](s)
        for i in 0..<size.int: cast[ptr string](user)[].add(p[i]),
      addr out2)
    termSendChar(t, 'c'.uint32, VTermModifier.Ctrl)  # Ctrl+C → \x03 (SIGINT byte)
    check out2 == "\x03"
    termFree(t)

  test "termGetText single row":
    var t = termNew(80, 24)
    termAdvance(t, "hello world")
    let text = termGetText(t, 0, 0, 0, 10)
    check text == "hello world"
    termFree(t)

  test "termGetText strips trailing spaces":
    var t = termNew(20, 24)
    termAdvance(t, "hi")
    let text = termGetText(t, 0, 0, 0, 19)
    check text == "hi"
    termFree(t)

  test "termGetText multi-row":
    var t = termNew(80, 24)
    termAdvance(t, "line1\r\nline2")
    let text = termGetText(t, 0, 0, 1, 4)
    check text == "line1\nline2"
    termFree(t)

  test "scrollback buffer fills on scroll":
    var t = termNew(80, 5)  # 5-row terminal forces scrolling quickly
    for i in 1..10:
      termAdvance(t, "line" & $i & "\r\n")
    check t.scrollback.lines.len >= 5
    termFree(t)

  test "termScroll changes scrollOffset":
    var t = termNew(80, 5)
    for i in 1..10: termAdvance(t, "x\r\n")
    let sbLen = t.scrollback.lines.len
    termScroll(t, 2)
    check t.scrollOffset == 2
    termScroll(t, -10)  # clamp to 0
    check t.scrollOffset == 0
    termScroll(t, 9999)  # clamp to sbLen
    check t.scrollOffset == sbLen
    termFree(t)

  test "termScrollReset goes to bottom":
    var t = termNew(80, 5)
    for i in 1..10: termAdvance(t, "x\r\n")
    termScroll(t, 3)
    termScrollReset(t)
    check t.scrollOffset == 0
    termFree(t)

  test "termScrollCell reads live screen at offset 0":
    var t = termNew(80, 24)
    termAdvance(t, "hello")
    check termScrollCell(t, 0, 0).chars[0] == 'h'.uint32
    termFree(t)

  test "termScrollCell reads scrollback when offset > 0":
    var t = termNew(80, 5)
    termAdvance(t, "AAAAAA\r\n")  # this line will scroll off
    for i in 1..5: termAdvance(t, "x\r\n")
    check t.scrollback.lines.len >= 1
    termScroll(t, t.scrollback.lines.len)  # scroll all the way up
    # first scrollback line should have 'A'
    let cell = termScrollCell(t, 0, 0)
    check cell.chars[0] == 'A'.uint32
    termFree(t)
