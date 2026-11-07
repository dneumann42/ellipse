## Tests for `ellipse_ui/keys`: chord parsing and matching, keymap dispatch,
## modal layering, and the routing that takes a bound key away from the
## widgets. Headless: synthetic key events through `pushKeyEvent`, the
## keymaps run by hand after `beginInputFrame`, as `updateUI` runs them.

import std/syncio

import ellipse/platform/platform
import ellipse_ui/keys

var failures = 0
var passed = 0

proc expect(cond: bool, msg: string) =
  if cond:
    passed += 1
  else:
    failures += 1
    echo "FAILED: ", msg

var log = ""
var dialogUp = false

proc note(s: string): KeyAction =
  result = proc () {.closure.} = log.add s

proc dialogOpen(): bool = dialogUp

proc step(evs: seq[KeyEvent]): seq[KeyEvent] =
  ## One input frame: push, open the frame, run the keymaps, and return
  ## what the widgets would see.
  for ev in evs:
    pushKeyEvent ev
  beginInputFrame()
  runKeymaps()
  keyEvents()

proc chord(ch: char, ctrl = true, shift = false, alt = false): KeyEvent =
  KeyEvent(kind: kevLetter, ch: ch, ctrl: ctrl, shift: shift, alt: alt)

proc main() =
  # --- parsing --------------------------------------------------------------------
  let cs = parseChord("Ctrl+Shift+S")
  expect(cs.kind == kevLetter and cs.ch == 's' and cs.ctrl and cs.shift and
    not cs.alt, "parse: Ctrl+Shift+S")
  expect(parseChord("alt+f4").kind == kevF4 and parseChord("alt+f4").alt,
    "parse: names are case-insensitive")
  expect(parseChord("Ctrl++").ch == '+' and parseChord("Ctrl+Plus").ch == '+',
    "parse: Ctrl++ and Ctrl+Plus are the plus key")
  expect(parseChord("Ctrl+/").ch == '/', "parse: Ctrl+/")
  expect(parseChord("PgDn").kind == kevPageDown, "parse: PgDn alias")
  expect(parseChord("?").kind == kevText and parseChord("?").ch == '?',
    "parse: a bare symbol is typed text")
  expect(parseChord("Hyper+X").kind == kevNone, "parse: unknown modifier")
  expect(parseChord("Ctrl+Banana").kind == kevNone, "parse: unknown key")

  # --- matching -------------------------------------------------------------------
  expect(matches(chord('s'), parseChord("Ctrl+S")), "match: Ctrl+S")
  expect(not matches(chord('s', shift = true), parseChord("Ctrl+S")),
    "match: Shift is significant")
  expect(matches(chord('='), parseChord("Ctrl+Plus")) and
      matches(chord('=', shift = true), parseChord("Ctrl+Plus")) and
      matches(chord('+'), parseChord("Ctrl+Plus")),
    "match: Ctrl+Plus takes the '=' key and the keypad +")
  expect(matches(KeyEvent(kind: kevF3, shift: true), parseChord("Shift+F3")) and
      not matches(KeyEvent(kind: kevF3), parseChord("Shift+F3")),
    "match: named keys compare modifiers")
  expect(matches(KeyEvent(kind: kevText, text: "?"), parseChord("?")),
    "match: typed text")

  # --- dispatch & routing ---------------------------------------------------------
  var app = Keymap(name: "app", active: proc (): bool = not dialogUp)
  app.bindKey("Ctrl+F", note("find "))
  app.bindKey("Ctrl+N", proc () =
    log.add "new "
    dialogUp = true)                    # a chord that opens a dialog
  app.bindKey("F3", note("next "))
  installKeymap(app)
  var dialog = Keymap(name: "dialog", active: dialogOpen, modal: true)
  dialog.bindKey("Enter", proc () =
    log.add "ok "
    dialogUp = false)
  dialog.bindKey("Escape", note("cancel "))
  installKeymap(dialog)

  log = ""
  var seen = step(@[chord('f'), KeyEvent(kind: kevText, text: "x"),
                    KeyEvent(kind: kevF3)])
  expect(log == "find next ", "dispatch: bound chords run, got '" & log & "'")
  expect(seen.len == 1 and seen[0].kind == kevText,
    "routing: bound keys leave the widget stream, " & $seen.len & " left")

  log = ""
  seen = step(@[KeyEvent(kind: kevEnter)])
  expect(log == "" and seen.len == 1,
    "dispatch: an inactive modal map lets Enter through")

  # Ctrl+N opens the dialog mid-frame: the rest of the frame is the
  # dialog's, so its Ctrl+F is dead and Escape is the dialog's.
  log = ""
  seen = step(@[chord('n'), chord('f'), KeyEvent(kind: kevEscape),
                KeyEvent(kind: kevText, text: "q")])
  expect(log == "new cancel ",
    "modal: keys after the opening chord go to the dialog, got '" & log & "'")
  expect(seen.len == 2 and seen[0].kind == kevLetter and seen[0].ch == 'f',
    "modal: the app's chord reaches the dialog's fields unrun, " & $seen.len)

  log = ""
  discard step(@[KeyEvent(kind: kevEnter), chord('f')])
  expect(log == "ok find ", "modal: closing the dialog hands keys back, got '" &
    log & "'")

  installKeymap(Keymap(name: "app"))   # same name: replaced in place, empty
  log = ""
  seen = step(@[chord('f')])
  expect(log == "" and seen.len == 1, "install: a same-name keymap replaces it")
  uninstallKeymap("dialog")
  clearKeymaps()
  seen = step(@[KeyEvent(kind: kevEnter)])
  expect(seen.len == 1, "clear: no keymaps, nothing taken")

  # Key sequences: "Ctrl+X b" waits after its prefix, like Emacs.
  var emacs = Keymap(name: "emacs")
  emacs.bindKey("Ctrl+X b", note("buffers"))
  emacs.bindKey("Ctrl+X Ctrl+S", note("save"))
  emacs.bindKey("Ctrl+K", note("kill"))
  installKeymap(emacs)
  expect(parseKeys("Ctrl+X b").len == 2, "parseKeys: two chords")
  expect(parseKeys("Ctrl+X Bogus+q").len == 0, "parseKeys: a bad chord spoils it")
  log = ""
  seen = step(@[chord('x')])
  expect(log == "" and seen.len == 0, "sequence: the prefix is taken and waits")
  expect(pendingKeys() == "Ctrl+X", "sequence: the prefix is pending: " & pendingKeys())
  seen = step(@[KeyEvent(kind: kevText, text: "b")])
  expect(log == "buffers" and seen.len == 0, "sequence: the second key runs it")
  expect(pendingKeys() == "", "sequence: done, nothing pending")
  log = ""
  seen = step(@[chord('x'), chord('s')])
  expect(log == "save", "sequence: both keys in one frame")
  log = ""
  seen = step(@[chord('x'), KeyEvent(kind: kevText, text: "q")])
  expect(log == "" and seen.len == 0, "sequence: an unbound continuation is swallowed")
  expect(pendingKeys() == "", "sequence: ...and cancels the prefix")
  seen = step(@[KeyEvent(kind: kevText, text: "b")])
  expect(log == "" and seen.len == 1, "sequence: a lone continuation is just a key")
  seen = step(@[chord('k')])
  expect(log == "kill", "sequence: single chords still work beside sequences")
  log = ""
  discard step(@[chord('x')])
  cancelKeySequence()
  seen = step(@[KeyEvent(kind: kevText, text: "b")])
  expect(log == "" and seen.len == 1, "sequence: cancelKeySequence forgets the prefix")
  clearKeymaps()

  echo "keys_test: ", passed, " passed, ", failures, " failed"
  if failures > 0:
    quit 1

when isMainModule:
  main()
