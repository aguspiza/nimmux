## Config loader — reads ~/.config/nimmux/nimmux.json (Linux) or
## %APPDATA%\nimmux\nimmux.json (Windows). Unknown JSON keys are ignored.

import std/[json, os]

type
  TerminalConfig* = object
    autoResumeAgentSessions*: bool
    shell*: string

  NimmuxConfig* = object
    terminal*: TerminalConfig

proc defaultConfig*(): NimmuxConfig =
  result.terminal.autoResumeAgentSessions = true
  result.terminal.shell                   = ""

proc parseConfig*(json: string): NimmuxConfig =
  result = defaultConfig()
  let n = try: parseJson(json) except: return
  if n.kind != JObject: return
  if "terminal" in n and n["terminal"].kind == JObject:
    let t = n["terminal"]
    if "autoResumeAgentSessions" in t:
      result.terminal.autoResumeAgentSessions = t["autoResumeAgentSessions"].getBool(true)
    if "shell" in t:
      result.terminal.shell = t["shell"].getStr("")

proc configPath*(): string =
  when defined(windows):
    getEnv("APPDATA") / "nimmux" / "nimmux.json"
  else:
    getEnv("HOME") / ".config" / "nimmux" / "nimmux.json"

proc loadConfig*(): NimmuxConfig =
  let path = configPath()
  if not fileExists(path): return defaultConfig()
  parseConfig(readFile(path))
