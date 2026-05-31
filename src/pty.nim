## PTY layer — spawns a shell inside a pseudo-terminal.
## Linux: openpty + fork/execvp.  Windows: CreatePseudoConsole (ConPTY).

import std/[os, monotimes, times]
import session

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
    STARTF_USESTDHANDLES                = DWORD(0x00000100)
    CREATE_NEW_PROCESS_GROUP            = DWORD(0x00000200)
    S_OK                                = HRESULT(0)
    WAIT_TIMEOUT_VAL                    = DWORD(0x00000102)

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
  proc WaitForSingleObject(hHandle: HANDLE; dwMilliseconds: DWORD): DWORD
  proc GetLastError(): DWORD
  {.pop.}

  proc ReadProcessMemory(hProcess: HANDLE; lpBase: pointer; lpBuf: pointer;
                          nSize: SIZE_T; nRead: ptr SIZE_T): BOOL
    {.importc: "ReadProcessMemory", header: "<windows.h>".}

  proc NtQueryInformationProcess(hProcess: HANDLE; cls: int32; info: pointer;
                                  infoLen: DWORD; retLen: ptr DWORD): int32
    {.importc: "NtQueryInformationProcess", dynlib: "ntdll.dll".}

  # ── public API (Windows) ──────────────────────────────────────────────────────

  type Pty* = object
    hPC*:    HPCON
    hWrite*: HANDLE
    hRead*:  HANDLE
    pi*:     PROCESS_INFORMATION
    pid*:    int        ## Process ID (for session persistence)
    masterFd*: int      ## Not used on Windows (ConPTY uses HPCON)

  proc ptySpawn*(shell: string; args: seq[string];
                 cols = 80'i32; rows = 24'i32; cwd = ""; ptyState: PtyState = PtyState()): Pty =
    # If we have a valid PTY state, try to reconnect
    # On POSIX: reconnect using saved PID and masterFd
    # On Windows: reconnection not supported (ConPTY uses HPCON which can't be transferred)
    # For MVP 1.1, we accept that restarting will spawn new shells
    when not defined(windows):
      # POSIX: Try to reconnect
      if ptyState.pid > 0:
        result = ptyReconnect(ptyState.pid, ptyState.masterFd)
        if result.isAlive():
          return result
    
    # Spawn a new PTY
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
    si.StartupInfo.dwFlags   = STARTF_USESTDHANDLES  # prevent child from inheriting parent console
    si.StartupInfo.hStdInput  = cast[HANDLE](high(uint))  # INVALID_HANDLE_VALUE — ConPTY owns these
    si.StartupInfo.hStdOutput = cast[HANDLE](high(uint))
    si.StartupInfo.hStdError  = cast[HANDLE](high(uint))
    si.lpAttributeList = attrList

    var cmdLine = shell
    for a in args:
      cmdLine.add(' ')
      cmdLine.add(a)
    var cmd = newWideCString(cmdLine)
    var wdir: pointer = nil
    var wdirBuf: WideCString
    if cwd.len > 0 and dirExists(cwd):  # skip stale session CWD if path no longer exists
      wdirBuf = newWideCString(cwd)
      wdir = cast[pointer](wdirBuf[0].addr)
    var ok = CreateProcessW(nil, cast[pointer](cmd[0].addr), nil, nil, 0,
      EXTENDED_STARTUPINFO_PRESENT or CREATE_NEW_PROCESS_GROUP, nil, wdir, addr si, addr result.pi)
    if ok == 0 and wdir != nil:
      # stale/incompatible cwd — retry without it
      ok = CreateProcessW(nil, cast[pointer](cmd[0].addr), nil, nil, 0,
        EXTENDED_STARTUPINFO_PRESENT or CREATE_NEW_PROCESS_GROUP, nil, nil, addr si, addr result.pi)
    if ok == 0:
      raise newException(OSError, "CreateProcessW failed (error " & $GetLastError() & ")")

    DeleteProcThreadAttributeList(attrList)
    dealloc(attrList)
    
    # Set the pid for session persistence
    result.pid = result.pi.dwProcessId.int

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
    # NOTE: NOT closing process/thread handles - allows session persistence
    # The process will continue running in the background
    # We keep hProcess and hThread so isAlive() and reconnection can work

  proc isAlive*(pty: Pty): bool =
    if pty.pi.hProcess == nil: return false
    WaitForSingleObject(pty.pi.hProcess, 0) == WAIT_TIMEOUT_VAL

  proc shellPid*(pty: Pty): int = pty.pi.dwProcessId.int

  proc currentCwd*(pty: Pty): string =
    ## Reads the current working directory of the ConPTY child process via PEB.
    if pty.pi.hProcess == nil: return ""
    type ProcBasicInfo {.pure.} = object
      reserved1: pointer
      pebBase:   pointer
      reserved2: array[2, pointer]
      uniquePid: pointer
      reserved3: pointer
    try:
      var pbi: ProcBasicInfo
      var retLen: DWORD
      if NtQueryInformationProcess(pty.pi.hProcess, 0,
          addr pbi, DWORD(sizeof ProcBasicInfo), addr retLen) != 0:
        return ""
      # PEB+0x20 → RTL_USER_PROCESS_PARAMETERS*  (x64 offset)
      var paramsPtr: pointer
      if ReadProcessMemory(pty.pi.hProcess,
          cast[pointer](cast[int](pbi.pebBase) + 0x20),
          addr paramsPtr, SIZE_T(sizeof pointer), nil) == 0:
        return ""
      # RTL_USER_PROCESS_PARAMETERS+0x38 → CurrentDirectory.DosPath.Length (u16)
      # RTL_USER_PROCESS_PARAMETERS+0x40 → CurrentDirectory.DosPath.Buffer  (ptr)
      var cwdLen: uint16
      if ReadProcessMemory(pty.pi.hProcess,
          cast[pointer](cast[int](paramsPtr) + 0x38),
          addr cwdLen, 2.SIZE_T, nil) == 0 or cwdLen == 0:
        return ""
      var cwdBuf: pointer
      if ReadProcessMemory(pty.pi.hProcess,
          cast[pointer](cast[int](paramsPtr) + 0x40),
          addr cwdBuf, SIZE_T(sizeof pointer), nil) == 0 or cwdBuf == nil:
        return ""
      var wideBuf = cast[WideCString](alloc0(cwdLen.int + 2))
      defer: dealloc(wideBuf)
      if ReadProcessMemory(pty.pi.hProcess, cwdBuf,
          wideBuf, cwdLen.SIZE_T, nil) == 0:
        return ""
      result = $wideBuf
      if result.len > 3 and result[^1] == '\\':
        result.setLen(result.len - 1)  # strip trailing backslash Windows adds
    except:
      return ""

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
    masterFd*: int  ## Master fd (same as master, for session persistence)

  proc ptySpawn*(shell: string; args: seq[string];
                 cols = 80'i32; rows = 24'i32; cwd = ""; ptyState: PtyState = PtyState()): Pty =
    # If we have a valid PTY state, try to reconnect
    if ptyState.pid > 0:
      result = ptyReconnect(ptyState.pid, ptyState.masterFd)
      if result.isAlive():
        return result
    
    # Otherwise spawn a new PTY
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
      if cwd.len > 0:
        discard posix.chdir(cstring(cwd))
      putEnv("TERM", "xterm-256color")
      putEnv("COLORTERM", "truecolor")
      var allArgs = @[shell] & args
      var cArgs = allocCStringArray(allArgs)
      discard execvp(cstring(shell), cArgs)
      quit(1)
    else:
      discard posix.close(slave)
      result.pid = pid
      result.masterFd = master

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
    # NOTE: NOT terminating the process - allows session persistence
    # The process will continue running in the background
    if pty.master > 0:
      discard posix.close(pty.master)
      pty.master = 0
    # Don't kill the child process - it continues running

  proc isAlive*(pty: Pty): bool =
    if pty.pid <= 0: return false
    var status: cint
    waitpid(pty.pid, status, WNOHANG) == 0

  proc currentCwd*(pty: Pty): string =
    try: expandSymlink("/proc/" & $pty.pid.int & "/cwd")
    except: ""

  proc ptyIsReconnectable*(pid: int; masterFd: int): bool =
    ## Check if a PTY can be reconnected (process exists and handle is valid)
    ## POSIX: check if process exists and fd is still open
    if pid <= 0: return false
    # Check if process exists
    let procPath = "/proc/" & $pid
    if not fileExists(procPath): return false
    # Check if masterFd is still a valid fd (check /proc/pid/fd/)
    let fdPath = procPath & "/fd/" & $masterFd
    return fileExists(fdPath)

  proc ptyReconnect*(pid: int; masterFd: int): Pty =
    ## Reconnect to an existing PTY by PID and master fd
    ## POSIX: duplicate the master fd and create a new Pty object
    if pid <= 0 or masterFd < 0:
      raise newException(ValueError, "Invalid pid or masterFd")
    
    # Check if reconnectable
    if not ptyIsReconnectable(pid, masterFd):
      raise newException(ValueError, "PTY not reconnectable")
    
    result.pid = Pid(pid)
    result.master = masterFd
    result.masterFd = masterFd
