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
      id*:         int
      cwd*:        string
      scrollback*: string
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

proc maxLeafId(node: Pane): int =
  if node.kind == Leaf: node.id
  else: max(maxLeafId(node.first), maxLeafId(node.second))

proc restoreWorkspace*(root: Pane; focused: int): Workspace =
  result.root    = root
  result.focused = focused
  result.nextId  = maxLeafId(root) + 1

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

proc setLeafCwd*(ws: var Workspace; id: int; cwd: string) =
  proc go(p: Pane) =
    if p.kind == Leaf and p.id == id: p.cwd = cwd
    elif p.kind == Split: go(p.first); go(p.second)
  go(ws.root)

proc leafCwd*(ws: Workspace; id: int): string =
  proc go(p: Pane): string =
    if p.kind == Leaf and p.id == id: return p.cwd
    elif p.kind == Split:
      let r = go(p.first)
      if r.len > 0: return r
      return go(p.second)
  go(ws.root)

proc setLeafScrollback*(ws: var Workspace; id: int; scrollback: string) =
  proc go(p: Pane) =
    if p.kind == Leaf and p.id == id: p.scrollback = scrollback
    elif p.kind == Split: go(p.first); go(p.second)
  go(ws.root)

proc leafScrollback*(ws: Workspace; id: int): string =
  proc go(p: Pane): string =
    if p.kind == Leaf and p.id == id: return p.scrollback
    elif p.kind == Split:
      let r = go(p.first)
      if r.len > 0: return r
      return go(p.second)
  go(ws.root)

type Rect* = object
  x*, y*, w*, h*: float32

proc leafRects*(node: Pane; r: Rect): seq[(int, Rect)] =
  case node.kind
  of Leaf:
    result.add((node.id, r))
  of Split:
    let (r1, r2) =
      if node.dir == Vertical:
        (Rect(x: r.x, y: r.y, w: r.w * node.ratio, h: r.h),
         Rect(x: r.x + r.w * node.ratio, y: r.y, w: r.w * (1 - node.ratio), h: r.h))
      else:
        (Rect(x: r.x, y: r.y, w: r.w, h: r.h * node.ratio),
         Rect(x: r.x, y: r.y + r.h * node.ratio, w: r.w, h: r.h * (1 - node.ratio)))
    result.add(leafRects(node.first, r1))
    result.add(leafRects(node.second, r2))

proc leafRects*(ws: Workspace; r: Rect): seq[(int, Rect)] =
  leafRects(ws.root, r)
