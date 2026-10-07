## Widgets in terminal mode, headless: frames driven by a script with the
## pointer moving over, pressing and releasing buttons, every frame painted
## through the terminal renderer -- the paths a real terminal session takes.

import std/[syncio, strutils, envvars]

import ellipse_ui/app

var failures = 0
var passed = 0

proc expect(cond: bool, msg: string) =
  if cond:
    passed += 1
  else:
    failures += 1
    echo "FAILED: ", msg

var presses = 0
var checked = false

proc view() {.raises.} =
  clay "root", col(width = grow(), height = grow(), padding = padAll(16),
                   gap = 16).bg(bgColor):
    if button(hashId("ok"), "OK"):
      inc presses
    if button(hashId("tall"), "Tall", height = fixedPx(48)):
      inc presses
    checked = checkbox(hashId("check"), "Check", checked)

proc rowOf(pic: CellBuffer; needle: string): tuple[c, r: int] =
  result = (-1, -1)
  let lines = pic.toPlain.splitLines
  for r in 0 ..< lines.len:
    let c = lines[r].find(needle)
    if c >= 0:
      return (c, r)

proc at(c, r: int): (float32, float32) =
  ((float32(c) + 0.5'f32) * cellWidth, (float32(r) + 0.5'f32) * cellHeight)

proc script() {.closure, raises.} =
  for i in 0 ..< 3:
    frame()
    drawCommands()
  var pic = terminalPicture()
  let shot = pic.toPlain
  expect(shot.contains("OK ▄") and shot.contains("▀▀▀"),
    "button casts a half-block shadow:\n" & shot)
  let ok = rowOf(pic, "OK")
  # hover, press, release on OK; render every frame
  let (x, y) = at(ok.c, ok.r)
  for step in 0 ..< 6:
    setPointer(x, y, step == 2 or step == 3)
    frame()
    drawCommands()
    if step == 3:
      # Held: the face slides one column right on its own row; no shadow.
      let held = terminalPicture()
      let moved = rowOf(held, "OK")
      expect(moved == (ok.c + 1, ok.r), "held button slides right only, " &
        $ok.c & "," & $ok.r & " -> " & $moved.c & "," & $moved.r)
      expect(not held.toPlain.splitLines[ok.r].contains("▄"),
        "held button casts no shadow")
  expect(presses == 1, "a click presses the button once, got " & $presses)
  # sweep the pointer across the whole screen, pressing as it goes
  pic = terminalPicture()
  for r in 0 ..< pic.rows:
    for c in countup(0, pic.cols - 1, 3):
      let (px, py) = at(c, r)
      setPointer(px, py, (r + c) mod 2 == 0)
      frame()
      drawCommands()
  expect(true, "pointer sweep survives")
  echo "tui widgets: ", passed, " passed, ", failures, " failed"
  if failures > 0:
    quit(1)

when isMainModule:
  setTerminalMode(true)
  try:
    putEnv("ELLIPSE_TUI_SIZE", "40x14")
  except:
    discard
  run(App(window: WindowConfig(title: "tui widgets"), view: view,
          debugMode: false, log: false), script)
