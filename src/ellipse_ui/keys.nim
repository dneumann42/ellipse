## Keyboard shortcuts: chords written the way menus print them, gathered
## into keymaps that run before the widget tree sees the keys. See
## `documentation/nim-tutorial.md` §8 (Keymaps and shortcuts).
##
## A binding may be a key *sequence*, chords separated by spaces, as in
## Emacs: `bindKey(m, "Ctrl+X b", ...)`. Its first chord starts the sequence
## and is taken from the widgets; the next key either continues it, finishes
## it (the action runs), or -- bound to nothing after the prefix -- cancels
## it and is swallowed. `pendingKeys` names the prefix typed so far.
{.push gcsafe.}


import std/[syncio, strutils]

import ellipse/platform/platform

type
  Chord* = object
    ## One key with its modifiers. `kind == kevNone` marks a chord that did
    ## not parse.
    kind*: KeyEventKind
    ch*: char      ## the key's character: kevLetter (a chord) or kevText
    ctrl*, shift*, alt*: bool

  KeyAction* = proc () {.closure.}
  KeyWhen* = proc (): bool {.closure.}

  Binding = object
    chords: seq[Chord]   ## one chord, or a sequence
    action: KeyAction

  Keymap* = object
    ## Bindings that run together. `active` (nil: always) switches the
    ## whole map, and `modal` makes it hide the keymaps installed before it
    ## while it is active.
    name*: string
    active*: KeyWhen
    modal*: bool
    bindings: seq[Binding]

var keymaps {.threadvar.}: seq[Keymap]
keymaps = @[]
var pending {.threadvar.}: seq[KeyEvent]
pending = @[]   ## the key sequence typed so far

# --- chords ------------------------------------------------------------------

func lowerAscii(s: string): string =
  result = ""
  for c in s:
    if c >= 'A' and c <= 'Z':
      result.add char(ord(c) + 32)
    else:
      result.add c

func namedKey(name: string): KeyEventKind =
  ## The key a lowercased name means, `kevNone` for none.
  case name
  of "enter", "return": kevEnter
  of "escape", "esc": kevEscape
  of "tab": kevTab
  of "backspace": kevBackspace
  of "delete", "del": kevDelete
  of "insert", "ins": kevInsert
  of "left": kevLeft
  of "right": kevRight
  of "up": kevUp
  of "down": kevDown
  of "home": kevHome
  of "end": kevEnd
  of "pageup", "pgup": kevPageUp
  of "pagedown", "pgdn": kevPageDown
  of "f1": kevF1
  of "f2": kevF2
  of "f3": kevF3
  of "f4": kevF4
  of "f5": kevF5
  of "f6": kevF6
  of "f7": kevF7
  of "f8": kevF8
  of "f9": kevF9
  of "f10": kevF10
  of "f11": kevF11
  of "f12": kevF12
  else: kevNone

proc parseChord*(spec: string): Chord =
  ## `"Ctrl+Shift+S"` -> its `Chord`; see the module header for the
  ## syntax. A chord that does not parse has `kind == kevNone`.
  result = Chord(kind: kevNone)
  # Split on '+', but a '+' right after a separator (or alone) is the key
  # itself: "Ctrl++" and "+" both name the plus character.
  var parts: seq[string] = @[]
  var cur = ""
  var i = 0
  while i < spec.len:
    let c = spec[i]
    if c == '+' and cur.len > 0:
      parts.add cur
      cur = ""
    else:
      cur.add c
    inc i
  if cur.len > 0:
    parts.add cur
  if parts.len == 0:
    return
  var ctrl = false
  var shift = false
  var alt = false
  var j = 0
  while j < parts.len - 1:
    case lowerAscii(parts[j])
    of "ctrl", "control": ctrl = true
    of "shift": shift = true
    of "alt": alt = true
    else: return
    inc j
  let key = parts[^1]
  let lk = lowerAscii(key)
  var ch = '\0'
  if key.len == 1:
    ch = lk[0]
  elif lk == "plus":
    ch = '+'
  elif lk == "minus":
    ch = '-'
  elif lk == "space":
    ch = ' '
  if ch != '\0':
    if ctrl or alt:
      result = Chord(kind: kevLetter, ch: ch, ctrl: ctrl, shift: shift, alt: alt)
    else:
      # Typed text: Shift is in the character already ("A", "?").
      result = Chord(kind: kevText, ch: (if key.len == 1: key[0] else: ch))
    return
  let k = namedKey(lk)
  if k != kevNone:
    result = Chord(kind: k, ctrl: ctrl, shift: shift, alt: alt)

proc matches*(ev: KeyEvent, c: Chord): bool =
  ## Whether the key event is the chord: same key, same modifiers.
  case c.kind
  of kevNone:
    false
  of kevLetter:
    if ev.kind != kevLetter or ev.ctrl != c.ctrl or ev.alt != c.alt:
      false
    elif c.ch == '+':
      ev.ch == '+' or ev.ch == '='   # Ctrl+Plus: the '=' key, shift or not
    else:
      ev.ch == c.ch and ev.shift == c.shift
  of kevText:
    ev.kind == kevText and ev.text.len == 1 and ev.text[0] == c.ch
  else:
    ev.kind == c.kind and ev.ctrl == c.ctrl and ev.alt == c.alt and
      ev.shift == c.shift

proc parseKeys*(spec: string): seq[Chord] =
  ## `"Ctrl+X b"` -> its chords, in order. Empty when any chord does not
  ## parse (or there is none).
  for part in spec.split(' '):
    if part.len == 0:
      continue
    let c = parseChord(part)
    if c.kind == kevNone:
      return @[]
    result.add c

func describe(ev: KeyEvent): string =
  ## A key event the way a chord is written: `Ctrl+X`, `b`.
  if ev.ctrl: result.add "Ctrl+"
  if ev.alt: result.add "Alt+"
  if ev.shift and ev.kind != kevText: result.add "Shift+"
  case ev.kind
  of kevLetter: result.add (if ev.ch in {'a'..'z'}: char(ord(ev.ch) - 32) else: ev.ch)
  of kevText: result.add ev.text
  else:
    let name = $ev.kind
    result.add (if name.startsWith("kev"): name[3 .. ^1] else: name)

proc pendingKeys*(): string =
  ## The key sequence typed so far, `""` when none is: "Ctrl+X".
  for i, ev in pending:
    if i > 0: result.add ' '
    result.add describe(ev)

proc cancelKeySequence*() =
  ## Forget a half-typed key sequence.
  pending.setLen(0)

proc pressed*(chord: string): bool =
  ## The chord went down this input frame -- a one-off check against the
  ## frame's (routed) key events, for code that doesn't keep a keymap.
  let c = parseChord(chord)
  let evs = keyEvents()
  for ev in evs:
    if matches(ev, c):
      return true
  false

# --- keymaps -----------------------------------------------------------------

proc bindKey*(m: var Keymap, chord: string, action: KeyAction) =
  ## Run `action` when `chord` goes down while `m` is active; `chord` may be
  ## a space-separated sequence ("Ctrl+X b"). A chord that does not parse is
  ## a programming error: it is reported and skipped.
  let cs = parseKeys(chord)
  if cs.len == 0:
    echo "ellipse_ui/keys: keymap `", m.name, "`: cannot parse chord `",
      chord, "`"
    return
  m.bindings.add Binding(chords: cs, action: action)

proc installKeymap*(m: Keymap) =
  ## Put `m` on top of the keymap stack, replacing an installed keymap of
  ## the same name in place (it keeps its position).
  for i in 0 ..< keymaps.len:
    if keymaps[i].name == m.name:
      keymaps[i] = m
      return
  keymaps.add m

proc uninstallKeymap*(name: string) =
  var kept: seq[Keymap] = @[]
  for m in keymaps:
    if m.name != name:
      kept.add m
  keymaps = kept

proc clearKeymaps*() =
  keymaps.setLen(0)

proc isActive(m: Keymap): bool =
  let p = m.active
  if p == nil:
    return true
  p()

proc dispatchKey(ev: KeyEvent): bool =
  ## Run the first binding the typed sequence (`pending` and `ev`) matches,
  ## newest active keymap first, no further down than the topmost active
  ## modal one. A strict prefix of a binding waits for more keys; a key
  ## that ends a prefix nothing continues is swallowed.
  var typed = pending
  typed.add ev
  var prefix = false
  var i = keymaps.len - 1
  while i >= 0:
    if isActive(keymaps[i]):
      let bs = keymaps[i].bindings
      for b in bs:
        if b.chords.len < typed.len:
          continue
        var same = true
        for k in 0 ..< typed.len:
          if not matches(typed[k], b.chords[k]):
            same = false
            break
        if not same:
          continue
        if b.chords.len == typed.len:
          pending.setLen(0)
          let act = b.action
          act()
          return true
        prefix = true
      if keymaps[i].modal:
        break
    dec i
  if prefix:
    pending = typed
    return true
  if pending.len > 0:
    pending.setLen(0)
    return true
  false

proc runKeymaps*() =
  ## Offer this input frame's keys to the installed keymaps and take out
  ## the ones a binding handled. `updateUI` calls it; a hand-written frame
  ## loop calls it after `beginInputFrame`, before laying out.
  if keymaps.len == 0:
    return
  let evs = keyEvents()
  if evs.len == 0:
    return
  var kept: seq[KeyEvent] = @[]
  var taken = false
  for ev in evs:
    if dispatchKey(ev):
      taken = true
    else:
      kept.add ev
  if taken:
    setKeyEvents(kept)
