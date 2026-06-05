import std/[unittest, strutils, os]
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
    when defined(windows):
      # Skip on Windows - cmd.exe doesn't work well with PTY writes in this context
      skip()
    else:
      var pty = ptySpawn(sh, @[])
      pty.write("echo hello" & enter)
      check "hello" in pty.read(timeout = 500)
      pty.close()

  test "Ctrl+C (\\x03) interrupts a running foreground process":
    # Regression: CREATE_NEW_PROCESS_GROUP on Windows disables CTRL+C delivery
    # for all processes in the new group, so \\x03 was silently swallowed.
    # Uses the same scenario as nimmux in practice: interactive shell with a
    # foreground command running.
    when defined(windows):
      var pt = ptySpawn("cmd.exe", @[])
      # Wait for the initial prompt
      var gotPrompt = false
      for _ in 0..<10:
        if ">" in pt.read(timeout = 400): gotPrompt = true; break
      check gotPrompt
      # Start a long-running command
      pt.write("ping 127.0.0.1\r\n")
      # Wait for the first reply so we know ping is running
      var started = false
      for _ in 0..<10:
        if "127.0.0.1" in pt.read(timeout = 500): started = true; break
      check started
      # Send Ctrl+C — with CREATE_NEW_PROCESS_GROUP the signal is disabled and
      # ping keeps running; without it cmd.exe receives the signal and aborts ping
      pt.write("\x03")
      os.sleep(200)
      # If interrupted, cmd.exe returns to its prompt; probe with echo
      pt.write("echo ctrlc_ok\r\n")
      var interrupted = false
      for _ in 0..<8:
        if "ctrlc_ok" in pt.read(timeout = 500): interrupted = true; break
      check interrupted
      pt.close()
    else:
      var pt = ptySpawn("/bin/sh", @[])
      pt.write("sleep 30\n")
      os.sleep(200)
      pt.write("\x03")
      os.sleep(100)
      pt.write("echo ctrlc_ok\n")
      var interrupted = false
      for _ in 0..<8:
        if "ctrlc_ok" in pt.read(timeout = 300): interrupted = true; break
      check interrupted
      pt.close()
