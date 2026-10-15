# Timings for the game

import sdl3

const
  MaxDeltaTime* = 0.25'f64
  TargetUpdateHz* = 60.0'f64
  FixedUpdateSeconds* = 1.0'f64 / TargetUpdateHz

var currentFrameDeltaSecondsValue = FixedUpdateSeconds

proc secondsBetween*(startCounter, endCounter, frequency: uint64): float64 =
  float64(endCounter - startCounter) / float64(frequency)

proc countersForSeconds*(seconds: float64, frequency: uint64): uint64 =
  max(uint64(seconds * frequency.float64), 1'u64)

proc currentFrameDeltaSeconds*(): float64 =
  currentFrameDeltaSecondsValue

type
  Engine* = object
    frequency, frameStepCounters: uint64
    previousTime, nextFrameCounter: uint64
    firstFrame: bool

proc initEngine*(): Engine =
  result = Engine()
  result.frequency = getPerformanceFrequency()
  result.frameStepCounters = countersForSeconds(FixedUpdateSeconds, result.frequency)
  result.previousTime = getPerformanceCounter()
  result.nextFrameCounter = result.previousTime + result.frameStepCounters
  result.firstFrame = true

proc sleepUntilCounter*(target, frequency: uint64) =
  while true:
    let now = getPerformanceCounter()
    if now >= target:
      break
    let remaining = secondsBetween(now, target, frequency)
    if remaining > 0.003:
      sdl3.delay(uint32(max((remaining * 1000.0).int - 1, 1)))
    elif remaining > 0.001:
      sdl3.delay(0)

proc beginFrame*(engine: var Engine): tuple[started: uint64, dt: float64] =
  let now = getPerformanceCounter()
  result.started = now
  result.dt = min(secondsBetween(engine.previousTime, now, engine.frequency),
                   MaxDeltaTime)
  currentFrameDeltaSecondsValue = result.dt
  engine.previousTime = now

proc endFrame*(engine: var Engine, running: bool) =
  engine.firstFrame = false
  if not running:
    return
  sleepUntilCounter(engine.nextFrameCounter, engine.frequency)
  let now = getPerformanceCounter()
  while engine.nextFrameCounter <= now:
    engine.nextFrameCounter += engine.frameStepCounters
