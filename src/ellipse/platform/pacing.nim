## Frame pacing: *when* the app loop runs a frame.
##
## The UI is immediate mode -- every frame re-runs the widget code and lays
## the whole tree out -- so the cheap frame is the one that never runs. The
## loop in `platform.start` sleeps until something asks for a frame:
##
##   - input: keys, clicks, wheel, window events, and pointer motion that
##     changes what the pointer is over (see `setMotionFilter`);
##   - a deadline: `requestFrameAt` / `requestFrameIn`, which widget
##     cadences (`refreshDue`) and the caret blink use to wake on time;
##   - an animation: `requestFrame`, which keeps the *next* frame coming at
##     the display rate (vsync) for as long as something re-requests it;
##   - a live resize gesture (`noteResize`): every frame runs at vsync from
##     the first resize event until the window has held still for
##     `ResizeSettleNs`, then one settling frame;
##   - `wake`: anything else that changed state outside a frame.
##
## Widgets refresh on their own cadence inside whatever frames run: a 1 Hz
## clock and a per-frame title share one loop that wakes at the rate of the
## fastest *due* widget, while `refreshDue` keeps every slower one on its
## own schedule (drift-free, optionally aligned to the wall clock).
##
## Everything here is clock-injectable (`setClock`) and SDL-free, so the
## scheduler is unit-testable without a window.

import std/[monotimes, tables]

## --- clocks ------------------------------------------------------------------

when defined(windows):
  type
    CFileTime {.importc: "FILETIME", header: "<windows.h>".} = object
      dwLowDateTime: uint32
      dwHighDateTime: uint32

  proc c_GetSystemTimePreciseAsFileTime(ft: ptr CFileTime) {.
    importc: "GetSystemTimePreciseAsFileTime", header: "<windows.h>".}
else:
  type
    CTimespec {.importc: "struct timespec", header: "<time.h>".} = object
      tv_sec: int
      tv_nsec: int

  var CLOCK_REALTIME {.importc: "CLOCK_REALTIME", header: "<time.h>".}: int32

  proc c_clock_gettime(clk: int32; ts: ptr CTimespec): int32 {.
    importc: "clock_gettime", header: "<time.h>".}

const
  NsPerMs* = 1_000_000'i64
  NsPerSec* = 1_000_000_000'i64
  Never* = high(int64)
    ## "No deadline": the interval of a cadence that never refreshes on its
    ## own, and the value `nextDeadline` reports when nothing is scheduled.
  ResizeSettleNs* = 200 * NsPerMs
    ## How long the window must go without a resize event before the
    ## resize gesture is considered over.
  MaxFrameDt = 0.05'f32       ## dt clamp: a hitch never jumps animations
  MaxDeadlines = 64

type
  ClockFn* = proc (): int64 {.closure.}

proc systemMono(): int64 = getMonoTime().ticks

proc systemWall(): int64 =
  ## Nanoseconds since the Unix epoch.
  when defined(windows):
    var ft = CFileTime()
    c_GetSystemTimePreciseAsFileTime(addr ft)
    let ticks = (int64(ft.dwHighDateTime) shl 32) or int64(ft.dwLowDateTime)
    (ticks - 116_444_736_000_000_000'i64) * 100   # 100 ns since 1601
  else:
    var ts = CTimespec()
    if c_clock_gettime(CLOCK_REALTIME, addr ts) != 0:
      return 0
    int64(ts.tv_sec) * NsPerSec + int64(ts.tv_nsec)

var
  monoClock: ClockFn = systemMono
  wallClock: ClockFn = systemWall

proc setClock*(mono, wall: ClockFn) =
  ## Replace the monotonic and wall clocks (nanoseconds) -- the seam the
  ## pacing tests drive time through.
  monoClock = mono
  wallClock = wall

proc resetClock*() =
  monoClock = systemMono
  wallClock = systemWall

proc monoNow*(): int64 = monoClock()
proc wallNow*(): int64 = wallClock()

## --- frame state -------------------------------------------------------------

type
  FrameReason* = enum
    ## Why a frame ran (the debug overlay's timeline colours).
    frInput, frTimer, frAnim, frResize, frSettle

type
  FrameStats* = object
    ## Counters since the last `takeStats`, for the debug report.
    frames*: int        ## frames run (update + render)
    presents*: int      ## frames that actually presented pixels
    inputWakes*: int    ## frames woken by input / `wake`
    timerWakes*: int    ## frames woken by a deadline
    animWakes*: int     ## frames requested by `requestFrame`
    resizeFrames*: int  ## frames run inside a resize gesture
    damagePx*: int64    ## pixels repainted by the renderer

var
  frameNs = 0'i64             ## this frame's monotonic stamp
  frameWallNs = 0'i64         ## ... and its wall-clock stamp
  prevFrameNs = 0'i64
  frameDtSec = 1.0'f32 / 60.0'f32
  frameSerial = 0'i64
  periodNs = 16_666_667'i64   ## display refresh period

  wakePending = true          ## input since the last frame (first frame: yes)
  wantNext = false            ## `requestFrame` during this frame
  wantSettle = false          ## `requestSettleFrame` during this frame
  deadlines: seq[int64] = @[] ## pending `requestFrameAt`s, ascending

  resizeActive = false
  resizeBegan = false         ## this frame is the first of a resize gesture
  resizeEnded = false         ## this frame closes a resize gesture
  resizeStartPending = false
  resizeLastNs = 0'i64

  presentWanted = false
  presentedLast = false
  stats = FrameStats()
  reason = frInput
  frameDamagePx = 0'i64
  recordRefresh = false
  refreshedNow: seq[uint64] = @[]   ## owners whose guard ran this frame
  overlayDeadline = Never
  overlayPassOn = false

proc frameNow*(): int64 =
  ## The current frame's monotonic time in ns. Stable for the whole frame,
  ## so every widget due at the same deadline refreshes in the same frame.
  frameNs

proc frameWall*(): int64 =
  ## The current frame's wall-clock time (ns since the Unix epoch).
  frameWallNs

proc frameDelta*(): float32 =
  ## Seconds since the previous frame, for animation integration. The first
  ## frame after an idle stretch reports one display period instead of the
  ## idle time, so an animation never starts with a jump; hitches clamp at
  ## 50 ms.
  frameDtSec

proc frameIndex*(): int64 = frameSerial

proc frameReason*(): FrameReason =
  ## Why the current frame runs.
  reason

proc frameDamage*(): int64 =
  ## Pixels the renderer repainted in the current frame.
  frameDamagePx

proc setRefreshRecording*(on: bool) =
  ## Record which widgets' `refresh` guards run each frame (debug overlay).
  recordRefresh = on
  refreshedNow.setLen(0)

proc refreshedThisFrame*(): seq[uint64] =
  ## Widget keys whose guards ran this frame (with recording on).
  refreshedNow

proc refreshPeriod*(): int64 = periodNs

proc setRefreshPeriod*(ns: int64) =
  ## The display's refresh period (ns), from the platform's display mode.
  if ns > 0:
    periodNs = ns

## --- requests ----------------------------------------------------------------

proc wake*() =
  ## Run a frame as soon as the loop can: state changed outside a frame
  ## (input, a socket, another thread's result picked up by a poll).
  wakePending = true

proc requestFrame*() =
  ## Run the next frame at the display rate. An animation calls this every
  ## frame it is still moving; the loop drops back to idle the first frame
  ## nobody asks.
  wantNext = true

proc requestSettleFrame*() =
  ## One more frame because this one's output changed: immediate-mode
  ## widgets read the previous frame's geometry, so a change is confirmed
  ## by a frame that reproduces it. Like `requestFrame`, but reported as
  ## its own reason.
  wantSettle = true

proc requestFrameAt*(deadline: int64) =
  ## Run a frame no later than the monotonic time `deadline` (ns). Requests
  ## persist until their time passes, are deduplicated, and the earliest
  ## `MaxDeadlines` are kept.
  if deadline == Never:
    return
  var i = 0
  while i < deadlines.len and deadlines[i] < deadline:
    inc i
  if i < deadlines.len and deadlines[i] == deadline:
    return
  deadlines.add deadline
  var j = deadlines.len - 1
  while j > i:
    let moved = deadlines[j - 1]
    deadlines[j] = moved
    dec j
  deadlines[i] = deadline
  if deadlines.len > MaxDeadlines:
    deadlines.setLen(MaxDeadlines)

proc requestFrameIn*(ns: int64) =
  ## `requestFrameAt` relative to the current frame (or now, outside one).
  let base = if frameNs > 0: frameNs else: monoNow()
  requestFrameAt(base + max(ns, 0'i64))

proc nextDeadline*(): int64 =
  ## The earliest pending deadline, `Never` when none.
  if deadlines.len == 0: Never else: deadlines[0]

## --- resize ------------------------------------------------------------------

proc noteResize*(now: int64) =
  ## A resize event arrived: start (or extend) the resize gesture.
  if not resizeActive:
    resizeActive = true
    resizeStartPending = true
  resizeLastNs = now
  wakePending = true

proc resizing*(): bool =
  ## Inside a live resize gesture: frames run at vsync and the renderer
  ## paints straight to the backbuffer.
  resizeActive

proc resizeStarted*(): bool =
  ## This frame is the first of a resize gesture.
  resizeBegan

proc resizeFinished*(): bool =
  ## This frame closes a resize gesture (the window held still for
  ## `ResizeSettleNs`): the renderer rebuilds its retained surface here.
  resizeEnded

proc settleResize(now: int64) =
  if resizeActive and now - resizeLastNs >= ResizeSettleNs:
    resizeActive = false
    resizeEnded = true
    wakePending = true

## --- the loop's view ---------------------------------------------------------

proc frameWanted*(now: int64): bool =
  ## Whether the loop should run a frame at `now`.
  settleResize(now)
  wakePending or wantNext or wantSettle or resizeActive or resizeEnded or
    (deadlines.len > 0 and deadlines[0] <= now)

proc idleWait*(now: int64): int64 =
  ## How long the loop may sleep (ns) before a frame is due, if no event
  ## arrives first: 0 when one is due now, `Never` when only input can wake.
  if frameWanted(now):
    return 0
  var until = min(nextDeadline(), overlayDeadline)
  if resizeActive:
    until = min(until, resizeLastNs + ResizeSettleNs)
  if until == Never:
    return Never
  max(until - now, 0'i64)

proc earliestFrameStart*(vsynced: bool): int64 =
  ## Frames never run faster than the display: a frame that presented on a
  ## vsynced renderer was already paced by the swap, so only a half-period
  ## floor applies (a real vsync never hits it; a driver that accepts vsync
  ## without blocking -- offscreen -- does); any other frame (no present, or
  ## no vsync) waits out the rest of one period.
  if presentedLast and vsynced:
    return prevFrameNs + periodNs div 2
  prevFrameNs + periodNs

proc beginFrame*(now: int64) =
  ## Open frame `now`: stamp it, compute `frameDelta`, classify why it ran
  ## and clear the per-frame requests.
  settleResize(now)
  let continuing = wantNext or wantSettle or resizeActive
  if prevFrameNs > 0 and continuing:
    frameDtSec = min(float32(now - prevFrameNs) / float32(NsPerSec),
                     MaxFrameDt)
    if frameDtSec <= 0.0'f32:
      frameDtSec = float32(periodNs) / float32(NsPerSec)
  else:
    frameDtSec = float32(periodNs) / float32(NsPerSec)
  if resizeActive or resizeEnded:
    reason = frResize
  elif wakePending:
    reason = frInput
  elif wantNext:
    reason = frAnim
  elif wantSettle:
    reason = frSettle
  else:
    reason = frTimer
  if wakePending:
    inc stats.inputWakes
  elif wantNext or wantSettle:
    inc stats.animWakes
  else:
    inc stats.timerWakes
  if resizeActive:
    inc stats.resizeFrames
  frameDamagePx = 0
  refreshedNow.setLen(0)
  inc stats.frames

  resizeBegan = resizeStartPending
  resizeStartPending = false
  frameNs = now
  frameWallNs = wallNow()
  inc frameSerial
  wantNext = false
  wantSettle = false
  wakePending = false
  presentWanted = false
  var passed = 0
  while passed < deadlines.len and deadlines[passed] <= now:
    inc passed
  if passed > 0:
    var j = 0
    while j + passed < deadlines.len:
      let moved = deadlines[j + passed]
      deadlines[j] = moved
      inc j
    deadlines.setLen(deadlines.len - passed)

proc endFrame*(presented: bool) =
  ## Close the frame; `presented` tells the pacer whether pixels went out.
  prevFrameNs = frameNs
  presentedLast = presented
  resizeEnded = false
  resizeBegan = false
  if presented:
    inc stats.presents

var fullRedraw = true

proc requestFullRedraw*() =
  ## The window's pixels are gone or stale (exposed, shown, restored, a new
  ## surface): the renderer repaints everything in the next frame.
  fullRedraw = true
  wakePending = true

proc takeFullRedraw*(): bool =
  ## The renderer's side of `requestFullRedraw`: true once per request.
  result = fullRedraw
  fullRedraw = false

proc requestPresent*() =
  ## The renderer painted something this frame: present it.
  presentWanted = true

proc presentRequested*(): bool = presentWanted

proc noteDamage*(px: int64) =
  stats.damagePx += px
  frameDamagePx += px

## --- overlay passes ----------------------------------------------------------
##
## A debug overlay must not make the app it measures run: it repaints itself
## in *overlay passes* -- render only, no `update`, no frame counted -- on
## its own deadline.

proc requestOverlayAt*(t: int64) =
  ## Repaint the overlay (render only) no later than `t`.
  overlayDeadline = min(overlayDeadline, t)

proc overlayWanted*(now: int64): bool =
  overlayDeadline <= now

proc beginOverlayPass*() =
  overlayPassOn = true
  overlayDeadline = Never
  presentWanted = false

proc endOverlayPass*() =
  overlayPassOn = false

proc overlayPass*(): bool =
  ## This render is an overlay pass, not a frame: the layout is last frame's.
  overlayPassOn

proc takeStats*(): FrameStats =
  result = stats
  stats = FrameStats()

## --- pointer motion ----------------------------------------------------------

type
  MotionFilter* = proc (x, y: float32; down: bool): bool {.closure.}
    ## Does a pointer move to (x, y) need a frame? Installed by the UI layer,
    ## which knows what the pointer was over in the last layout.

var motionFilter: MotionFilter = nil
var trackingFrame = -1'i64

proc setMotionFilter*(f: MotionFilter) =
  motionFilter = f

proc trackPointer*() =
  ## This frame's UI reads the raw pointer position (a drag, a crosshair, a
  ## tooltip that follows the cursor): every motion event until the next
  ## frame wakes the loop, not just the ones that change the hover set.
  trackingFrame = frameSerial

proc motionWakes*(x, y: float32; down: bool): bool =
  ## The loop's question on every pointer-motion event.
  if down or trackingFrame == frameSerial or motionFilter == nil:
    return true
  motionFilter(x, y, down)

## --- widget cadences ---------------------------------------------------------

type
  Cadence* = object
    ## How often a guarded block (`refreshDue`) runs. `interval` applies at
    ## rest, `hoverInterval` while the pointer is over the guard's element;
    ## 0 = every frame, `Never` = only on the first frame, an `invalidate`,
    ## or a hover change. `wall` aligns intervals to the wall clock (a
    ## clock ticks exactly as the second turns over).
    interval*: int64
    hoverInterval*: int64
    hoverSet*: bool
    wall*: bool

proc everyFrame*(): Cadence =
  ## Refresh in every frame that runs -- and keep frames running at vsync.
  Cadence(interval: 0)

proc every*(ms: int; wall = false): Cadence =
  ## Refresh once per `ms` milliseconds; `wall` aligns the ticks to wall-clock
  ## multiples of the interval (every(1000, wall = true): on the second).
  Cadence(interval: max(int64(ms), 1'i64) * NsPerMs, wall: wall)

proc onInput*(): Cadence =
  ## Never refresh on a timer: only on the first frame and on `invalidate`.
  Cadence(interval: Never)

proc whileHovered*(c: Cadence; rate: Cadence): Cadence =
  ## `c` at rest, `rate` while the pointer is over the guarded element.
  result = c
  result.hoverInterval = rate.interval
  result.hoverSet = true

proc onHover*(rate: Cadence = everyFrame()): Cadence =
  ## Refresh only while hovered (at `rate`), plus once on enter and leave.
  whileHovered(onInput(), rate)

type
  RefreshSlot = object
    owner: uint64       ## widget key, for `invalidateOwner`
    tag: uint64         ## label hash, for `invalidateTag` (0: unlabelled)
    nextDue: int64
    anchor: int64       ## grid origin of a non-wall interval
    interval: int64     ## effective interval at the last check
    hovered: bool
    dirty: bool
    seen: int64         ## frame serial of the last check

var
  slots: Table[uint64, RefreshSlot]
  lastSweep = 0'i64

proc boundaryAfter(now, wallAtNow, interval, anchor: int64; wall: bool): int64 =
  ## The first tick strictly after `now` on the cadence grid, as a monotonic
  ## time. Wall grids add 1 ms so the wall clock has turned over on wake.
  if wall:
    let into = wallAtNow mod interval
    return now + (interval - into) + NsPerMs
  let k = (now - anchor) div interval + 1
  anchor + k * interval

proc sweepSlots() =
  ## Drop slots no frame has checked for a while (removed widgets).
  if frameSerial - lastSweep < 600:
    return
  lastSweep = frameSerial
  var dead: seq[uint64] = @[]
  for k, s in slots:
    if frameSerial - s.seen > 600:
      dead.add k
  for k in dead:
    slots.del k

proc refreshDue*(key: uint64; owner: uint64; c: Cadence; hovered: bool;
                 tag = 0'u64): bool =
  ## The guard behind `refresh`: true when the block keyed `key` is due this
  ## frame, and in any case schedules the frame it is next due in. Due on its
  ## first check, after `invalidate`, on a hover change of a hover-aware
  ## cadence, and whenever its interval's next tick has passed -- ticks sit
  ## on a fixed grid, so a late frame never shifts the schedule and a long
  ## sleep never replays the missed ticks.
  sweepSlots()
  let now = frameNs
  let interval = if hovered and c.hoverSet: c.hoverInterval else: c.interval
  var s: RefreshSlot
  var fresh = false
  if slots.hasKey(key):
    s = slots.getOrDefault(key)
  else:
    fresh = true
    s = RefreshSlot(owner: owner, anchor: now, interval: interval,
                    hovered: hovered)
  let hoverChanged = c.hoverSet and s.hovered != hovered
  if interval != s.interval:
    # The effective rate changed (hover in/out): restart the grid now.
    s.anchor = now
    s.nextDue = if interval == Never: Never else: now
  result = fresh or s.dirty or hoverChanged or interval == 0 or
    (interval != Never and now >= s.nextDue)
  if result:
    s.dirty = false
    if interval != Never and interval > 0:
      s.nextDue = boundaryAfter(now, frameWallNs, interval, s.anchor, c.wall)
    else:
      s.nextDue = Never
  s.interval = interval
  s.hovered = hovered
  s.owner = owner
  s.tag = tag
  s.seen = frameSerial
  if result and recordRefresh:
    refreshedNow.add owner
  slots[key] = s
  if interval == 0:
    requestFrame()
  elif s.nextDue != Never:
    requestFrameAt(s.nextDue)

proc invalidateKey*(key: uint64) =
  ## Make one guarded block due in the next frame, and wake for it.
  if slots.hasKey(key):
    var s = slots.getOrDefault(key)
    s.dirty = true
    slots[key] = s
  wake()

proc invalidateOwner*(owner: uint64) =
  ## Make every guarded block of one widget due in the next frame.
  var hit: seq[uint64] = @[]
  for k, s in slots:
    if s.owner == owner:
      hit.add k
  for k in hit:
    var s = slots.getOrDefault(k)
    s.dirty = true
    slots[k] = s
  wake()

proc invalidateTag*(tag: uint64) =
  ## Make every guarded block labelled `tag` due in the next frame.
  var hit: seq[uint64] = @[]
  for k, s in slots:
    if s.tag == tag:
      hit.add k
  for k in hit:
    var s = slots.getOrDefault(k)
    s.dirty = true
    slots[k] = s
  wake()

proc resetPacing*() =
  ## Forget all scheduler state (tests).
  frameNs = 0
  frameWallNs = 0
  prevFrameNs = 0
  frameDtSec = 1.0'f32 / 60.0'f32
  frameSerial = 0
  wakePending = true
  wantNext = false
  wantSettle = false
  deadlines.setLen(0)
  resizeActive = false
  resizeBegan = false
  resizeEnded = false
  resizeStartPending = false
  presentWanted = false
  presentedLast = false
  fullRedraw = true
  stats = FrameStats()
  overlayDeadline = Never
  overlayPassOn = false
  slots = initTable[uint64, RefreshSlot]()
  trackingFrame = -1
