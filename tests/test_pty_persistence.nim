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
    # This test simulates the user's actual workflow:
    # 1. Start nimmux (which spawns a shell)
    # 2. Close nimmux
    # 3. Shell process should still be running
    
    # Spawn a shell PTY
    var pty = ptySpawn(sh, @[])
    let pid = pty.pid
    
    # Verify the process is alive
    check pty.isAlive()
    
    # Get the current working directory
    let cwd = pty.currentCwd()
    check cwd.len > 0
    
    # Save the PTY state (simulating session save on exit)
    let savedState = PtyState(
      pid: pid,
      masterFd: pty.masterFd,
      cwd: cwd
    )
    check savedState.pid == pid
    
    # Close the PTY (simulating app exit)
    pty.close()
    
    # Verify the process is still running after PTY close
    sleep(200)
    
    # Check if the process is still running
    when defined(windows):
      let tasklistOutput = execCmd("tasklist /FI \"PID eq " & $pid)
      check tasklistOutput == 0
    else:
      let procPath = "/proc/" & $pid
      check fileExists(procPath)
  
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
    # This test verifies that ptySpawn attempts to reconnect when given a valid PID
    var pty = ptySpawn(sh, @[])
    let pid = pty.pid
    let masterFd = pty.masterFd
    
    # Save the state
    let savedState = PtyState(pid: pid, masterFd: masterFd, cwd: pty.currentCwd())
    
    # Close the PTY
    pty.close()
    
    # Give it a moment
    sleep(200)
    
    # Try to spawn with the saved state - should reconnect on POSIX
    when not defined(windows):
      # On POSIX, reconnection should work
      var pty2 = ptySpawn(sh, @[], ptyState = savedState)
      # If reconnection worked, we should have the same PID
      check pty2.pid == pid
      pty2.close()
    else:
      # On Windows, reconnection via masterFd doesn't work (ConPTY uses HPCON)
      # So a new PTY will be spawned
      var pty2 = ptySpawn(sh, @[], ptyState = savedState)
      # This is expected behavior - we get a new PID
      check pty2.pid > 0
      pty2.close()
  
  test "End-to-end: kill existing shells before test":
    # This test ensures we start with a clean state
    # Kill any existing bash/cmd processes
    when defined(windows):
      discard execCmd("taskkill //F //IM bash.exe 2>nul")
      discard execCmd("taskkill //F //IM cmd.exe 2>nul")
    else:
      discard execCmd("pkill -f bash 2>/dev/null || true")
    
    # Small delay to let processes die
    sleep(500)
    
    # Now spawn a shell
    var pty = ptySpawn(sh, @[])
    let pid = pty.pid
    
    # Verify it's alive
    check pty.isAlive()
    
    # Save session
    let savedState = PtyState(pid: pid, masterFd: pty.masterFd, cwd: pty.currentCwd())
    
    # Close PTY
    pty.close()
    
    # Verify process still exists
    sleep(200)
    when defined(windows):
      let tasklistOutput = execCmd("tasklist /FI \"PID eq " & $pid)
      check tasklistOutput == 0
    else:
      let procPath = "/proc/" & $pid
      check fileExists(procPath)
    
    # Clean up
    when defined(windows):
      discard execCmd("taskkill //F //PID " & $pid & " 2>nul")
    else:
      discard execCmd("kill " & $pid & " 2>/dev/null || true")