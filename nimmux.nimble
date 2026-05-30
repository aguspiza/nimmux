version     = "0.1.0"
author      = "nimmux"
description = "Nim terminal multiplexer for Linux and Windows"
license     = "MIT"
srcDir      = "src"
bin         = @["nimmux"]

requires "nim >= 2.2.0"
# naylib added in Phase 4 when PoC UI code is promoted

task test, "Run tests with testament":
  exec "testament pattern \"tests/test_*.nim\""
