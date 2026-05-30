## Split-tree layout: leaves hold terminal state, nodes divide space.

import vterm
when defined(windows): import pty_win
else:                   import pty_posix

type
  SplitDir* = enum Vertical, Horizontal

  PaneKind* = enum Leaf, Split

  Pane* = ref object
    case kind*: PaneKind
    of Leaf:
      id*:  int
      term*: Terminal
      pty*:  Pty
      buf*:  seq[byte]
    of Split:
      dir*:           SplitDir
      ratio*:         float32   # fraction given to `first` child
      first*, second*: Pane

  Rect* = object
    x*, y*, w*, h*: float32

var nextId = 0

proc newLeafPane*(cols, rows: int32; shell = "cmd.exe"): Pane =
  inc nextId
  result = Pane(kind: Leaf, id: nextId)
  result.term = newTerminal(cols, rows)
  result.pty  = createPty(cols, rows, shell)

proc splitPane*(parent: var Pane; target: Pane; dir: SplitDir): Pane =
  ## Replace `target` in the tree with a Split node containing `target`
  ## and a new sibling pane. Returns the new sibling.
  let sibling = newLeafPane(target.term.cols, target.term.rows)

  proc replace(p: var Pane): bool =
    if p == target:
      p = Pane(kind: Split, dir: dir, ratio: 0.5, first: target, second: sibling)
      return true
    if p.kind == Split:
      if replace(p.first): return true
      if replace(p.second): return true
    false

  discard replace(parent)
  sibling

proc leaves*(root: Pane): seq[Pane] =
  case root.kind
  of Leaf:  result.add(root)
  of Split: result.add(leaves(root.first)); result.add(leaves(root.second))

proc leafRects*(root: Pane; r: Rect): seq[(Pane, Rect)] =
  ## Walk the tree and assign a screen rectangle to each leaf.
  case root.kind
  of Leaf:
    result.add((root, r))
  of Split:
    let (r1, r2) =
      if root.dir == Vertical:
        (Rect(x: r.x, y: r.y, w: r.w * root.ratio, h: r.h),
         Rect(x: r.x + r.w * root.ratio, y: r.y, w: r.w * (1 - root.ratio), h: r.h))
      else:
        (Rect(x: r.x, y: r.y, w: r.w, h: r.h * root.ratio),
         Rect(x: r.x, y: r.y + r.h * root.ratio, w: r.w, h: r.h * (1 - root.ratio)))
    result.add(leafRects(root.first,  r1))
    result.add(leafRects(root.second, r2))

proc closeAll*(root: Pane) =
  case root.kind
  of Leaf:
    var p = root.pty
    p.close()
    var t = root.term
    t.destroy()
  of Split:
    closeAll(root.first)
    closeAll(root.second)
