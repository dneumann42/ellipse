## The frame pacer inside the real app loop, headless: `start` must sleep
## between widget deadlines, ignore pointer motion that changes nothing,
## wake for motion that does, and hold the frame rate up through a resize
## gesture -- counted with the pacer's own frame statistics.

import std/[syncio, envvars]

import clay
import ellipse/platform/platform
import ellipse/platform/renderer
import ellipse_ui/ui

var failures = 0
var passed = 0

proc expect(cond: bool, msg: string) =
  if cond:
    passed += 1
  else:
    failures += 1
    echo "FAILED: ", msg

const Ms = 1_000_000'i64

var tickText = ""
var ticks = 0
var frames = 0
var runStart = 0'i64
var mode = 0
var steps = 0
var sawResizeStart = 0
var sawResizeEnd = false

widget Ticker():
  refresh every(200):
    inc ticks
    tickText = "tick " & $ticks
  text(tickText)

widget Prober():
  ## Pushes one pointer move every 50 ms: mode 1 keeps it inside box A,
  ## mode 2 alternates between A and B.
  refresh every(50):
    inc steps
    if mode == 1:
      pushSdlMotion(20.0'f32 + float32(steps), 20.0)
    else:
      pushSdlMotion(if steps mod 2 == 0: 20.0'f32 else: 320.0'f32, 20.0)
    if steps > 10:
      quit()
  text("probe")

proc update() {.raises.} =
  inc frames
  updateUI()
  if resizeStarted():
    inc sawResizeStart
  if resizeFinished() and mode == 3:
    sawResizeEnd = true
    quit()
  layout:
    clay "root", row(width = grow(), height = grow()).bg(bgColor):
      clay "a", row(width = fixedPx(200), height = fixedPx(100)).bg(panelBg):
        if mode == 0:
          Ticker()
        elif mode == 1 or mode == 2:
          Prober()
      clay "b", row(width = fixedPx(200), height = fixedPx(100)).bg(panelBg):
        text("b")
  if mode == 0 and monoNow() - runStart > 1050 * Ms:
    quit()

proc render() {.raises.} =
  drawCommands()

proc run(m: int): FrameStats {.raises.} =
  mode = m
  frames = 0
  steps = 0
  discard takeStats()
  runStart = monoNow()
  wake()
  start(update, render)
  takeStats()

proc main() {.raises.} =
  putEnv("SDL_VIDEODRIVER", "offscreen")
  bootup()

  # 1. a 200 ms ticker alone: ~6 ticks, each one frame + one settle frame,
  #    instead of the ~63 frames a fixed 60 Hz loop runs in that time.
  let idle = run(0)
  expect(ticks >= 5 and ticks <= 7, "ticker: ~6 refreshes in 1.05 s, got " & $ticks)
  expect(idle.frames <= 16, "ticker: loop sleeps between ticks, ran " &
    $idle.frames & " frames")
  expect(idle.presents <= ticks + 2, "ticker: presents only changed frames, got " &
    $idle.presents)

  # 2. pointer moves that stay inside one box: no input frames.
  pushSdlMotion(20.0, 20.0)
  let still = run(1)
  expect(still.inputWakes <= 2, "motion inside one box: no wakes, got " &
    $still.inputWakes)
  expect(still.presents <= 2, "motion inside one box: nothing repainted, got " &
    $still.presents)

  # 3. pointer moves across boxes: every move wakes a frame.
  let across = run(2)
  expect(across.inputWakes >= 8, "motion across boxes: wakes, got " &
    $across.inputWakes)

  # 4. a resize gesture: frames run continuously from the first event until
  #    the window holds still, then the settle frame ends it.
  mode = 3
  pushSdlResize(1000, 600)
  let rs = run(3)
  expect(sawResizeStart == 1, "resize: one gesture start, got " & $sawResizeStart)
  expect(sawResizeEnd, "resize: the gesture settles")
  expect(rs.resizeFrames >= 6, "resize: frames kept running through the gesture, got " &
    $rs.resizeFrames)

  echo "pacing_loop_test: ", passed, " passed, ", failures, " failed"

when isMainModule:
  try:
    main()
  except ErrorCode:
    echo "pacing_loop_test: error"
    failures += 1
  if failures > 0:
    quit(1)
