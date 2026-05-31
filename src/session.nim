## Session save/restore — serialises Workspace tree to/from JSON.

import std/[base64, json, os, tables]
import workspace

type
  PtyState* = object
    ## Saved PTY state for session persistence
    pid*:             int    ## Child process ID
    masterFd*:        int    ## Master file descriptor (Linux/Windows)
    cwd*:             string ## Current working directory
    daemonSessionId*: int    ## Daemon session ID (0 = not daemon-backed)

  SessionData* = object
    ## Complete session data including workspace and PTY states
    workspace*: Workspace
    ptyStates*: Table[int, PtyState]

proc paneToJson(p: Pane): JsonNode =
  case p.kind
  of Leaf:
    result = %*{"kind": "leaf", "id": p.id, "cwd": p.cwd}
    if p.scrollback.len > 0:
      result["scrollback"] = %encode(p.scrollback)
  of Split:
    result = %*{"kind": "split", "dir": $p.dir, "ratio": p.ratio,
       "first": paneToJson(p.first), "second": paneToJson(p.second)}

proc paneFromJson(n: JsonNode): Pane =
  case n["kind"].getStr()
  of "leaf":
    let sb = if n{"scrollback"} != nil: decode(n["scrollback"].getStr()) else: ""
    Pane(kind: Leaf, id: n["id"].getInt(), cwd: n{"cwd"}.getStr(""), scrollback: sb)
  of "split":
    let dir = if n["dir"].getStr() == "Horizontal": Horizontal else: Vertical
    Pane(kind: Split, dir: dir, ratio: n["ratio"].getFloat().float32,
         first: paneFromJson(n["first"]), second: paneFromJson(n["second"]))
  else:
    raise newException(ValueError, "unknown pane kind: " & n["kind"].getStr())

proc ptyStatesToJson*(ptyStates: Table[int, PtyState]): JsonNode =
  ## Serialize PTY states indexed by pane ID
  var arr = newSeq[JsonNode]()
  for id, state in ptyStates.pairs:
    arr.add(%*{
      "id": %id,
      "pid": %state.pid,
      "masterFd": %state.masterFd,
      "cwd": %state.cwd,
      "daemonSessionId": %state.daemonSessionId
    })
  %arr  # convert seq to JsonNode array

proc ptyStatesFromJson(n: JsonNode): Table[int, PtyState] =
  ## Deserialize PTY states
  var ptyStates: Table[int, PtyState] = initTable[int, PtyState]()
  if n{"ptyStates"} != nil:
    for stateJson in n["ptyStates"]:
      let id = stateJson["id"].getInt()
      ptyStates[id] = PtyState(
        pid:             stateJson{"pid"}.getInt(0),
        masterFd:        stateJson{"masterFd"}.getInt(0),
        cwd:             stateJson{"cwd"}.getStr(""),
        daemonSessionId: stateJson{"daemonSessionId"}.getInt(0)
      )
  ptyStates

proc toJson*(ws: Workspace; ptyStates: Table[int, PtyState]): JsonNode =
  ## Serialize workspace with PTY states
  %*{"focused": ws.focused, "root": paneToJson(ws.root), "ptyStates": ptyStatesToJson(ptyStates)}

proc fromJson*(n: JsonNode): SessionData =
  ## Deserialize workspace and PTY states
  let ws = restoreWorkspace(paneFromJson(n["root"]), n["focused"].getInt())
  let ptyStates = ptyStatesFromJson(n)
  SessionData(workspace: ws, ptyStates: ptyStates)

proc defaultSessionPath*(): string =
  when defined(windows):
    getEnv("APPDATA") / "nimmux" / "session.json"
  else:
    getEnv("HOME") / ".local" / "share" / "nimmux" / "session.json"

proc saveSession*(session: SessionData; path: string) =
  createDir(path.parentDir())
  writeFile(path, $session.workspace.toJson(session.ptyStates))

proc saveSession*(session: SessionData) = 
  saveSession(session, defaultSessionPath())

proc loadSession*(path: string): SessionData =
  if not fileExists(path): 
    return SessionData(workspace: newWorkspace(), ptyStates: initTable[int, PtyState]())
  fromJson(parseJson(readFile(path)))

proc loadSession*(): SessionData = 
  loadSession(defaultSessionPath())

proc ptyStatesEmpty*(): Table[int, PtyState] = initTable[int, PtyState]()