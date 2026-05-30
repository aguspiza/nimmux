## Workspace/pane split-tree model.
## Leaves hold terminal pane IDs; interior nodes are horizontal or vertical splits.

type
  SplitDir* = enum
    Horizontal,  ## left | right
    Vertical     ## top / bottom

  PaneKind* = enum
    Leaf, Split

  Pane* = ref object
    case kind*: PaneKind
    of Leaf:
      id*: int
    of Split:
      dir*:    SplitDir
      ratio*:  float32   ## fraction [0..1] allocated to `first`
      first*:  Pane
      second*: Pane

  Workspace* = object
    root*:    Pane
    focused*: int
    nextId:   int

proc newWorkspace*(): Workspace =
  result.root    = Pane(kind: Leaf, id: 0)
  result.focused = 0
  result.nextId  = 1

proc leaves*(node: Pane): seq[int] =
  if node.kind == Leaf:
    result.add(node.id)
  else:
    result.add(leaves(node.first))
    result.add(leaves(node.second))

proc leaves*(ws: Workspace): seq[int] = leaves(ws.root)

proc split*(ws: var Workspace; id: int; dir: SplitDir): int =
  result = ws.nextId
  inc ws.nextId
  let newLeaf = Pane(kind: Leaf, id: result)

  proc go(p: var Pane) =
    if p.kind == Leaf and p.id == id:
      let old = p
      p = Pane(kind: Split, dir: dir, ratio: 0.5'f32, first: old, second: newLeaf)
    elif p.kind == Split:
      go(p.first)
      go(p.second)

  go(ws.root)

proc setFocus*(ws: var Workspace; id: int) =
  ws.focused = id

proc close*(ws: var Workspace; id: int) =
  if ws.root.kind == Leaf: return

  proc go(p: var Pane): bool =
    if p.kind != Split: return false
    if p.first.kind == Leaf and p.first.id == id:
      p = p.second; return true
    if p.second.kind == Leaf and p.second.id == id:
      p = p.first; return true
    if go(p.first): return true
    if go(p.second): return true

  discard go(ws.root)
  if ws.focused == id:
    ws.focused = ws.leaves()[0]
