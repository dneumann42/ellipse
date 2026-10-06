## Frame pacing: the scheduler's decisions under a fake clock -- when the
## loop wakes, what `refreshDue` lets through, how resize gestures and
## animations hold the frame rate up and let it drop back to idle.

import std/syncio

import ellipse/platform/pacing

var failures = 0
var passed = 0

proc expect(cond: bool, msg: string) =
  if cond:
    passed += 1
  else:
    failures += 1
    echo "FAILED: ", msg

const Ms = NsPerMs

var mono = 0'i64
var wall = 0'i64

proc fakeMono(): int64 = mono
proc fakeWall(): int64 = wall

proc advance(ns: int64) =
  mono += ns
  wall += ns

proc frame() =
  beginFrame(mono)

proc setup() =
  resetPacing()
  mono = 1_000 * Ms
  wall = 1_700_000_000_000 * Ms + 250 * Ms   # 250 ms past a wall second
  setClock(fakeMono, fakeWall)

proc testIdle() =
  setup()
  expect(frameWanted(mono), "first frame runs without input")
  frame()
  endFrame(false)
  expect(not frameWanted(mono), "nothing requested: idle")
  expect(idleWait(mono) == Never, "idle with no deadline sleeps until input")
  wake()
  expect(frameWanted(mono), "wake() asks for a frame")

proc testEveryInterval() =
  setup()
  frame()
  expect(refreshDue(1, 0, every(1000), false), "interval: due on first check")
  endFrame(false)
  expect(not frameWanted(mono), "interval: not due right after")
  expect(idleWait(mono) == 1000 * Ms, "interval: sleeps a full interval, got " &
    $idleWait(mono))
  advance(400 * Ms)
  wake()                       # an input frame in between
  frame()
  expect(not refreshDue(1, 0, every(1000), false), "interval: not due at 400ms")
  endFrame(false)
  expect(idleWait(mono) == 600 * Ms, "interval: deadline kept after input frame")
  advance(600 * Ms)
  expect(frameWanted(mono), "interval: deadline wakes the loop")
  frame()
  expect(refreshDue(1, 0, every(1000), false), "interval: due at 1000ms")
  endFrame(false)
  # a late frame does not shift the grid
  advance(1300 * Ms)
  frame()
  expect(refreshDue(1, 0, every(1000), false), "interval: due when late")
  endFrame(false)
  expect(idleWait(mono) == 700 * Ms, "interval: grid not shifted by a late frame, got " &
    $(idleWait(mono) div Ms))

proc testWallAligned() =
  setup()
  frame()
  expect(refreshDue(2, 0, every(1000, wall = true), false), "wall: first due")
  endFrame(false)
  # 250 ms into the second: next tick in 750 ms (+1 ms slack)
  expect(idleWait(mono) == 751 * Ms, "wall: aligned to the second, got " &
    $(idleWait(mono) div Ms))

proc testTwoRates() =
  setup()
  frame()
  discard refreshDue(10, 0, every(1000), false)
  discard refreshDue(11, 0, every(250), false)
  endFrame(false)
  expect(idleWait(mono) == 250 * Ms, "two rates: wake for the faster one")
  var slow = 0
  var fast = 0
  var t = 0
  while t < 8:
    advance(idleWait(mono))
    frame()
    if refreshDue(10, 0, every(1000), false): inc slow
    if refreshDue(11, 0, every(250), false): inc fast
    endFrame(false)
    inc t
  expect(fast == 8, "two rates: fast widget ran every wake, got " & $fast)
  expect(slow == 2, "two rates: slow widget kept its own rate, got " & $slow)

proc testEveryFrameAndAnimation() =
  setup()
  frame()
  discard refreshDue(20, 0, everyFrame(), false)
  endFrame(true)
  expect(frameWanted(mono), "everyFrame keeps frames coming")
  setup()
  frame()
  requestFrame()
  endFrame(true)
  expect(frameWanted(mono), "requestFrame: next frame wanted")
  advance(16 * Ms)
  frame()
  expect(frameDelta() > 0.015 and frameDelta() < 0.017,
    "continuing frame: dt is the real gap")
  endFrame(true)
  expect(not frameWanted(mono), "animation stopped asking: idle again")
  advance(5000 * Ms)
  wake()
  frame()
  expect(frameDelta() < 0.02, "first frame after idle: dt is one period, not 5 s")
  endFrame(false)

proc testHover() =
  setup()
  let c = onHover(every(100))
  frame()
  expect(refreshDue(30, 0, c, false), "hover: due on first check")
  endFrame(false)
  expect(not frameWanted(mono) and idleWait(mono) == Never,
    "hover: not hovered -> no timer")
  advance(50 * Ms)
  wake()
  frame()
  expect(refreshDue(30, 0, c, true), "hover: due on enter")
  endFrame(false)
  expect(idleWait(mono) == 100 * Ms, "hover: hovered -> ticks at its rate")
  advance(100 * Ms)
  frame()
  expect(refreshDue(30, 0, c, true), "hover: due on the hover tick")
  endFrame(false)
  advance(10 * Ms)
  wake()
  frame()
  expect(refreshDue(30, 0, c, false), "hover: due once on leave")
  endFrame(false)
  advance(100 * Ms)
  frame()
  expect(not refreshDue(30, 0, c, false), "hover: idle again after leave")
  endFrame(false)

proc testInvalidate() =
  setup()
  frame()
  discard refreshDue(40, 7, onInput(), false)
  endFrame(false)
  expect(not frameWanted(mono), "onInput: never on a timer")
  invalidateOwner(7)
  expect(frameWanted(mono), "invalidate wakes the loop")
  frame()
  expect(refreshDue(40, 7, onInput(), false), "invalidate makes it due")
  expect(not refreshDue(40, 7, onInput(), false), "...once")
  endFrame(false)

proc testInvalidateTag() =
  setup()
  frame()
  discard refreshDue(50, 1, onInput(), false, tag = 99)
  discard refreshDue(51, 2, onInput(), false, tag = 98)
  endFrame(false)
  invalidateTag(99)
  expect(frameWanted(mono), "invalidateTag wakes the loop")
  frame()
  expect(refreshDue(50, 1, onInput(), false, tag = 99), "invalidateTag: tagged guard due")
  expect(not refreshDue(51, 2, onInput(), false, tag = 98), "invalidateTag: others not")
  endFrame(false)

proc testResize() =
  setup()
  frame()
  endFrame(true)
  advance(500 * Ms)
  noteResize(mono)
  expect(frameWanted(mono), "resize: first event wakes")
  frame()
  expect(resizeStarted(), "resize: first frame knows it started")
  expect(resizing(), "resize: gesture active")
  endFrame(true)
  advance(16 * Ms)
  frame()
  expect(not resizeStarted(), "resize: started only on the first frame")
  endFrame(true)
  advance(100 * Ms)
  expect(frameWanted(mono), "resize: vsync frames while gesture lasts")
  advance(150 * Ms)
  expect(frameWanted(mono), "resize: settle frame after the window held still")
  frame()
  expect(resizeFinished() and not resizing(), "resize: finished on the settle frame")
  endFrame(true)
  expect(not frameWanted(mono), "resize: idle after settling")

proc testPacing() =
  setup()
  setRefreshPeriod(16 * Ms)
  frame()
  endFrame(false)
  expect(earliestFrameStart(true) == mono + 16 * Ms,
    "pace: a frame that did not present waits a period")
  frame()
  endFrame(true)
  expect(earliestFrameStart(true) == mono + 8 * Ms,
    "pace: a vsynced present already paced (half-period floor)")
  expect(earliestFrameStart(false) == mono + 16 * Ms, "pace: no vsync, timer pace")

proc testMotion() =
  setup()
  frame()
  endFrame(false)
  setMotionFilter(proc (x, y: float32; down: bool): bool {.closure.} =
    x > 100.0)
  expect(not motionWakes(10.0, 10.0, false), "motion: same hover set sleeps")
  expect(motionWakes(150.0, 10.0, false), "motion: hover change wakes")
  expect(motionWakes(10.0, 10.0, true), "motion: held button always wakes")
  frame()
  trackPointer()
  endFrame(false)
  expect(motionWakes(10.0, 10.0, false), "motion: tracking frame wakes on any move")
  setMotionFilter(nil)

testIdle()
testEveryInterval()
testWallAligned()
testTwoRates()
testEveryFrameAndAnimation()
testHover()
testInvalidate()
testInvalidateTag()
testResize()
testPacing()
testMotion()

echo "pacing_test: ", passed, " passed, ", failures, " failed"
if failures > 0:
  quit(1)
