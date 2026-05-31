version     = "0.1.0"
author      = "nimmux"
description = "Nim terminal multiplexer for Linux and Windows"
license     = "MIT"
srcDir      = "src"
bin         = @["nimmux"]

requires "nim >= 2.2.0"
requires "https://github.com/aguspiza/naylib#fix/destroy-guard-after-close-window"

task test, "Run tests with testament":
  exec "testament pattern \"tests/test_*.nim\""
