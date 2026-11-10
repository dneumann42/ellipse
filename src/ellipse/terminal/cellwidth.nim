## Display width of text on a terminal: how many cells each code point
## takes. A compact take on wcwidth -- combining marks and zero-width
## joiners take none, East Asian wide/fullwidth ranges and emoji take two,
## everything else one. Tabs count one (the renderer draws a space); other
## control characters none.
{.push gcsafe.}


func decodeRune*(s: string; i: int): tuple[cp: int32, len: int] =
  ## The code point starting at byte `i` and its byte length. Malformed
  ## bytes decode as U+FFFD, one byte at a time.
  let b0 = int32(ord(s[i]))
  if b0 < 0x80:
    return (b0, 1)
  var need = 0
  var cp = 0'i32
  if (b0 and 0xE0) == 0xC0:
    need = 1
    cp = b0 and 0x1F
  elif (b0 and 0xF0) == 0xE0:
    need = 2
    cp = b0 and 0x0F
  elif (b0 and 0xF8) == 0xF0:
    need = 3
    cp = b0 and 0x07
  else:
    return (0xFFFD'i32, 1)
  if i + need > s.high:
    return (0xFFFD'i32, 1)
  for k in 1 .. need:
    let b = int32(ord(s[i + k]))
    if (b and 0xC0) != 0x80:
      return (0xFFFD'i32, 1)
    cp = (cp shl 6) or (b and 0x3F)
  (cp, need + 1)

func runeWidth*(cp: int32): int =
  ## Cells taken by one code point.
  if cp == 9:
    return 1
  if cp < 32 or (cp >= 0x7F and cp < 0xA0):
    return 0
  if (cp >= 0x0300 and cp <= 0x036F) or (cp >= 0x0483 and cp <= 0x0489) or
      (cp >= 0x0591 and cp <= 0x05BD) or (cp >= 0x0610 and cp <= 0x061A) or
      (cp >= 0x064B and cp <= 0x065F) or (cp >= 0x1AB0 and cp <= 0x1AFF) or
      (cp >= 0x1DC0 and cp <= 0x1DFF) or (cp >= 0x200B and cp <= 0x200F) or
      (cp >= 0x20D0 and cp <= 0x20FF) or (cp >= 0xFE00 and cp <= 0xFE0F) or
      (cp >= 0xFE20 and cp <= 0xFE2F) or (cp >= 0xE0100 and cp <= 0xE01EF) or
      cp == 0x00AD or cp == 0x2060 or cp == 0xFEFF:
    return 0
  if (cp >= 0x1100 and cp <= 0x115F) or (cp >= 0x231A and cp <= 0x231B) or
      (cp >= 0x2329 and cp <= 0x232A) or (cp >= 0x23E9 and cp <= 0x23EC) or
      (cp >= 0x25FD and cp <= 0x25FE) or (cp >= 0x2614 and cp <= 0x2615) or
      (cp >= 0x2648 and cp <= 0x2653) or (cp >= 0x26AA and cp <= 0x26AB) or
      (cp >= 0x26BD and cp <= 0x26BE) or (cp >= 0x26F2 and cp <= 0x26F5) or
      (cp >= 0x2705 and cp <= 0x2705) or (cp >= 0x274C and cp <= 0x274C) or
      (cp >= 0x2753 and cp <= 0x2755) or (cp >= 0x2795 and cp <= 0x2797) or
      (cp >= 0x2B1B and cp <= 0x2B1C) or
      (cp >= 0x2E80 and cp <= 0x303E) or (cp >= 0x3041 and cp <= 0x33FF) or
      (cp >= 0x3400 and cp <= 0x4DBF) or (cp >= 0x4E00 and cp <= 0x9FFF) or
      (cp >= 0xA000 and cp <= 0xA4CF) or (cp >= 0xA960 and cp <= 0xA97F) or
      (cp >= 0xAC00 and cp <= 0xD7A3) or (cp >= 0xF900 and cp <= 0xFAFF) or
      (cp >= 0xFE10 and cp <= 0xFE19) or (cp >= 0xFE30 and cp <= 0xFE6F) or
      (cp >= 0xFF00 and cp <= 0xFF60) or (cp >= 0xFFE0 and cp <= 0xFFE6) or
      (cp >= 0x1F300 and cp <= 0x1F64F) or (cp >= 0x1F680 and cp <= 0x1F6FF) or
      (cp >= 0x1F900 and cp <= 0x1F9FF) or (cp >= 0x1FA70 and cp <= 0x1FAFF) or
      (cp >= 0x20000 and cp <= 0x3FFFD):
    return 2
  1

func displayWidth*(s: string): int =
  ## Cells `s` takes on one terminal line.
  result = 0
  var i = 0
  while i < s.len:
    let (cp, n) = decodeRune(s, i)
    result += runeWidth(cp)
    i += n
