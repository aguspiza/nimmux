import std/[unittest, strutils]
import pty

when defined(windows):
  const sh    = "cmd.exe"
  const shRun = "/c"
  const enter = "\r\n"
else:
  const sh    = "/bin/sh"
  const shRun = "-c"
  const enter = "\n"

suite "pty":
  test "spawns a shell and reads output":
    var pty = ptySpawn(sh, @[shRun, "echo hi"])
    check "hi" in pty.read(timeout = 500)
    pty.close()

  test "writes to stdin":
    var pty = ptySpawn(sh, @[])
    pty.write("echo hello" & enter)
    check "hello" in pty.read(timeout = 500)
    pty.close()
