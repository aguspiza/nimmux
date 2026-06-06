## Minimal TrueType cmap reader.
## Checks whether a font file actually has a non-.notdef glyph for each
## codepoint, so we can split the atlas across two fonts at load time.

import fontcodepoints

proc ru16(d: openArray[byte]; o: int): uint16 =
  (d[o].uint16 shl 8) or d[o+1].uint16

proc ru32(d: openArray[byte]; o: int): uint32 =
  (d[o].uint32 shl 24) or (d[o+1].uint32 shl 16) or
  (d[o+2].uint32 shl 8) or d[o+3].uint32

proc tableOffset(d: openArray[byte]; tag: string): int =
  if d.len < 12: return -1
  let n = ru16(d, 4).int
  for i in 0..<n:
    let r = 12 + i * 16
    if r + 16 > d.len: break
    if d[r].char == tag[0] and d[r+1].char == tag[1] and
       d[r+2].char == tag[2] and d[r+3].char == tag[3]:
      return ru32(d, r + 8).int
  -1

proc numGlyphs(d: openArray[byte]): int =
  let off = tableOffset(d, "maxp")
  if off < 0 or off + 6 > d.len: return 0
  ru16(d, off + 4).int

proc hasGlyphFmt4(d: openArray[byte]; base, maxGlyphs: int; cp: uint32): bool =
  let segCount = ru16(d, base + 6).int div 2
  let endBase   = base + 14
  let startBase = endBase + 2 + segCount * 2
  let deltaBase = startBase + segCount * 2
  let rangeBase = deltaBase + segCount * 2
  for i in 0..<segCount:
    let eC = ru16(d, endBase   + i * 2).uint32
    let sC = ru16(d, startBase + i * 2).uint32
    if cp < sC: break
    if cp > eC: continue
    let delta    = ru16(d, deltaBase + i * 2).uint16
    let rangeOff = ru16(d, rangeBase + i * 2).uint16
    var glyphId: uint16
    if rangeOff == 0:
      glyphId = cp.uint16 + delta
    else:
      let idx = rangeBase + i * 2 + rangeOff.int + (cp.int - sC.int) * 2
      if idx + 2 > d.len: return false
      glyphId = (ru16(d, idx).uint16 + delta)
    return glyphId != 0 and glyphId.int < maxGlyphs
  false

proc fontCoverage*(path: string): seq[int32] =
  ## Returns the subset of buildTermCodepoints() that the font actually has.
  let raw = try: readFile(path) except: return @[]
  let d   = cast[seq[byte]](raw)
  if d.len < 12: return @[]

  let maxG    = numGlyphs(d)
  let cmapOff = tableOffset(d, "cmap")
  if cmapOff < 0 or cmapOff + 4 > d.len: return @[]

  let numSub = ru16(d, cmapOff + 2).int
  var fmt4Off = -1
  for i in 0..<numSub:
    let r   = cmapOff + 4 + i * 8
    if r + 8 > d.len: break
    let pid = ru16(d, r)
    let eid = ru16(d, r + 2)
    let off = cmapOff + ru32(d, r + 4).int
    if pid == 0 or (pid == 3 and (eid == 1 or eid == 10)):
      if off + 2 <= d.len and ru16(d, off) == 4:
        fmt4Off = off
        break
  if fmt4Off < 0: return @[]

  for cp in buildTermCodepoints():
    if hasGlyphFmt4(d, fmt4Off, maxG, cp.uint32):
      result.add(cp)
