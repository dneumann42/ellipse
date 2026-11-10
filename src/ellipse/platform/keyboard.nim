## Polled keyboard state. The scancode names sdl3 uses stop in this file:
## a game asks for keys by name and never imports sdl3 itself, so the input
## backend can be swapped without touching the game.
{.push gcsafe.}


import sdl3

type
  Key* = enum
    ## The keys worth holding down, named for what is printed on the cap.
    ## Letters and digits name themselves; the rest carry the word a manual
    ## would use (`keyF12`, `keyLeft`, `keyLShift`, `keyRightBracket`).
    keyA, keyB, keyC, keyD, keyE, keyF, keyG, keyH, keyI, keyJ, keyK, keyL,
    keyM, keyN, keyO, keyP, keyQ, keyR, keyS, keyT, keyU, keyV, keyW, keyX,
    keyY, keyZ,
    key1, key2, key3, key4, key5, key6, key7, key8, key9, key0,
    keyF1, keyF2, keyF3, keyF4, keyF5, keyF6, keyF7, keyF8, keyF9, keyF10,
    keyF11, keyF12,
    keyUp, keyDown, keyLeft, keyRight,
    keySpace, keyEnter, keyEscape, keyTab, keyBackspace, keyDelete, keyInsert,
    keyHome, keyEnd, keyPageUp, keyPageDown,
    keyMinus, keyEquals, keyLeftBracket, keyRightBracket, keyBackslash,
    keySemicolon, keyQuote, keyGrave, keyComma, keyPeriod, keySlash,
    keyLShift, keyRShift, keyLCtrl, keyRCtrl, keyLAlt, keyRAlt, keyLGui,
    keyRGui

proc scancodeOf(key: Key): Scancode =
  case key
  of keyA: SCANCODE_A
  of keyB: SCANCODE_B
  of keyC: SCANCODE_C
  of keyD: SCANCODE_D
  of keyE: SCANCODE_E
  of keyF: SCANCODE_F
  of keyG: SCANCODE_G
  of keyH: SCANCODE_H
  of keyI: SCANCODE_I
  of keyJ: SCANCODE_J
  of keyK: SCANCODE_K
  of keyL: SCANCODE_L
  of keyM: SCANCODE_M
  of keyN: SCANCODE_N
  of keyO: SCANCODE_O
  of keyP: SCANCODE_P
  of keyQ: SCANCODE_Q
  of keyR: SCANCODE_R
  of keyS: SCANCODE_S
  of keyT: SCANCODE_T
  of keyU: SCANCODE_U
  of keyV: SCANCODE_V
  of keyW: SCANCODE_W
  of keyX: SCANCODE_X
  of keyY: SCANCODE_Y
  of keyZ: SCANCODE_Z
  of key1: SCANCODE_1
  of key2: SCANCODE_2
  of key3: SCANCODE_3
  of key4: SCANCODE_4
  of key5: SCANCODE_5
  of key6: SCANCODE_6
  of key7: SCANCODE_7
  of key8: SCANCODE_8
  of key9: SCANCODE_9
  of key0: SCANCODE_0
  of keyF1: SCANCODE_F1
  of keyF2: SCANCODE_F2
  of keyF3: SCANCODE_F3
  of keyF4: SCANCODE_F4
  of keyF5: SCANCODE_F5
  of keyF6: SCANCODE_F6
  of keyF7: SCANCODE_F7
  of keyF8: SCANCODE_F8
  of keyF9: SCANCODE_F9
  of keyF10: SCANCODE_F10
  of keyF11: SCANCODE_F11
  of keyF12: SCANCODE_F12
  of keyUp: SCANCODE_UP
  of keyDown: SCANCODE_DOWN
  of keyLeft: SCANCODE_LEFT
  of keyRight: SCANCODE_RIGHT
  of keySpace: SCANCODE_SPACE
  of keyEnter: SCANCODE_RETURN
  of keyEscape: SCANCODE_ESCAPE
  of keyTab: SCANCODE_TAB
  of keyBackspace: SCANCODE_BACKSPACE
  of keyDelete: SCANCODE_DELETE
  of keyInsert: SCANCODE_INSERT
  of keyHome: SCANCODE_HOME
  of keyEnd: SCANCODE_END
  of keyPageUp: SCANCODE_PAGEUP
  of keyPageDown: SCANCODE_PAGEDOWN
  of keyMinus: SCANCODE_MINUS
  of keyEquals: SCANCODE_EQUALS
  of keyLeftBracket: SCANCODE_LEFTBRACKET
  of keyRightBracket: SCANCODE_RIGHTBRACKET
  of keyBackslash: SCANCODE_BACKSLASH
  of keySemicolon: SCANCODE_SEMICOLON
  of keyQuote: SCANCODE_APOSTROPHE
  of keyGrave: SCANCODE_GRAVE
  of keyComma: SCANCODE_COMMA
  of keyPeriod: SCANCODE_PERIOD
  of keySlash: SCANCODE_SLASH
  of keyLShift: SCANCODE_LSHIFT
  of keyRShift: SCANCODE_RSHIFT
  of keyLCtrl: SCANCODE_LCTRL
  of keyRCtrl: SCANCODE_RCTRL
  of keyLAlt: SCANCODE_LALT
  of keyRAlt: SCANCODE_RALT
  of keyLGui: SCANCODE_LGUI
  of keyRGui: SCANCODE_RGUI

proc keyHeld*(key: Key): bool =
  ## Whether `key` is held as the frame stands. False when there is no
  ## keyboard state to read at all -- no window yet, no keyboard on the box.
  var numkeys: cint
  let keys = getKeyboardState(numkeys)
  if keys.isNil:
    return false
  keys[scancodeOf(key).int]
