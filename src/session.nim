## Session save/restore — serialises Workspace tree to/from JSON.

import std/[json, os]
import workspace

proc paneToJson(p: Pane): JsonNode =
  case p.kind
  of Leaf:
    %*{"kind": "leaf", "id": p.id}
  of Split:
    %*{"kind": "split", "dir": $p.dir, "ratio": p.ratio,
       "first": paneToJson(p.first), "second": paneToJson(p.second)}

proc paneFromJson(n: JsonNode): Pane =
  case n["kind"].getStr()
  of "leaf":
    Pane(kind: Leaf, id: n["id"].getInt())
  of "split":
    let dir = if n["dir"].getStr() == "Horizontal": Horizontal else: Vertical
    Pane(kind: Split, dir: dir, ratio: n["ratio"].getFloat().float32,
         first: paneFromJson(n["first"]), second: paneFromJson(n["second"]))
  else:
    raise newException(ValueError, "unknown pane kind: " & n["kind"].getStr())

proc toJson*(ws: Workspace): JsonNode =
  %*{"focused": ws.focused, "root": paneToJson(ws.root)}

proc fromJson*(n: JsonNode): Workspace =
  restoreWorkspace(paneFromJson(n["root"]), n["focused"].getInt())

proc defaultSessionPath*(): string =
  when defined(windows):
    getEnv("APPDATA") / "nimmux" / "session.json"
  else:
    getEnv("HOME") / ".local" / "share" / "nimmux" / "session.json"

proc saveSession*(ws: Workspace; path: string) =
  createDir(path.parentDir())
  writeFile(path, $ws.toJson())

proc saveSession*(ws: Workspace) = saveSession(ws, defaultSessionPath())

proc loadSession*(path: string): Workspace =
  if not fileExists(path): return newWorkspace()
  fromJson(parseJson(readFile(path)))

proc loadSession*(): Workspace = loadSession(defaultSessionPath())
