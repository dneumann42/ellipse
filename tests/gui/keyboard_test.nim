## Integration test for the platform keyboard pipeline: pushes real SDL
## events (text input, keydowns, wheel) onto SDL's queue, lets the app loop
## pump them through `pumpEvents` -> `beginInputFrame`, and checks what the
## widgets would see via `keyEvents`/`wheelDelta`. The synthetic
## `pushKeyEvent` tests in widgets_test.nim skip exactly this plumbing, so
## this is the guard against SDL-side regressions (event types, struct
## layouts, keycode synthesis, the IME-mode gate).
##
## Runs fully headless: forces the offscreen video driver itself.

import std/[syncio, envvars]

import ellipse/platform/platform

var failures = 0
var passed = 0

proc expect(cond: bool, msg: string) =
  if cond:
    passed += 1
  else:
    failures += 1
    echo "FAILED: ", msg

const
  ModS = 0x00000003'i32     # KMOD_SHIFT
  ModC = 0x000000C0'i32     # KMOD_CTRL
  ModNumLock = 0x00001000'i32  # KMOD_NUM

var seenEvents: seq[KeyEvent] = @[]
var seenImeMode: seq[KeyEvent] = @[]
var seenReEnabled: seq[KeyEvent] = @[]
var seenWheel: tuple[x, y: float32]
var phase = 0

proc pushKeyboard(scancode, key, modifiers: int32) =
  pushSdlKeydown(scancode, key, modifiers)

proc update()  =
  beginInputFrame()
  case phase
  of 0:
    seenEvents = keyEvents()
    seenWheel = wheelDelta()
    phase = 1
    # switch to IME mode and press 'a': synthesis must go silent
    setTextInputEnabled(true)
    pushKeyboard(4, 97, 0)
  of 1:
    seenImeMode = keyEvents()
    phase = 2
    setTextInputEnabled(false)
    pushKeyboard(4, 97, 0)         # default mode again: 'a' synthesizes
  of 2:
    seenReEnabled = keyEvents()
    phase = 3
    pushSdlQuit()
  else:
    discard

proc render()  =
  discard

proc main()  =
  putEnv("SDL_VIDEODRIVER", "offscreen")
  initialize()

  # printable via the TEXT_INPUT path, a Ctrl-A chord, Backspace, then two
  # synthesized keydowns: bare 'a' (keycode set) and shift+B (keycode unset,
  # exercising the SDL_GetKeyFromScancode fallback) + a wheel notch down.
  pushSdlTextInput("hi")
  pushKeyboard(4, 1, ModC)         # Ctrl+A -> kevLetter chord, no text
  pushKeyboard(42, 8, 0)           # Backspace
  pushKeyboard(4, 97, 0)           # 'a' -> synthesized kevText
  pushKeyboard(5, 0, ModS)         # B, keycode unset -> keymap fallback
  # Shifted symbols: SDL3 hands these keydowns their *unshifted* keycode
  # ('1', '=', '/', '['); the typed text must still be the symbol.
  pushKeyboard(30, 49, ModS)       # Shift+1 -> "!"
  pushKeyboard(31, 50, ModS)       # Shift+2 -> "@"
  pushKeyboard(46, 61, ModS)       # Shift+= -> "+"
  pushKeyboard(56, 47, ModS)       # Shift+/ -> "?"
  pushKeyboard(47, 91, ModS)       # Shift+[ -> "{"
  pushKeyboard(56, 47, ModC)       # Ctrl+/ -> chord '/'
  pushKeyboard(46, 61, ModC)       # Ctrl+= -> chord '='
  pushKeyboard(93, 0, ModNumLock)  # keypad 5, NumLock on -> "5"
  pushKeyboard(96, 0, 0)           # keypad 8, NumLock off -> Up
  pushKeyboard(73, 0, 0)           # Insert
  pushSdlWheel(0.0, 2.0)

  start(update, render)   # three pumped frames, then the pushed quit lands

  expect(seenEvents.len == 15, "keyboard pump: all fifteen key events arrive, got " &
    $seenEvents.len)
  if seenEvents.len == 15:
    expect(seenEvents[0].kind == kevText and seenEvents[0].text == "hi",
      "keyboard pump: SDL text input reaches keyEvents")
    expect(seenEvents[1].kind == kevLetter and seenEvents[1].ch == 'a' and
        seenEvents[1].ctrl,
      "keyboard pump: Ctrl+A becomes a kevLetter chord")
    expect(seenEvents[2].kind == kevBackspace,
      "keyboard pump: scancode mapping for Backspace")
    expect(seenEvents[3].kind == kevText and seenEvents[3].text == "a",
      "keyboard pump: bare 'a' keydown synthesizes kevText")
    expect(seenEvents[4].kind == kevText and seenEvents[4].text == "B",
      "keyboard pump: shift+B resolves via the keymap fallback, got " &
      $seenEvents[4].text)
    let typed = ["!", "@", "+", "?", "{"]
    for i in 0 ..< typed.len:
      let ev = seenEvents[5 + i]
      expect(ev.kind == kevText and ev.text == typed[i],
        "keyboard pump: shifted symbol types " & typed[i] & ", got " & ev.text)
    expect(seenEvents[10].kind == kevLetter and seenEvents[10].ch == '/' and
        seenEvents[10].ctrl,
      "keyboard pump: Ctrl+/ is a chord on '/'")
    expect(seenEvents[11].kind == kevLetter and seenEvents[11].ch == '=' and
        seenEvents[11].ctrl,
      "keyboard pump: Ctrl+= is a chord on '='")
    expect(seenEvents[12].kind == kevText and seenEvents[12].text == "5",
      "keyboard pump: keypad 5 with NumLock types 5")
    expect(seenEvents[13].kind == kevUp,
      "keyboard pump: keypad 8 without NumLock is Up")
    expect(seenEvents[14].kind == kevInsert,
      "keyboard pump: Insert arrives")
  expect(seenImeMode.len == 0,
    "keyboard pump: IME mode disables keydown synthesis, got " &
    $seenImeMode.len)
  expect(seenReEnabled.len == 1 and seenReEnabled[0].kind == kevText and
      seenReEnabled[0].text == "a",
    "keyboard pump: synthesis returns with IME mode off")
  expect(seenWheel.y == 2.0,
    "keyboard pump: wheel delta survives, got " & $seenWheel.y)

  echo "keyboard_test: ", passed, " passed, ", failures, " failed"
  if failures > 0:
    quit 1

when isMainModule:
  try:
    main()
  except CatchableError:
    echo "keyboard_test aborted by ErrorCode"
    quit 1
