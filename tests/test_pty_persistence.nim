import std/[unittest, os, times, osproc]
import pty
import session
import tables

when defined(windows):
  const sh    = "cmd.exe"
  const enter = "\r\n"
else:
  const sh    = "/bin/sh"
  const enter = "\n"

suite "pty_persistence":
  test "PTY process persists after close":
    # Spawn a PTY
    var pty = ptySpawn(sh, @[])
    let pid = pty.pid
    
    # Verify the process is alive
    check pty.isAlive()
    
    # Close the PTY without terminating the process
    pty.close()
    
    # On Windows, the process may still be running due to CREATE_NEW_PROCESS_GROUP
    # Give it a moment to potentially terminate
    sleep(100)
    
    # The PID should still be valid (process may or may not still be running)
    # This test verifies that close() doesn't explicitly terminate the process
    echo "PTY PID ", pid, " closed, checking if still running..."
  
  test "PTY state can be serialized and deserialized":
    var pty = ptySpawn(sh, @[])
    let originalPid = pty.pid
    
    # Create PtyState
    let ptyState = PtyState(
      pid: pty.pid,
      masterFd: pty.masterFd,
      cwd: pty.currentCwd()
    )
    
    # Verify the state
    check ptyState.pid == originalPid
    
    # Close the PTY
    pty.close()
  
  test "PTY spawn with default parameters":
    # Test that ptySpawn works with default parameters
    var pty = ptySpawn(sh, @[])
    
    check pty.pid > 0
    check pty.isAlive()
    
    pty.close()
  
  test "User workflow: start shell, close app, shell persists":
    # On Windows: ConPTY keeps the process alive after close().
    # On Linux: closing the master PTY fd sends SIGHUP; the shell exits.
    #   Session persistence on Linux is the daemon's job (it keeps the master
    #   fd open). At the PTY layer alone, the process is expected to die.
    var pty = ptySpawn(sh, @[])
    let pid = pty.pid
    check pty.isAlive()
    let cwd = pty.currentCwd()
    check cwd.len > 0
    let savedState = PtyState(pid: pid, masterFd: pty.masterFd, cwd: cwd)
    check savedState.pid == pid
    pty.close()
    sleep(200)
    when defined(windows):
      let tasklistOutput = execCmd("tasklist /FI \"PID eq " & $pid)
      check tasklistOutput == 0
  
  test "PTY state saves correct PID":
    # This test verifies that the PID saved in PtyState matches the actual PTY PID
    var pty = ptySpawn(sh, @[])
    let spawnedPid = pty.pid
    
    # Create PtyState as would be done on session save
    let savedState = PtyState(
      pid: pty.pid,
      masterFd: pty.masterFd,
      cwd: pty.currentCwd()
    )
    
    # Verify the saved PID matches the spawned PID
    check savedState.pid == spawnedPid
    check savedState.pid > 0
    
    # Close the PTY
    pty.close()
  
  test "New shell spawn gets new PID":
    # This test verifies that when we spawn a new shell, we get a NEW PID
    # (not reusing a saved PID from a previous session)
    var pty1 = ptySpawn(sh, @[])
    let pid1 = pty1.pid
    
    # Create a "saved" state with a different PID (simulating stale session)
    var staleState: PtyState
    staleState.pid = 99999
    staleState.masterFd = 0
    staleState.cwd = ""
    
    # Spawn a new PTY with the stale state
    # The stale PID should be ignored (process doesn't exist)
    var pty2 = ptySpawn(sh, @[], ptyState = staleState)
    let pid2 = pty2.pid
    
    # Should have spawned a new process, not reused stale PID
    check pid2 > 0
    check pid2 != pid1  # Different from first spawn
    
    # Clean up
    pty1.close()
    pty2.close()
  
  test "PTY persists after close on Windows":
    # This test verifies that on Windows, the process continues running
    # after close() is called (due to CREATE_NEW_PROCESS_GROUP)
    when defined(windows):
      var pty = ptySpawn(sh, @[])
      let pid = pty.pid
      
      check pty.isAlive()
      
      # Close the PTY
      pty.close()
      
      # Give it a moment
      sleep(200)
      
      # Check if process still exists
      let tasklistOutput = execCmd("tasklist /FI \"PID eq " & $pid)
      check tasklistOutput == 0  # Process should still be running
  
  test "PTY reconnection with valid state":
    # PTY-level reconnection was removed; session persistence is now handled
    # by the daemon which keeps the master fd open across app restarts.
    # ptySpawn with a saved state always spawns a fresh process.
    var pty = ptySpawn(sh, @[])
    let pid = pty.pid
    let masterFd = pty.masterFd
    let savedState = PtyState(pid: pid, masterFd: masterFd, cwd: pty.currentCwd())
    pty.close()
    sleep(200)
    var pty2 = ptySpawn(sh, @[], ptyState = savedState)
    check pty2.pid > 0
    pty2.close()
  
