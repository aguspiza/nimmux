version     = "0.1.0"
author      = "nimmux"
description = "Nim terminal multiplexer for Linux and Windows"
license     = "MIT"
srcDir      = "src"

# ── binaries ──────────────────────────────────────────────────────────────────

bin = @["nimmux"]            ## GUI terminal multiplexer

# ── daemon binary ─────────────────────────────────────────────────────────────
# nimmux-daemon holds PTY sessions across GUI restarts.
# Built separately so it can be deployed without Raylib.

binDir = "."

task build_daemon, "Build nimmux-daemon":
  exec "nim c -d:release --out:nimmux-daemon src/nimmuxd.nim"

task build_all, "Build both nimmux and nimmux-daemon":
  exec "nimble build"
  exec "nimble build_daemon"

requires "nim >= 2.2.0"
requires "naylib >= 5.0.0"

task test, "Run tests with testament":
  exec "testament pattern \"tests/test_*.nim\""
