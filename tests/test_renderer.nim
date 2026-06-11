import std/[strutils, unittest]

const rendererSource = staticRead("../src/renderer.nim")

suite "renderer":
  test "terminal default background is dark grey":
    check rendererSource.contains("DefaultBG: array[3, uint8] = [20'u8,  20,  20]")
