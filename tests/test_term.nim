import std/unittest
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
