## Hooks integration for agent resume.
## Generates and manages hook scripts for Claude Code, Codex, OpenCode.

import std/[os, strutils, json]

type
  HookConfig* = object
    agent*: string
    path*: string
    command*: string
    enabled*: bool

proc getHooksDir*(): string =
  ## Get platform-specific hooks directory
  when defined(windows):
    result = getEnv("APPDATA") & "\\nimmux\\hooks"
  else:
    result = getHomeDir() & "/.local/share/nimmux/hooks"

proc ensureHooksDir*() =
  ## Ensure hooks directory exists
  let path = getHooksDir()
  if not path.existsDir():
    createDir(path)

proc hookPath*(agent: string): string =
  ## Get hook script path for an agent
  result = getHooksDir() & "/" & agent & ".sh"
  when defined(windows):
    result = getHooksDir() & "\\" & agent & ".bat"

proc hookScript*(agent: string): string =
  ## Generate hook script content for an agent
  case agent
  of "claude-code":
    result = """#!/bin/bash
# Claude Code hook for nimmux
# This hook is triggered when Claude Code stops waiting for input

if command -v nimmux >/dev/null 2>&1; then
    nimmux notify "Claude Code: Agent is waiting for input"
fi
"""
  of "codex":
    result = """#!/bin/bash
# Codex hook for nimmux
if command -v nimmux >/dev/null 2>&1; then
    nimmux notify "Codex: Agent is waiting for input"
fi
"""
  of "opencode":
    result = """#!/bin/bash
# OpenCode hook for nimmux
if command -v nimmux >/dev/null 2>&1; then
    nimmux notify "OpenCode: Agent is waiting for input"
fi
"""
  else:
    result = ""

proc installHook*(agent: string): HookConfig =
  ## Install hook for an agent
  ensureHooksDir()
  
  let path = hookPath(agent)
  let script = hookScript(agent)
  
  if script.len == 0:
    return HookConfig(agent: agent, path: path, command: "", enabled: false)
  
  writeFile(path, script)
  
  ## Make executable on Unix
  when not defined(windows):
    chmod(path, 0o755)
  
  result = HookConfig(agent: agent, path: path, command: script, enabled: true)

proc removeHook*(agent: string): bool =
  ## Remove hook for an agent
  let path = hookPath(agent)
  if path.fileExists():
    delFile(path)
    return true
  return false

proc listHooks*(): seq[HookConfig] =
  ## List all installed hooks
  result = @[]
  let hooksDir = getHooksDir()
  
  when defined(windows):
    for file in getFiles(hooksDir):
      if file.ext == "bat":
        let agent = file.stem
        let path = hooksDir & "/" & file
        result.add(HookConfig(agent: agent, path: path, enabled: true))
  else:
    for file in getFiles(hooksDir):
      if file.ext == "sh":
        let agent = file.stem
        let path = hooksDir & "/" & file
        result.add(HookConfig(agent: agent, path: path, enabled: true))

proc getHookCommand*(agent: string): string =
  ## Get the hook command for an agent
  let path = hookPath(agent)
  if path.fileExists():
    when defined(windows):
      return path
    else:
      return "bash " & path
  return ""