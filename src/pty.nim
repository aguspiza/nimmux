## PTY layer — spawns a shell inside a pseudo-terminal.
## Linux: openpty + fork/execvp.  Windows: CreatePseudoConsole (ConPTY).

import std/[os, monotimes, times]

when defined(windows):

  # ── Win32 types ──────────────────────────────────────────────────────────────

  type
    HANDLE   = pointer
    HPCON    = pointer
    DWORD    = uint32
    BOOL     = int32
    HRESULT  = int32
    SIZE_T   = uint
    COORD {.importc: "COORD", header: "<windows.h>".} = object
      X*, Y*: int16

    SECURITY_ATTRIBUTES = object
      nLength:              DWORD
      lpSecurityDescriptor: pointer
      bInheritHandle:       BOOL

    STARTUPINFOW = object
      cb:               DWORD
      lpReserved:       pointer
      lpDesktop:        pointer
      lpTitle:          pointer
      dwX, dwY:         DWORD
      dwXSize, dwYSize: DWORD
      dwXCountChars:    DWORD
      dwYCountChars:    DWORD
      dwFillAttribute:  DWORD
      dwFlags:          DWORD
      wShowWindow:      uint16
      cbReserved2:      uint16
      lpReserved2:      pointer
      hStdInput:        HANDLE
      hStdOutput:       HANDLE
      hStdError:        HANDLE

    STARTUPINFOEXW = object
      StartupInfo:     STARTUPINFOW
      lpAttributeList: pointer

    PROCESS_INFORMATION = object
      hProcess:    HANDLE
      hThread:     HANDLE
      dwProcessId: DWORD
      dwThreadId:  DWORD

  const
    PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE = SIZE_T(0x00020016)
    EXTENDED_STARTUPINFO_PRESENT        = DWORD(0x00080000)
    STARTF_USESTDHANDLES = DWORD(0x00000100)
    S_OK                 = HRESULT(0)

  {.push importc, header: "<windows.h>".}
  proc CreatePseudoConsole(size: COORD; hInput, hOutput: HANDLE; dwFlags: DWORD;
                            phPC: ptr HPCON): HRESULT
  proc ClosePseudoConsole(hPC: HPCON)
  proc ResizePseudoConsole(hPC: HPCON; size: COORD): HRESULT
  proc CreatePipe(hReadPipe, hWritePipe: ptr HANDLE;
                  lpPipeAttributes: pointer;
                  nSize: DWORD): BOOL
  proc CloseHandle(hObject: HANDLE): BOOL
  proc WriteFile(hFile: HANDLE; lpBuffer: pointer; nNumberOfBytesToWrite: DWORD;
                 lpNumberOfBytesWritten: ptr DWORD; lpOverlapped: pointer): BOOL
  proc ReadFile(hFile: HANDLE; lpBuffer: pointer; nNumberOfBytesToRead: DWORD;
                lpNumberOfBytesRead: ptr DWORD; lpOverlapped: pointer): BOOL
  proc PeekNamedPipe(hNamedPipe: HANDLE; lpBuffer: pointer; nBufferSize: DWORD;
                     lpBytesRead: ptr DWORD; lpTotalBytesAvail: ptr DWORD;
                     lpBytesLeftThisMessage: ptr DWORD): BOOL
  proc InitializeProcThreadAttributeList(lpAttributeList: pointer;
                                          dwAttributeCount: DWORD; dwFlags: DWORD;
                                          lpSize: ptr SIZE_T): BOOL
  proc UpdateProcThreadAttribute(lpAttributeList: pointer; dwFlags: DWORD;
                                  Attribute: SIZE_T; lpValue: pointer; cbSize: SIZE_T;
                                  lpPreviousValue: pointer; lpReturnSize: ptr SIZE_T): BOOL
  proc DeleteProcThreadAttributeList(lpAttributeList: pointer)
  proc CreateProcessW(lpApplicationName: pointer; lpCommandLine: pointer;
                      lpProcessAttributes, lpThreadAttributes: pointer;
                      bInheritHandles: BOOL; dwCreationFlags: DWORD;
                      lpEnvironment: pointer; lpCurrentDirectory: pointer;
                      lpStartupInfo: pointer;
                      lpProcessInformation: ptr PROCESS_INFORMATION): BOOL
  proc TerminateProcess(hProcess: HANDLE; uExitCode: uint32): BOOL
  {.pop.}

  # ── public API (Windows) ──────────────────────────────────────────────────────

  type Pty* = object
    hPC*:    HPCON
    hWrite*: HANDLE
    hRead*:  HANDLE
    pi*:     PROCESS_INFORMATION

  proc ptySpawn*(shell: string; args: seq[string];
                 cols = 80'i32; rows = 24'i32): Pty =
    var hPtyIn, hPtyOut, hAppWrite, hAppRead: HANDLE
    doAssert CreatePipe(addr hPtyIn,  addr hAppWrite, nil, 0) != 0
    doAssert CreatePipe(addr hAppRead, addr hPtyOut,  nil, 0) != 0
    let coord = COORD(X: cols.int16, Y: rows.int16)
    doAssert CreatePseudoConsole(coord, hPtyIn, hPtyOut, 0, addr result.hPC) == S_OK
    discard CloseHandle(hPtyIn)
    discard CloseHandle(hPtyOut)
    result.hWrite = hAppWrite
    result.hRead  = hAppRead

    var attrListSize: SIZE_T
    discard InitializeProcThreadAttributeList(nil, 1, 0, addr attrListSize)
    var attrList = alloc(attrListSize)
    doAssert InitializeProcThreadAttributeList(attrList, 1, 0, addr attrListSize) != 0
    doAssert UpdateProcThreadAttribute(attrList, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
      result.hPC, sizeof(HPCON).SIZE_T, nil, nil) != 0

    var si = STARTUPINFOEXW()
    si.StartupInfo.cb        = sizeof(STARTUPINFOEXW).DWORD
    si.StartupInfo.dwFlags   = STARTF_USESTDHANDLES
    si.StartupInfo.hStdInput  = cast[HANDLE](high(uint))
    si.StartupInfo.hStdOutput = cast[HANDLE](high(uint))
    si.StartupInfo.hStdError  = cast[HANDLE](high(uint))
    si.lpAttributeList = attrList

    var cmdLine = shell
    for a in args:
      cmdLine.add(' ')
      cmdLine.add(a)
    var cmd = newWideCString(cmdLine)
    doAssert CreateProcessW(nil, cast[pointer](cmd[0].addr), nil, nil, 0,
      EXTENDED_STARTUPINFO_PRESENT, nil, nil, addr si, addr result.pi) != 0

    DeleteProcThreadAttributeList(attrList)
    dealloc(attrList)

  proc write*(pty: Pty; data: string) =
    if data.len == 0: return
    var written: DWORD
    discard WriteFile(pty.hWrite, data[0].unsafeAddr, data.len.DWORD,
                      addr written, nil)

  proc read*(pty: Pty; timeout: int): string =
    let deadline = getMonoTime() + initDuration(milliseconds = timeout)
    while getMonoTime() < deadline:
      var avail: DWORD
      if PeekNamedPipe(pty.hRead, nil, 0, nil, addr avail, nil) != 0 and avail > 0:
        let before = result.len
        result.setLen(before + avail.int)
        var nRead: DWORD
        if ReadFile(pty.hRead, result[before].addr, avail, addr nRead, nil) != 0:
          result.setLen(before + nRead.int)
      else:
        os.sleep(10)

  proc readAvailable*(pty: Pty; buf: var seq[byte]): int =
    var avail: DWORD
    if PeekNamedPipe(pty.hRead, nil, 0, nil, addr avail, nil) == 0 or avail == 0:
      return 0
    let before = buf.len
    buf.setLen(before + avail.int)
    var nRead: DWORD
    discard ReadFile(pty.hRead, buf[before].addr, avail, addr nRead, nil)
    buf.setLen(before + nRead.int)
    result = nRead.int

  proc resize*(pty: Pty; cols, rows: int32) =
    discard ResizePseudoConsole(pty.hPC, COORD(X: cols.int16, Y: rows.int16))

  proc close*(pty: var Pty) =
    if pty.hPC != nil:
      ClosePseudoConsole(pty.hPC); pty.hPC = nil
    if pty.hWrite != nil:
      discard CloseHandle(pty.hWrite); pty.hWrite = nil
    if pty.hRead != nil:
      discard CloseHandle(pty.hRead);  pty.hRead = nil
    if pty.pi.hProcess != nil:
      discard TerminateProcess(pty.pi.hProcess, 0)
      discard CloseHandle(pty.pi.hProcess); pty.pi.hProcess = nil
      discard CloseHandle(pty.pi.hThread);  pty.pi.hThread  = nil

else:  # ── POSIX ────────────────────────────────────────────────────────────────

  import std/posix

  type
    Winsize {.importc: "struct winsize", header: "<sys/ioctl.h>".} = object
      ws_row*, ws_col*, ws_xpixel*, ws_ypixel*: uint16

  proc openpty(amaster, aslave: ptr cint; name: cstring;
               termios: pointer; winp: ptr Winsize): cint
    {.importc, header: "<pty.h>".}

  proc ioctl(fd: cint; request: culong; arg: pointer): cint
    {.importc, header: "<sys/ioctl.h>".}

  var TIOCSWINSZ {.importc, header: "<sys/ioctl.h>".}: culong

  # ── public API (POSIX) ────────────────────────────────────────────────────────

  type Pty* = object
    master*: cint
    pid*:    Pid

  proc ptySpawn*(shell: string; args: seq[string];
                 cols = 80'i32; rows = 24'i32): Pty =
    var master, slave: cint
    var ws = Winsize(ws_col: cols.uint16, ws_row: rows.uint16)
    if openpty(addr master, addr slave, nil, nil, addr ws) != 0:
      raiseOSError(osLastError(), "openpty failed")
    result.master = master

    let pid = fork()
    if pid == 0:
      discard posix.close(master)
      discard setsid()
      discard ioctl(slave, TIOCSWINSZ, addr ws)
      discard dup2(slave, STDIN_FILENO)
      discard dup2(slave, STDOUT_FILENO)
      discard dup2(slave, STDERR_FILENO)
      discard posix.close(slave)
      putEnv("TERM", "xterm-256color")
      putEnv("COLORTERM", "truecolor")
      var allArgs = @[shell] & args
      var cArgs = allocCStringArray(allArgs)
      discard execvp(cstring(shell), cArgs)
      quit(1)
    else:
      discard posix.close(slave)
      result.pid = pid

  proc write*(pty: Pty; data: string) =
    if data.len > 0:
      discard posix.write(pty.master, data[0].unsafeAddr, data.len)

  proc read*(pty: Pty; timeout: int): string =
    let deadline = getMonoTime() + initDuration(milliseconds = timeout)
    var tmp: array[4096, byte]
    while getMonoTime() < deadline:
      let rem = max(1, inMilliseconds(deadline - getMonoTime()).int)
      var pfd = TPollfd(fd: pty.master, events: POLLIN)
      let r = poll(addr pfd, 1, cint(min(rem, 50)))
      if r > 0 and (pfd.revents and POLLIN) != 0:
        let n = posix.read(pty.master, addr tmp, tmp.len)
        if n > 0:
          result.add(cast[string](tmp[0..<n]))
        else:
          break  # EOF / EIO (slave closed)
      elif r == 0 and result.len > 0:
        break    # 50 ms quiescence after receiving data

  proc readAvailable*(pty: Pty; buf: var seq[byte]): int =
    var pfd = TPollfd(fd: pty.master, events: POLLIN)
    if poll(addr pfd, 1, 0) <= 0 or (pfd.revents and POLLIN) == 0:
      return 0
    var tmp: array[4096, byte]
    let n = posix.read(pty.master, addr tmp, tmp.len)
    if n > 0:
      buf.add(tmp[0..<n])
      return n
    0

  proc resize*(pty: var Pty; cols, rows: int32) =
    var ws = Winsize(ws_col: cols.uint16, ws_row: rows.uint16)
    discard ioctl(pty.master, TIOCSWINSZ, addr ws)

  proc close*(pty: var Pty) =
    if pty.master > 0:
      discard posix.close(pty.master)
      pty.master = 0
    if pty.pid > 0:
      discard kill(pty.pid, SIGTERM)
      pty.pid = 0
