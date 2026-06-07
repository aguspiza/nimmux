import std/[os, sets, unittest]
import fontprobe, fontcodepoints

const CascadiaMono = r"C:\Windows\Fonts\CascadiaMono.ttf"
const DejaVuMono   = r"C:\Windows\Fonts\DejaVuSansMono.ttf"
const SegoeSym     = r"C:\Windows\Fonts\seguisym.ttf"

suite "fontprobe":

  test "ASCII is covered by Cascadia Mono":
    if not fileExists(CascadiaMono): skip()
    let cov = fontCoverage(CascadiaMono)
    check 0x0041.int32 in cov  # A
    check 0x0061.int32 in cov  # a
    check 0x0030.int32 in cov  # 0

  test "box drawing covered by Cascadia Mono":
    if not fileExists(CascadiaMono): skip()
    let cov = fontCoverage(CascadiaMono)
    check 0x2500.int32 in cov  # ─
    check 0x2502.int32 in cov  # │
    check 0x256D.int32 in cov  # ╭

  test "math operators NOT covered by Cascadia Mono":
    if not fileExists(CascadiaMono): skip()
    let cov = fontCoverage(CascadiaMono)
    check 0x2295.int32 notin cov  # ⊕
    check 0x2297.int32 notin cov  # ⊗

  test "math operators covered by DejaVu Sans Mono":
    if not fileExists(DejaVuMono): skip()
    let cov = fontCoverage(DejaVuMono)
    check 0x2295.int32 in cov  # ⊕
    check 0x2297.int32 in cov  # ⊗

  test "primary + fallback + ext cover all declared codepoints":
    if not fileExists(CascadiaMono) or not fileExists(DejaVuMono) or
       not fileExists(SegoeSym): skip()
    let primCov = fontCoverage(CascadiaMono).toHashSet()
    let fallCov = fontCoverage(DejaVuMono).toHashSet()
    let extCov  = fontCoverage(SegoeSym).toHashSet()
    let all     = buildTermCodepoints()
    var missing: seq[int32]
    for cp in all:
      if cp notin primCov and cp notin fallCov and cp notin extCov:
        missing.add(cp)
    check missing.len == 0

  test "missing font returns empty coverage":
    let cov = fontCoverage(r"C:\nonexistent\font.ttf")
    check cov.len == 0
