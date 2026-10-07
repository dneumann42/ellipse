## Terminal input decoding: the bytes a terminal sends turned into the
## events the UI reads -- `KeyEvent`s, SGR mouse reports, bracketed paste,
## focus changes.
##
## Understood: UTF-8 text, C0 controls (Ctrl+letter), ESC-prefixed Alt
## chords, CSI and SS3 cursor/editing/function keys with xterm modifier
## parameters, the kitty keyboard protocol's `CSI code;mods u` (enabled with
## the "disambiguate" flag, so Esc, Tab and Ctrl+I stay apart), SGR mouse
## (`CSI < b;x;y M/m`), bracketed paste (`CSI 200~ .. CSI 201~`) and focus
## reports (`CSI I` / `CSI O`).
##
## Bytes that end mid-sequence wait in the decoder for the next read; a
## lone ESC at the end of a read is the Escape key (escape sequences
## arrive whole in practice).

import ../platform/keyevents
import ./cellwidth

type
  MouseButton* = enum
    mbLeft, mbMiddle, mbRight, mbNone

  TermEventKind* = enum
    teKey, teMouse, teWheel, tePaste, teFocus

  TermEvent* = object
    shift*, alt*, ctrl*: bool ## mouse and wheel: modifiers held
    case kind*: TermEventKind
    of teKey:
      key*: KeyEvent
    of teMouse:
      col*, row*: int         ## 0-based cell
      button*: MouseButton
      pressed*: bool          ## press (or drag motion with a button held)
      motion*: bool           ## a move, not a press/release
    of teWheel:
      dx*, dy*: float32       ## SDL's sense: +y scrolls up / away
      wcol*, wrow*: int
    of tePaste:
      text*: string
    of teFocus:
      focused*: bool

  Decoder* = object
    pending: string           ## an unfinished sequence from the last feed
    pasting: bool
    paste: string

proc key(kind: KeyEventKind; mods: int = 0): TermEvent =
  ## `mods` is xterm's modifier bitmask: 1 shift, 2 alt, 4 ctrl.
  TermEvent(kind: teKey, key: KeyEvent(kind: kind, shift: (mods and 1) != 0,
    alt: (mods and 2) != 0, ctrl: (mods and 4) != 0))

proc chord(ch: char; mods: int): TermEvent =
  result = key(kevLetter, mods)
  result.key.ch = ch

proc textEv(s: string): TermEvent =
  TermEvent(kind: teKey, key: KeyEvent(kind: kevText, text: s))

proc control(b: int; mods: int; evs: var seq[TermEvent]) =
  ## A C0 control byte (with Alt when it followed an ESC).
  case b
  of 13, 10: evs.add key(kevEnter, mods)
  of 9: evs.add key(kevTab, mods)
  of 8, 127: evs.add key(kevBackspace, mods)
  of 27: evs.add key(kevEscape, mods)
  of 0: evs.add chord(' ', mods or 4)
  of 1 .. 7, 11, 12, 14 .. 26:
    evs.add chord(char(ord('a') + b - 1), mods or 4)
  of 28: evs.add chord('\\', mods or 4)
  of 29: evs.add chord(']', mods or 4)
  of 31: evs.add chord('/', mods or 4)
  else: discard

proc parseParams(s: string): seq[int] =
  ## "1;5" -> [1, 5]; empty fields are 0, sub-parameters (':') dropped.
  result = @[]
  var cur = 0
  var any = false
  var skipping = false
  for c in s:
    if c == ';':
      result.add cur
      cur = 0
      any = false
      skipping = false
    elif c == ':':
      skipping = true
    elif c >= '0' and c <= '9' and not skipping:
      cur = cur * 10 + (ord(c) - ord('0'))
      any = true
  if any or result.len > 0:
    result.add cur

proc modsOf(params: seq[int]; at: int): int =
  ## xterm sends modifiers as 1 + bitmask.
  if params.len > at and params[at] > 0: params[at] - 1 else: 0

proc tildeKey(n, mods: int; evs: var seq[TermEvent]) =
  case n
  of 1, 7: evs.add key(kevHome, mods)
  of 4, 8: evs.add key(kevEnd, mods)
  of 2: evs.add key(kevInsert, mods)
  of 3: evs.add key(kevDelete, mods)
  of 5: evs.add key(kevPageUp, mods)
  of 6: evs.add key(kevPageDown, mods)
  of 11: evs.add key(kevF1, mods)
  of 12: evs.add key(kevF2, mods)
  of 13: evs.add key(kevF3, mods)
  of 14: evs.add key(kevF4, mods)
  of 15: evs.add key(kevF5, mods)
  of 17: evs.add key(kevF6, mods)
  of 18: evs.add key(kevF7, mods)
  of 19: evs.add key(kevF8, mods)
  of 20: evs.add key(kevF9, mods)
  of 21: evs.add key(kevF10, mods)
  of 23: evs.add key(kevF11, mods)
  of 24: evs.add key(kevF12, mods)
  else: discard

proc letterKey(final: char; mods: int; evs: var seq[TermEvent]) =
  ## The final byte of `CSI 1;m X` / `SS3 X`.
  case final
  of 'A': evs.add key(kevUp, mods)
  of 'B': evs.add key(kevDown, mods)
  of 'C': evs.add key(kevRight, mods)
  of 'D': evs.add key(kevLeft, mods)
  of 'H': evs.add key(kevHome, mods)
  of 'F': evs.add key(kevEnd, mods)
  of 'P': evs.add key(kevF1, mods)
  of 'Q': evs.add key(kevF2, mods)
  of 'R': evs.add key(kevF3, mods)
  of 'S': evs.add key(kevF4, mods)
  of 'Z': evs.add key(kevTab, mods or 1)   # back-tab
  of 'M': evs.add key(kevEnter, mods)      # SS3 M: keypad Enter
  else: discard

proc utf8(cp: int): string =
  result = ""
  if cp < 0x80:
    result.add char(cp)
  elif cp < 0x800:
    result.add char(0xC0 or (cp shr 6))
    result.add char(0x80 or (cp and 0x3F))
  elif cp < 0x10000:
    result.add char(0xE0 or (cp shr 12))
    result.add char(0x80 or ((cp shr 6) and 0x3F))
    result.add char(0x80 or (cp and 0x3F))
  else:
    result.add char(0xF0 or (cp shr 18))
    result.add char(0x80 or ((cp shr 12) and 0x3F))
    result.add char(0x80 or ((cp shr 6) and 0x3F))
    result.add char(0x80 or (cp and 0x3F))

proc kittyKey(code, mods: int; evs: var seq[TermEvent]) =
  ## `CSI code;mods u`: functional keys by their legacy codes; printable
  ## ones become text, or a chord with Ctrl/Alt.
  case code
  of 9: evs.add key(kevTab, mods)
  of 13: evs.add key(kevEnter, mods)
  of 27: evs.add key(kevEscape, mods)
  of 127, 8: evs.add key(kevBackspace, mods)
  of 57414: evs.add key(kevEnter, mods)    # keypad Enter
  of 57441 .. 57454: discard               # bare modifier keys
  else:
    if code < 32:
      control(code, mods, evs)
    elif (mods and (2 or 4)) != 0:
      var ch = if code < 128: char(code) else: '?'
      if ch >= 'A' and ch <= 'Z':
        ch = char(ord(ch) + 32)
      evs.add chord(ch, mods)
    elif code >= 32:
      evs.add textEv(utf8(code))

proc mouse(params: seq[int]; release: bool; evs: var seq[TermEvent]) =
  ## SGR report: button code, 1-based column and row.
  if params.len < 3:
    return
  let b = params[0]
  let col = params[1] - 1
  let row = params[2] - 1
  let shift = (b and 4) != 0
  let alt = (b and 8) != 0
  let ctrl = (b and 16) != 0
  if (b and 64) != 0:
    let dir = b and 3
    var dx = 0'f32
    var dy = 0'f32
    case dir
    of 0: dy = 1
    of 1: dy = -1
    of 2: dx = -1
    else: dx = 1
    evs.add TermEvent(kind: teWheel, dx: dx, dy: dy, wcol: col, wrow: row,
                      shift: shift, alt: alt, ctrl: ctrl)
    return
  let motion = (b and 32) != 0
  let button = MouseButton(b and 3)
  evs.add TermEvent(kind: teMouse, col: col, row: row, button: button,
                    pressed: not release and button != mbNone, motion: motion,
                    shift: shift, alt: alt, ctrl: ctrl)

proc csi(d: var Decoder; body: string; final: char; evs: var seq[TermEvent]) =
  ## One complete `ESC [ body final`.
  if body.len > 0 and body[0] == '<' and (final == 'M' or final == 'm'):
    mouse(parseParams(body.substr(1)), final == 'm', evs)
    return
  if body.len > 0 and (body[0] == '?' or body[0] == '>' or body[0] == '='):
    return   # replies to queries (kitty flags, device attributes)
  let p = parseParams(body)
  case final
  of '~':
    if p.len == 0:
      return
    if p[0] == 200:
      d.pasting = true
      d.paste = ""
    elif p[0] == 201:
      discard
    else:
      tildeKey(p[0], modsOf(p, 1), evs)
  of 'u':
    if p.len > 0:
      kittyKey(p[0], modsOf(p, 1), evs)
  of 'I':
    evs.add TermEvent(kind: teFocus, focused: true)
  of 'O':
    evs.add TermEvent(kind: teFocus, focused: false)
  else:
    letterKey(final, modsOf(p, 1), evs)

proc feed*(d: var Decoder; bytes: string): seq[TermEvent] =
  ## Decode `bytes` (prefixed by whatever an earlier feed left unfinished).
  result = @[]
  let s = d.pending & bytes
  d.pending = ""
  var i = 0
  while i < s.len:
    if d.pasting:
      # Everything up to the end marker is pasted text, verbatim.
      const endMark = "\e[201~"
      var j = i
      var found = -1
      while j + endMark.len <= s.len:
        if s.substr(j, j + endMark.len - 1) == endMark:
          found = j
          break
        inc j
      if found < 0:
        # Keep a possible partial end marker for the next feed.
        let keep = min(endMark.len - 1, s.len - i)
        d.paste.add s.substr(i, s.len - keep - 1)
        d.pending = s.substr(s.len - keep)
        return
      d.paste.add s.substr(i, found - 1)
      result.add TermEvent(kind: tePaste, text: d.paste)
      d.paste = ""
      d.pasting = false
      i = found + endMark.len
      continue
    let b = ord(s[i])
    if b == 27:
      if i + 1 >= s.len:
        result.add key(kevEscape)
        inc i
      elif s[i + 1] == '[':
        # CSI: parameter/intermediate bytes, then a final byte 0x40..0x7E.
        var j = i + 2
        while j < s.len and (ord(s[j]) < 0x40 or ord(s[j]) > 0x7E):
          inc j
        if j >= s.len:
          d.pending = s.substr(i)
          return
        csi(d, s.substr(i + 2, j - 1), s[j], result)
        i = j + 1
      elif s[i + 1] == 'O':
        if i + 2 >= s.len:
          d.pending = s.substr(i)
          return
        letterKey(s[i + 2], 0, result)
        i += 3
      else:
        # ESC + key: that key with Alt.
        let nb = ord(s[i + 1])
        if nb < 32 or nb == 127:
          control(nb, 2, result)
          i += 2
        else:
          let (cp, n) = decodeRune(s, i + 1)
          var ch = if cp < 128: char(cp) else: '?'
          if ch >= 'A' and ch <= 'Z':
            result.add chord(char(ord(ch) + 32), 2 or 1)
          else:
            result.add chord(ch, 2)
          i += 1 + n
    elif b < 32 or b == 127:
      control(b, 0, result)
      inc i
    else:
      # A run of text: one event per character, like a key per press.
      let need = if b >= 0xF0: 4 elif b >= 0xE0: 3 elif b >= 0xC0: 2 else: 1
      if i + need > s.len:
        d.pending = s.substr(i)   # a character split across reads
        return
      let (_, n) = decodeRune(s, i)
      result.add textEv(s.substr(i, i + n - 1))
      i += n
