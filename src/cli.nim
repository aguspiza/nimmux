## CLI argument parser and commands.
## Handles `nimmux notify`, `nimmux split`, `nimmux hooks`, etc.

import std/[os, parseopt, strutils, json]

type
  CliCommand* = enum
    CmdNone,
    CmdNotify,
    CmdSplit,
    CmdHooks,
    CmdVersion,
    CmdHelp

  CliOptions* = ref object
    command*: CliCommand
    paneId*: int
    body*: string
    direction*: string
    hooksSubcmd*: string
    agent*: string

proc parseCli*(): CliOptions =
  ## Parse command-line arguments
  result.command = CmdNone
  result.direction = "vertical"
  
  for kind, arg in getopt():
    case kind
    of cmdShortOption, cmdLongOption:
      let opt = arg
      case opt
      of "notify", "n":
        result.command = CmdNotify
      of "split", "s":
        result.command = CmdSplit
      of "hooks", "h":
        result.command = CmdHooks
      of "version", "v":
        result.command = CmdVersion
      of "help", "H":
        result.command = CmdHelp
      of "pane":
        result.paneId = parseInt(arg)
      of "body":
        result.body = arg
      of "direction":
        result.direction = arg
      of "subcmd":
        result.hooksSubcmd = arg
      of "agent":
        result.agent = arg
      else:
        discard

    of cmdArgument:
      # Positional arguments
      case result.command
      of CmdNotify:
        result.body = arg
      of CmdSplit:
        if result.direction.len == 0:
          result.direction = arg
      of CmdHooks:
        if result.hooksSubcmd.len == 0:
          result.hooksSubcmd = arg
      of CmdNone:
        result.command = CmdNotify  # First arg might be the body
        result.body = arg
      else:
        discard

    of cmdEnd:
      break

proc printHelp*() =
  echo """
nimmux - terminal multiplexer for AI coding agents

Usage: nimmux [options] [command] [args]

Commands:
  notify <body>          Send a notification (default command)
  split [--pane ID]      Request a split of the specified pane
  hooks <subcmd> [agent] Manage agent hooks (setup, list, remove)
  version                Print version and exit
  help                   Show this help message

Options:
  -p, --pane ID     Pane ID for the command
  -b, --body TEXT   Notification body text
  -d, --direction   Split direction (vertical, horizontal)
  -a, --agent NAME  Agent name (claude-code, codex, opencode)
  -v, --version     Print version
  -h, --help        Show help

Examples:
  nimmux "Agent is waiting for input"
  nimmux notify -b "Build complete"
  nimmux split -p 1 -d horizontal
  nimmux hooks setup claude-code
"""

proc printVersion*() =
  echo "nimmux version 0.1.0-mvp1.1"

proc executeNotify*(opts: CliOptions): string =
  ## Execute notify command
  when defined(windows):
    # Use named pipe
    result = executeIpc("notify", opts.body)
  else:
    # Use Unix domain socket
    result = executeIpc("notify", opts.body)

proc executeSplit*(opts: CliOptions): string =
  ## Execute split command
  let data = %*{"cmd": "split", "paneId": opts.paneId, "direction": opts.direction}
  when defined(windows):
    result = executeIpc("split", $data)
  else:
    result = executeIpc("split", $data)

proc executeHooks*(opts: CliOptions): string =
  ## Execute hooks command
  case opts.hooksSubcmd
  of "setup":
    result = installHook(opts.agent)
  of "list":
    result = listHooks()
  of "remove":
    result = removeHook(opts.agent)
  else:
    result = "Unknown hooks subcommand: " & opts.hooksSubcmd

proc executeIpc*(cmd, data: string): string =
  ## Execute an IPC command
  # Placeholder - will be implemented with actual IPC
  return %*{"ok": true, "cmd": cmd}

proc installHook*(agent: string): string =
  ## Generate hook script for agent
  case agent
  of "claude-code", "codex", "opencode":
    let script = "nimmux notify \"Agent is waiting for input\""
    return %*{"ok": true, "hook": script, "agent": agent}
  else:
    return %*{"ok": false, "error": "Unknown agent: " & agent}

proc listHooks*(): string =
  ## List installed hooks
  return %*{"ok": true, "hooks": []}

proc removeHook*(agent: string): string =
  ## Remove a hook
  return %*{"ok": true, "agent": agent}

proc runCli*() =
  ## Main CLI entry point
  let opts = parseCli()
  
  case opts.command
  of CmdHelp, CmdNone:
    printHelp()
  of CmdVersion:
    printVersion()
  of CmdNotify:
    if opts.body.len == 0:
      echo "Error: notification body required"
      echo "Usage: nimmux notify <body>"
      quit(1)
    echo executeNotify(opts)
  of CmdSplit:
    echo executeSplit(opts)
  of CmdHooks:
    if opts.hooksSubcmd.len == 0:
      echo "Error: hooks subcommand required"
      echo "Usage: nimmux hooks <setup|list|remove> [agent]"
      quit(1)
    echo executeHooks(opts)
  else:
    printHelp()