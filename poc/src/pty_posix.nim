## POSIX PTY bindings (Linux).
## Uses openpty/forkpty from <pty.h>.

when defined(windows):
  {.error: "pty_posix.nim is Linux/POSIX-only; use pty_win.nim on Windows".}

import std/[posix, os]

type
  Winsize {.importc: "struct winsize", header: "<sys/ioctl.h>".} = object
    ws_row*, ws_col*, ws_xpixel*, ws_ypixel*: uint16

proc openpty(amaster, aslave: ptr cint; name: cstring;
             termios: pointer; winp: ptr Winsize): cint
  {.importc, header: "<pty.h>".}

proc ioctl(fd: cint; request: culong; arg: pointer): cint
  {.importc, header: "<sys/ioctl.h>".}

var TIOCSWINSZ {.importc, header: "<sys/ioctl.h>".}: culong

# ── public API ────────────────────────────────────────────────────────────────

type
  Pty* = object
    master*: cint   # read terminal output / write keyboard input
    pid*:    Pid

proc createPty*(cols, rows: int32; shell = "/bin/bash"): Pty =
  var master, slave: cint
  var ws = Winsize(ws_col: cols.uint16, ws_row: rows.uint16)
  if openpty(addr master, addr slave, nil, nil, addr ws) != 0:
    raiseOSError(osLastError(), "openpty failed")
  result.master = master

  let pid = fork()
  if pid == 0:
    # child
    discard close(master)
    discard setsid()
    discard ioctl(slave, TIOCSWINSZ, addr ws)
    discard dup2(slave, STDIN_FILENO)
    discard dup2(slave, STDOUT_FILENO)
    discard dup2(slave, STDERR_FILENO)
    discard close(slave)
    putEnv("TERM", "xterm-256color")
    putEnv("COLORTERM", "truecolor")
    let sh = cstring(shell)
    var args = allocCStringArray([shell, ""])
    args[1] = nil
    discard execvp(sh, args)
    quit(1)
  else:
    discard close(slave)
    result.pid = pid
    # non-blocking reads
    let flags = fcntl(master, F_GETFL, 0)
    discard fcntl(master, F_SETFL, flags or O_NONBLOCK)

proc write*(pty: Pty; data: string) =
  if data.len > 0:
    discard posix.write(pty.master, data[0].unsafeAddr, data.len)

proc readAvailable*(pty: Pty; buf: var seq[byte]): int =
  var tmp: array[4096, byte]
  let n = posix.read(pty.master, addr tmp, tmp.len)
  if n > 0:
    let before = buf.len
    buf.setLen(before + n)
    copyMem(buf[before].addr, addr tmp, n)
    return n
  0

proc resize*(pty: Pty; cols, rows: int32) =
  var ws = Winsize(ws_col: cols.uint16, ws_row: rows.uint16)
  discard ioctl(pty.master, TIOCSWINSZ, addr ws)

proc close*(pty: var Pty) =
  if pty.master > 0:
    discard posix.close(pty.master)
    pty.master = 0
  if pty.pid > 0:
    discard kill(pty.pid, SIGTERM)
    pty.pid = 0
