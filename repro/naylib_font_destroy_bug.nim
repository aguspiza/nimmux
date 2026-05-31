## naylib bug: Font =destroy fires after closeWindow(), crashing on Linux.
##
## Root cause
## ----------
## naylib declares:
##
##   proc `=destroy`*(x: Font) = unloadFont(x)
##
## `unloadFont` calls Raylib's UnloadFont which calls UnloadTexture which
## issues OpenGL calls (glDeleteTextures).  When a Font is declared as a
## local variable in the same scope as `closeWindow()`, Nim/ORC calls
## =destroy AFTER closeWindow() returns — by which point the OpenGL context
## has been destroyed on Linux, causing a SIGSEGV.
##
## The same problem affects Texture and RenderTexture.
##
## Suggested fix (one line in naylib/raylib.nim)
## -----------------------------------------------
##   proc `=destroy`*(x: Font) =
##     if isFontValid(x): unloadFont(x)   # guard added
##
## This makes the destructor a no-op when the font has already been
## unloaded (or when the context is gone), matching standard RAII practice.
##
## Workaround
## ----------
## Wrap all Raylib resource allocations in a block so their =destroy hooks
## fire before closeWindow():
##
##   initWindow(...)
##   block:
##     let font = loadFont(...)
##     ...
##   closeWindow()  ← runs after =destroy(font)
##
## How to reproduce
## ----------------
##   nim c -r repro/naylib_font_destroy_bug.nim        # prints args then crashes
##   nim c -r repro/naylib_font_destroy_bug.nim fixed  # exits cleanly

import raylib, std/[os, strutils]

const candidates = when defined(windows): [
    r"C:\Windows\Fonts\consola.ttf",
    r"C:\Windows\Fonts\lucon.ttf",
    r"C:\Windows\Fonts\cour.ttf",
  ] else: [
    "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
    "/usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf",
    "/usr/share/fonts/truetype/ubuntu/UbuntuMono-R.ttf",
  ]

proc findFont(): string =
  for p in candidates:
    if fileExists(p): return p
  quit("no usable font found for this repro", 1)

# ── buggy: font outlives closeWindow() ───────────────────────────────────────

proc buggy() =
  setTraceLogLevel(TraceLogLevel.Error)
  initWindow(200, 100, "naylib font =destroy bug")
  let font = loadFont(findFont(), 16, 512)
  discard font  # suppress unused warning
  closeWindow()
  # =destroy(font) fires HERE — OpenGL context already destroyed on Linux
  # → SIGSEGV: Illegal storage access (Attempt to read from nil?)

# ── fixed: block scope ensures =destroy fires before closeWindow() ───────────

proc fixed() =
  setTraceLogLevel(TraceLogLevel.Error)
  initWindow(200, 100, "naylib font =destroy fixed")
  block:
    let font = loadFont(findFont(), 16, 512)
    discard font
    # =destroy(font) fires here when block exits — window still open, OK
  closeWindow()

# ── main ─────────────────────────────────────────────────────────────────────

let runFixed = paramCount() > 0 and paramStr(1) == "fixed"
if runFixed:
  echo "running fixed version (block scope)..."
  fixed()
  echo "exited cleanly"
else:
  echo "running buggy version (font outlives closeWindow)..."
  echo "on Linux this crashes with SIGSEGV on exit"
  buggy()
  echo "if you see this, the bug may be masked by your driver/platform"
