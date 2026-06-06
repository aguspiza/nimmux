## Unicode codepoint ranges loaded into the terminal font atlas.
## Keep in sync with what TUI apps (Claude Code, htop, etc.) actually emit.

proc buildTermCodepoints*(): seq[int32] =
  for c in 0x0020..0x007E: result.add(c.int32)  # printable ASCII
  for c in 0x00A0..0x00FF: result.add(c.int32)  # Latin-1 supplement
  for c in 0x0100..0x017F: result.add(c.int32)  # Latin Extended-A
  for c in 0x2000..0x205F: result.add(c.int32)  # general punctuation • …
  for c in 0x2100..0x214F: result.add(c.int32)  # letterlike symbols ℹ
  for c in 0x2190..0x21FF: result.add(c.int32)  # arrows → ← ↑ ↓
  for c in 0x2200..0x22FF: result.add(c.int32)  # math operators ⊕ ⊗ ⊙
  for c in 0x2300..0x23FF: result.add(c.int32)  # misc technical ⌘ ⌃ ⌥ ⏎
  for c in 0x2500..0x257F: result.add(c.int32)  # box drawing ─│┌┐└┘├┤┬┴┼
  for c in 0x2580..0x259F: result.add(c.int32)  # block elements ▀▄█▌▐
  for c in 0x25A0..0x25FF: result.add(c.int32)  # geometric shapes ●○◆►◄
  for c in 0x2600..0x26FF: result.add(c.int32)  # misc symbols ⚠ ⚡ ✉
  for c in 0x2700..0x27BF: result.add(c.int32)  # dingbats ✓ ✗ ✔ ✘ ❯ ❮
  for c in 0x2800..0x28FF: result.add(c.int32)  # braille (progress bars)
