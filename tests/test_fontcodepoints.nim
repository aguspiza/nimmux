import std/unittest
import fontcodepoints

suite "fontcodepoints":

  test "covers Claude Code / TUI characters":
    let cps = buildTermCodepoints()

    # Characters that were rendering as '?' before the fix.
    # Add new failures here when discovered rather than editing the ranges blindly.
    const mustHave = [
      # box drawing — TUI borders
      (0x2500, "─"), (0x2502, "│"), (0x250C, "┌"), (0x2510, "┐"),
      (0x2514, "└"), (0x2518, "┘"), (0x251C, "├"), (0x2524, "┤"),
      (0x252C, "┬"), (0x2534, "┴"), (0x253C, "┼"),
      # block elements — progress bars, UI fills
      (0x2588, "█"), (0x2591, "░"), (0x2592, "▒"), (0x2593, "▓"),
      (0x258C, "▌"), (0x2590, "▐"),
      # braille — spinner animations ⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏
      (0x280B, "⠋"), (0x2819, "⠙"), (0x2839, "⠹"), (0x2838, "⠸"),
      (0x283C, "⠼"), (0x2834, "⠴"), (0x2826, "⠦"), (0x2827, "⠧"),
      (0x2807, "⠇"), (0x280F, "⠏"),
      # dingbats — status indicators
      (0x2713, "✓"), (0x2717, "✗"), (0x2714, "✔"), (0x2718, "✘"),
      (0x276F, "❯"), (0x276E, "❮"),
      # misc symbols — warnings
      (0x26A0, "⚠"),
      # arrows — navigation, diffs
      (0x2192, "→"), (0x2190, "←"), (0x2191, "↑"), (0x2193, "↓"),
      # math operators — tool output
      (0x2295, "⊕"), (0x2297, "⊗"), (0x2299, "⊙"),
      # misc technical — keyboard glyphs in help text
      (0x2318, "⌘"), (0x2303, "⌃"), (0x2325, "⌥"), (0x23CE, "⏎"),
      # letterlike
      (0x2139, "ℹ"),
      # general punctuation
      (0x2022, "•"), (0x2026, "…"),
    ]

    for (cp, ch) in mustHave:
      check cp.int32 in cps
