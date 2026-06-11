import std/[strutils, unittest]

const rendererSource = staticRead("../src/renderer.nim")

suite "renderer":
  test "terminal default background is dark grey":
    check rendererSource.contains("DefaultBG: array[3, uint8] = [28'u8,  28,  28]")
