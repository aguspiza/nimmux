import std/unittest
import osc

suite "OSC parser":
  test "detects OSC 9 notification":
    var parser = initOscParser()
    let data = "\e]9;Agent waiting\a"
    let n = parser.feed(data)
    check n != nil
    check n.kind == OscNotify
    check n.body == "Agent waiting"

  test "detects OSC 9 with ID":
    var parser = initOscParser()
    let data = "\e]9;1;Agent waiting\a"
    let n = parser.feed(data)
    check n != nil
    check n.notifId == 1
    check n.body == "Agent waiting"

  test "detects OSC 2 window title":
    var parser = initOscParser()
    let data = "\e]2;My Terminal\a"
    let n = parser.feed(data)
    check n != nil
    check n.kind == OscTitle
    check n.title == "My Terminal"

  test "handles partial input":
    var parser = initOscParser()
    let n1 = parser.feed("\e]")
    check n1 == nil
    let n2 = parser.feed("9;")
    check n2 == nil
    let n3 = parser.feed("Test\a")
    check n3 != nil
    check n3.kind == OscNotify
    check n3.body == "Test"

  test "ignores unrelated sequences":
    var parser = initOscParser()
    let n = parser.feed("\e[2J")  # Clear screen
    check n == nil

  test "resets on invalid sequence":
    var parser = initOscParser()
    # First sequence is incomplete (no BEL terminator)
    let n1 = parser.feed("\e]9;test")
    check n1 == nil
    # Parser should still be in a state to parse new input
    # Reset and try a new sequence
    parser.reset()
    let n2 = parser.feed("\e]2;title\a")
    check n2 != nil
    check n2.kind == OscTitle