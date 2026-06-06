import std/unittest
import fontcodepoints

suite "fontcodepoints":

  test "covers all declared ranges":
    let cps = buildTermCodepoints()

    const ranges = [
      (0x0020, 0x007E, "printable ASCII"),
      (0x00A0, 0x00FF, "Latin-1 supplement"),
      (0x0100, 0x017F, "Latin Extended-A"),
      (0x2000, 0x205F, "general punctuation"),
      (0x2100, 0x214F, "letterlike symbols"),
      (0x2190, 0x21FF, "arrows"),
      (0x2200, 0x22FF, "math operators"),
      (0x2300, 0x23FF, "misc technical"),
      (0x2500, 0x257F, "box drawing"),
      (0x2580, 0x259F, "block elements"),
      (0x25A0, 0x25FF, "geometric shapes"),
      (0x2600, 0x26FF, "misc symbols"),
      (0x2700, 0x27BF, "dingbats"),
      (0x2800, 0x28FF, "braille"),
    ]

    for (lo, hi, name) in ranges:
      for cp in lo..hi:
        check cp.int32 in cps
