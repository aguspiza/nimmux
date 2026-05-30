## Windows ConPTY bindings.
## Creates a pseudo-console, spawns a child process, and provides
## non-blocking read/write over pipes.

when not defined(windows):
  {.error: "pty_win.nim is Windows-only; use pty_posix.nim on Linux".}

# ── Win32 type definitions ────────────────────────────────────────────────────

type
  HANDLE   = pointer
  HPCON    = pointer
  DWORD    = uint32
  BOOL     = int32
  HRESULT  = int32
  SIZE_T   = uint
  COORD    = object
    X*, Y*: int16

  SECURITY_ATTRIBUTES = object
    nLength:              DWORD
    lpSecurityDescriptor: pointer
    bInheritHandle:       BOOL

  STARTUPINFOW = object
    cb:              DWORD
    lpReserved:      pointer
    lpDesktop:       pointer
    lpTitle:         pointer
    dwX, dwY:        DWORD
    dwXSize, dwYSize:DWORD
    dwXCountChars:   DWORD
    dwYCountChars:   DWORD
    dwFillAttribute: DWORD
    dwFlags:         DWORD
    wShowWindow:     uint16
    cbReserved2:     uint16
    lpReserved2:     pointer
    hStdInput:       HANDLE
    hStdOutput:      HANDLE
    hStdError:       HANDLE

  STARTUPINFOEXW = object
    StartupInfo:    STARTUPINFOW
    lpAttributeList: pointer  # LPPROC_THREAD_ATTRIBUTE_LIST

  PROCESS_INFORMATION = object
    hProcess:  HANDLE
    hThread:   HANDLE
    dwProcessId: DWORD
    dwThreadId:  DWORD

const
  PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE = SIZE_T(0x00020016)
  EXTENDED_STARTUPINFO_PRESENT        = DWORD(0x00080000)
  S_OK                                = HRESULT(0)

# ── Win32 API imports ─────────────────────────────────────────────────────────

{.push importc, header: "<windows.h>".}
proc CreatePseudoConsole(size: COORD; hInput, hOutput: HANDLE; dwFlags: DWORD;
                          phPC: ptr HPCON): HRESULT
proc ClosePseudoConsole(hPC: HPCON)
proc ResizePseudoConsole(hPC: HPCON; size: COORD): HRESULT
proc CreatePipe(hReadPipe, hWritePipe: ptr HANDLE;
                lpPipeAttributes: ptr SECURITY_ATTRIBUTES;
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
                                        dwAttributeCount: DWORD;
                                        dwFlags: DWORD;
                                        lpSize: ptr SIZE_T): BOOL
proc UpdateProcThreadAttribute(lpAttributeList: pointer; dwFlags: DWORD;
                                Attribute: SIZE_T; lpValue: pointer;
                                cbSize: SIZE_T; lpPreviousValue: pointer;
                                lpReturnSize: ptr SIZE_T): BOOL
proc DeleteProcThreadAttributeList(lpAttributeList: pointer)
proc CreateProcessW(lpApplicationName: pointer; lpCommandLine: pointer;
                    lpProcessAttributes, lpThreadAttributes: pointer;
                    bInheritHandles: BOOL; dwCreationFlags: DWORD;
                    lpEnvironment: pointer; lpCurrentDirectory: pointer;
                    lpStartupInfo: pointer;
                    lpProcessInformation: ptr PROCESS_INFORMATION): BOOL
proc WaitForSingleObject(hHandle: HANDLE; dwMilliseconds: DWORD): DWORD
proc TerminateProcess(hProcess: HANDLE; uExitCode: uint32): BOOL
{.pop.}

# ── public API ────────────────────────────────────────────────────────────────

type
  Pty* = object
    hPC*:      HPCON
    hWrite*:   HANDLE   # write keyboard input here
    hRead*:    HANDLE   # read terminal output here
    pi*:       PROCESS_INFORMATION

proc createPty*(cols, rows: int32; shell = "cmd.exe"): Pty =
  ## Spawn `shell` inside a ConPTY of the given size.
  var
    hPtyIn, hPtyOut: HANDLE   # PTY's own pipe ends
    hAppWrite, hAppRead: HANDLE

  doAssert CreatePipe(addr hPtyIn, addr hAppWrite, nil, 0) != 0,
    "CreatePipe(input) failed"
  doAssert CreatePipe(addr hAppRead, addr hPtyOut, nil, 0) != 0,
    "CreatePipe(output) failed"

  let coord = COORD(X: cols.int16, Y: rows.int16)
  doAssert CreatePseudoConsole(coord, hPtyIn, hPtyOut, 0, addr result.hPC) == S_OK,
    "CreatePseudoConsole failed"

  discard CloseHandle(hPtyIn)
  discard CloseHandle(hPtyOut)

  result.hWrite = hAppWrite
  result.hRead  = hAppRead

  # Build proc-thread attribute list
  var attrListSize: SIZE_T = 0
  discard InitializeProcThreadAttributeList(nil, 1, 0, addr attrListSize)
  var attrList = alloc(attrListSize)
  doAssert InitializeProcThreadAttributeList(attrList, 1, 0, addr attrListSize) != 0
  doAssert UpdateProcThreadAttribute(attrList, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
    result.hPC, sizeof(HPCON).SIZE_T, nil, nil) != 0

  var si = STARTUPINFOEXW()
  si.StartupInfo.cb = sizeof(STARTUPINFOEXW).DWORD
  si.lpAttributeList = attrList

  # CreateProcessW needs a mutable wide-string command line
  var cmd = newWideCString(shell)
  doAssert CreateProcessW(nil, cast[pointer](cmd[0].addr), nil, nil, 0,
    EXTENDED_STARTUPINFO_PRESENT, nil, nil,
    addr si, addr result.pi) != 0,
    "CreateProcessW failed for: " & shell

  DeleteProcThreadAttributeList(attrList)
  dealloc(attrList)

proc write*(pty: Pty; data: string) =
  if data.len == 0: return
  var written: DWORD
  discard WriteFile(pty.hWrite, data[0].unsafeAddr, data.len.DWORD, addr written, nil)

proc readAvailable*(pty: Pty; buf: var seq[byte]): int =
  ## Non-blocking read; returns number of bytes appended to `buf`.
  var avail: DWORD
  if PeekNamedPipe(pty.hRead, nil, 0, nil, addr avail, nil) == 0 or avail == 0:
    return 0
  let before = buf.len
  buf.setLen(before + avail.int)
  var read: DWORD
  discard ReadFile(pty.hRead, buf[before].addr, avail, addr read, nil)
  buf.setLen(before + read.int)
  result = read.int

proc resize*(pty: Pty; cols, rows: int32) =
  discard ResizePseudoConsole(pty.hPC, COORD(X: cols.int16, Y: rows.int16))

proc close*(pty: var Pty) =
  if pty.hPC != nil:
    ClosePseudoConsole(pty.hPC)
    pty.hPC = nil
  if pty.hWrite != nil:
    discard CloseHandle(pty.hWrite); pty.hWrite = nil
  if pty.hRead != nil:
    discard CloseHandle(pty.hRead);  pty.hRead = nil
  if pty.pi.hProcess != nil:
    discard TerminateProcess(pty.pi.hProcess, 0)
    discard CloseHandle(pty.pi.hProcess); pty.pi.hProcess = nil
    discard CloseHandle(pty.pi.hThread);  pty.pi.hThread  = nil
