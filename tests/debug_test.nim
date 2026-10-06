## Debug mode in the real loop, headless: F1 toggles it and never reaches
## the app, it attributes frames and repaints to widgets, and -- the point --
## it does not make an idle app run: with the overlay up, a static UI gets
## render-only overlay passes, not `update` calls.

import std/[syncio, envvars]

import clay
import ellipse/platform/platform
import ellipse/platform/renderer
import ellipse_ui/ui
import ellipse_ui/debug

var failures = 0
var passed = 0

proc expect(cond: bool, msg: string) =
  if cond:
    passed += 1
  else:
    failures += 1
    echo "FAILED: ", msg

const
  Ms = 1_000_000'i64
  ScanF1 = 58'i32

var mode = 0
var updates = 0
var renders = 0
var sawF1 = false
var runStart = 0'i64
var tickText = ""
var ticks = 0
var shot = ""

widget Ticker():
  refresh every(200):
    inc ticks
    tickText = "tick " & $ticks
  text(tickText)

widget Still():
  text("nothing moves here")

proc update() {.raises.} =
  inc updates
  updateUI()
  let evs = keyEvents()
  for ev in evs:
    if ev.kind == kevF1:
      sawF1 = true
  layout:
    clay "root", col(width = grow(), height = grow(), gap = 8,
                     padding = padAll(16)).bg(bgColor):
      clay "box", row(width = fixedPx(300), height = fixedPx(60),
                      padding = padAll(8)).bg(panelBg):
        if mode == 0:
          Ticker()
        else:
          Still()
  if mode == 0 and monoNow() - runStart > 1200 * Ms:
    quit()

proc render() {.raises.} =
  inc renders
  drawCommands()
  if shot.len > 0:
    discard saveBackbuffer(shot)
    shot = ""
  if mode == 1 and monoNow() - runStart > 1600 * Ms:
    pushSdlQuit()

proc run(m: int) {.raises.} =
  mode = m
  updates = 0
  renders = 0
  runStart = monoNow()
  wake()
  start(update, render)

proc main() {.raises.} =
  putEnv("SDL_VIDEODRIVER", "offscreen")
  bootup()
  installDebugMode()

  pushSdlKeydown(ScanF1, 0x4000003A'i32, 0)
  run(0)
  expect(debugActive(), "F1 turns debug mode on")
  expect(not sawF1, "F1 never reaches the app")
  expect(updates <= 16, "ticker with overlay: still ~2 frames per tick, ran " &
    $updates)
  shot = "build/debug_overlay.bmp"
  wake()
  mode = 0
  runStart = monoNow() - 1150 * Ms   # one more frame, saving the shot
  start(update, render)

  run(1)
  expect(updates <= 3, "idle app with overlay up: no update calls, ran " &
    $updates)
  expect(renders >= updates + 2, "idle app: overlay passes kept rendering (" &
    $renders & " renders, " & $updates & " updates)")

  pushSdlKeydown(ScanF1, 0x4000003A'i32, 0)
  mode = 0
  run(0)
  expect(not debugActive(), "F1 again turns it off")
  expect(not sawF1, "F1 still never reaches the app")

  echo "debug_test: ", passed, " passed, ", failures, " failed"

when isMainModule:
  try:
    main()
  except ErrorCode:
    echo "debug_test: error"
    failures += 1
  if failures > 0:
    quit(1)
