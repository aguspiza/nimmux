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
