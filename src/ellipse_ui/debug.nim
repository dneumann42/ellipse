## Debug mode: F1 toggles an overlay that shows what the UI is doing.
##
## Opt in once at startup:
##
##   import ellipse_ui/debug
##   bootup()
##   installDebugMode()
##
## Then F1 (taken before widgets and app chords see it) shows:
##
##   - every widget's box, labelled with its name, its *fps* -- how many
##     times a second its painted output actually changed -- and, for
##     widgets with `refresh` guards, how often those ran (`r` rate). Boxes
##     that repainted in the frame on screen are tinted;
##   - the window's real numbers: frames run, frames that repainted, pixels
##     repainted, all per second, and the display rate they are paced to;
##   - a timeline of the last few seconds: one tick per frame -- every time
##     the whole UI re-ran -- coloured by why it ran (input, timer,
##     animation, resize), tall when it repainted; below it a lane per busy
##     widget marking when it repainted (square) or refreshed (bar).
##
## The overlay measures without disturbing: it is painted after layout,
## straight onto the backbuffer (outside the app's commands, damage
## tracking and settle frames), and keeps its numbers current with
## render-only *overlay passes* twice a second that never run `update`. An
## idle app stays idle with the overlay up -- the timeline shows the gap
## and the counters fall to zero.
{.push gcsafe.}


import std/[tables, math]

import clay
import ellipse/platform/platform
import ellipse/platform/renderer
import ellipse/platform/damage
import ./events
import ./ui

const
  WindowNs = 5 * NsPerSec        ## timeline span
  RateNs = NsPerSec              ## per-second counters look back this far
  OverlayEveryNs = 500 * NsPerMs ## overlay pass cadence while shown
  MaxLanes = 8

type
  FrameRec = object
    t: int64
    reason: FrameReason
    painted: bool
    damage: int64

  WidgetStat = object
    name: string
    changes: seq[int64]     ## when its own output changed
    refreshes: seq[int64]   ## when its `refresh` guards ran
    lastHash: uint64
    seen: int64

  WidgetBox = object
    key: uint64
    name: string
    box: Rect
    changed: bool

var
  installed = false
  active = false
  history {.threadvar.}: seq[FrameRec]
  widgetStats {.threadvar.}: Table[uint64, WidgetStat]
  boxes {.threadvar.}: seq[WidgetBox]
history = @[]
boxes = @[]

proc debugActive*(): bool =
  ## The overlay is showing.
  active

## --- per-frame recording ---------------------------------------------------------

proc mix(a, b: uint64): uint64 =
  var z = (a xor b) + 0x9E3779B97F4A7C15'u64
  z = (z xor (z shr 30)) * 0xBF58476D1CE4E5B9'u64
  z = (z xor (z shr 27)) * 0x94D049BB133111EB'u64
  z xor (z shr 31)

proc prune(ts: var seq[int64]; since: int64) =
  var drop = 0
  while drop < ts.len and ts[drop] < since:
    inc drop
  if drop > 0:
    var j = 0
    while j + drop < ts.len:
      let v = ts[j + drop]
      ts[j] = v
      inc j
    ts.setLen(ts.len - drop)

proc countSince(ts: seq[int64]; since: int64): int =
  result = 0
  for t in ts:
    if t >= since:
      inc result

proc recordFrame() =
  ## After a real frame's layout: attribute this frame's render commands to
  ## the innermost widget that declared them, find whose output changed,
  ## box every widget and log the frame.
  let now = frameNow()
  let ctx = currentContext()
  let trace = widgetTrace()

  # owner[element index] = innermost widget whose body declared it
  var owner = newSeq[int](ctx.elements.len)
  for k in 0 ..< owner.len:
    owner[k] = -1
  var i = 0
  while i < trace.len:
    var e = trace[i].elemStart
    while e < trace[i].elemEnd and e < ctx.elements.len:
      owner[e] = i    # later (inner) widgets overwrite
      inc e
    inc i

  var hashes = newSeq[uint64](trace.len)
  let cmds = renderCommands()
  for cmd in cmds:
    # Text commands carry a per-line id; their element index is exact.
    var idx = -1
    if cmd.kind == renderText:
      idx = int(cmd.elementIndex)
    else:
      idx = int(ctx.elementMap.getOrDefault(cmd.id,
                                            MapItem(elementIndex: -1)).elementIndex)
    if idx >= 0 and idx < owner.len and owner[idx] >= 0:
      let text = if cmd.kind == renderText: lineText(cmd) else: ""
      hashes[owner[idx]] = mix(hashes[owner[idx]], signature(cmd, text))

  boxes.setLen(0)
  i = 0
  while i < trace.len:
    let t = trace[i]
    let key = uint64(t.key)
    var st = widgetStats.getOrDefault(key, WidgetStat(name: t.name, seen: -1))
    let changed = st.seen >= 0 and st.lastHash != hashes[i]
    if changed or st.seen < 0:
      st.changes.add now
    st.lastHash = hashes[i]
    st.seen = now
    st.name = t.name
    prune(st.changes, now - WindowNs)
    prune(st.refreshes, now - WindowNs)
    widgetStats[key] = st

    # The widget's box: the union of its elements' boxes this frame, cut to
    # the clip region its first element sits in.
    var box = rect(0, 0, 0, 0)
    var clipId = 0'u32
    var e = t.elemStart
    while e < t.elemEnd and e < ctx.elements.len:
      let el = ctx.elements[e]
      if e == t.elemStart:
        clipId = el.clipId
      let item = ctx.elementMap.getOrDefault(el.id, MapItem(elementIndex: -1))
      if item.elementIndex >= 0 and item.box.width > 0 and item.box.height > 0:
        box = union(box, item.box)
      inc e
    if clipId != 0:
      let clipItem = ctx.elementMap.getOrDefault(clipId, MapItem(elementIndex: -1))
      if clipItem.elementIndex >= 0:
        box = intersect(box, clipItem.box)
    if box.width > 0 and box.height > 0 and t.name != "handleEvents":
      boxes.add WidgetBox(key: key, name: t.name, box: box, changed: changed)
    inc i

  let fired = refreshedThisFrame()
  for o in fired:
    var st = widgetStats.getOrDefault(o, WidgetStat(seen: -1))
    if st.seen >= 0:
      st.refreshes.add now
      widgetStats[o] = st

  # forget widgets gone for the whole window
  var dead: seq[uint64] = @[]
  for k, st in widgetStats:
    if st.seen < now - WindowNs:
      dead.add k
  for k in dead:
    widgetStats.del k

  history.add FrameRec(t: now, reason: frameReason(),
                       painted: contentPainted(), damage: frameDamage())
  var drop = 0
  while drop < history.len and history[drop].t < now - WindowNs:
    inc drop
  if drop > 0:
    var j = 0
    while j + drop < history.len:
      let v = history[j + drop]
      history[j] = v
      inc j
    history.setLen(history.len - drop)

## --- drawing ------------------------------------------------------------------

const
  TextSize = 12
  PanelW = 560.0'f32

proc reasonColor(r: FrameReason): Color =
  case r
  of frInput: rgb(90, 160, 255)
  of frTimer: rgb(90, 210, 120)
  of frAnim: rgb(255, 170, 60)
  of frResize: rgb(220, 100, 230)
  of frSettle: rgb(150, 150, 165)

proc fmtRate(n: int): string =
  ## Counts over `RateNs` (one second) as a per-second figure.
  $n

proc fmtPx(px: int64): string =
  if px >= 1_000_000: $(px div 1_000_000) & "." & $((px div 100_000) mod 10) & "M"
  elif px >= 1_000: $(px div 1_000) & "k"
  else: $px

proc label(text: string; x, y: float32; fg, bg: Color) =
  let w = overlayTextWidth(text, TextSize)
  overlayRect(rect(x, y, w + 6, float32(TextSize) + 4), bg)
  overlayText(text, x + 3, y + 1, TextSize, fg)

proc drawWidgets(now: int64) =
  let since = now - RateNs
  for b in boxes:
    let st = widgetStats.getOrDefault(b.key, WidgetStat(seen: -1))
    let fps = countSince(st.changes, since)
    let refreshes = countSince(st.refreshes, since)
    let hot = fps > 0
    if b.changed and not overlayPass():
      overlayRect(b.box, rgb(255, 140, 40, 40))
    overlayFrame(b.box, 1.0,
      if hot: rgb(255, 150, 50, 200) else: rgb(110, 150, 255, 90))
    if b.box.width >= 36 and b.box.height >= 12:
      var txt = b.name & " " & $fps & "fps"
      if st.refreshes.len > 0:
        txt.add " r" & $refreshes
      # above the box when there is room, so the label hides nothing
      let ly = if b.box.y >= float32(TextSize) + 5: b.box.y - float32(TextSize) - 4
               else: b.box.y + 1
      label(txt, b.box.x, ly,
        if hot: rgb(255, 225, 190) else: rgb(200, 210, 235),
        rgb(10, 12, 20, 190))

proc xOf(t, now: int64; chartX, chartW: float32): float32 =
  ## Timeline x of time `t`: `now` at the right edge, `WindowNs` ago at the left.
  chartX + chartW - chartW * float32(now - t) / float32(WindowNs)

proc drawPanel(now: int64) =
  let (vw, vh) = windowPixelSize()
  let since = now - RateNs

  # busiest widgets in the window, for the lanes
  var lanes: seq[tuple[key: uint64, score: int]] = @[]
  for k, st in widgetStats:
    let score = st.changes.len + st.refreshes.len
    if score > 0 and st.name != "handleEvents":
      var at = lanes.len
      while at > 0 and lanes[at - 1].score < score:
        dec at
      lanes.add (key: k, score: score)
      var j = lanes.len - 1
      while j > at:
        let v = lanes[j - 1]
        lanes[j] = v
        dec j
      lanes[at] = (key: k, score: score)
  if lanes.len > MaxLanes:
    lanes.setLen(MaxLanes)

  let laneH = 15.0'f32
  let stripH = 34.0'f32
  let headH = 3.0'f32 * 17.0'f32
  let panelH = headH + stripH + float32(lanes.len) * laneH + 30.0'f32
  let px = max(vw - PanelW - 10.0'f32, 0.0'f32)
  let py = max(vh - panelH - 10.0'f32, 0.0'f32)
  overlayRect(rect(px, py, PanelW, panelH), rgb(8, 10, 16, 225))
  overlayFrame(rect(px, py, PanelW, panelH), 1.0, rgb(90, 100, 130, 255))

  var frames = 0
  var painted = 0
  var damage = 0'i64
  for f in history:
    if f.t >= since:
      inc frames
      if f.painted: inc painted
      damage += f.damage
  let hz = int(1_000_000_000'i64 div max(refreshPeriod(), 1'i64))
  let fg = rgb(225, 230, 240)
  let dim = rgb(150, 158, 175)
  overlayText("frames " & fmtRate(frames) & "/s   repaints " & fmtRate(painted) &
    "/s   repaint " & fmtPx(damage) & " px/s   display " & $hz & " Hz",
    px + 8, py + 6, 13, fg)
  var lastAgo = "never"
  if history.len > 0:
    lastAgo = $((now - history[^1].t) div NsPerMs) & " ms ago"
  overlayText("last frame " & lastAgo & "   widgets " & $boxes.len &
    "   F1 hides", px + 8, py + 23, TextSize, dim)

  # legend
  var lx = px + 8
  let ly = py + 40
  for r in [frInput, frTimer, frAnim, frSettle, frResize]:
    overlayRect(rect(lx, ly + 3, 8, 8), reasonColor(r))
    let name = case r
      of frInput: "input"
      of frTimer: "timer"
      of frAnim: "animation"
      of frResize: "resize"
      of frSettle: "settle"
    overlayText(name, lx + 11, ly, TextSize, dim)
    lx += 11 + overlayTextWidth(name, TextSize) + 12
  overlayText("tall = repainted", lx, ly, TextSize, dim)

  # frame strip: one tick per frame, newest at the right
  let nameW = 120.0'f32
  let chartX = px + 8 + nameW
  let chartW = PanelW - 16 - nameW
  let sy = py + headH + 4
  overlayText("frames", px + 8, sy + 10, TextSize, dim)
  overlayRect(rect(chartX, sy, chartW, stripH - 4), rgb(20, 24, 34, 255))
  var s = 1
  while s < 5:
    overlayRect(rect(chartX + chartW * float32(s) / 5.0, sy, 1, stripH - 4),
      rgb(45, 52, 70, 255))
    inc s
  for f in history:
    let x = xOf(f.t, now, chartX, chartW)
    if x >= chartX:
      let h = if f.painted: stripH - 6 else: (stripH - 6) * 0.4'f32
      overlayRect(rect(x, sy + stripH - 5 - h, 2, h), reasonColor(f.reason))

  # lanes: per busy widget, when it repainted (square) or refreshed (bar)
  var ly2 = sy + stripH + 2
  for lane in lanes:
    let st = widgetStats.getOrDefault(lane.key, WidgetStat(seen: -1))
    var name = st.name
    while name.len > 2 and overlayTextWidth(name, TextSize) > nameW - 8:
      name.setLen(name.len - 1)
    overlayText(name, px + 8, ly2, TextSize, fg)
    overlayRect(rect(chartX, ly2 + laneH / 2, chartW, 1), rgb(40, 46, 62, 255))
    for t in st.refreshes:
      let x = xOf(t, now, chartX, chartW)
      if x >= chartX:
        overlayRect(rect(x, ly2 + 2, 1, laneH - 4), rgb(90, 210, 120, 220))
    for t in st.changes:
      let x = xOf(t, now, chartX, chartW)
      if x >= chartX:
        overlayRect(rect(x - 2, ly2 + laneH / 2 - 3, 5, 6), rgb(255, 150, 50, 240))
    ly2 += laneH
  overlayText("-5 s", chartX, py + panelH - 18, TextSize, dim)
  overlayText("now", chartX + chartW - overlayTextWidth("now", TextSize),
    py + panelH - 18, TextSize, dim)

proc drawOverlay()  =
  if not active:
    return
  if not overlayPass():
    recordFrame()
  let now = monoNow()
  drawWidgets(now)
  drawPanel(now)
  requestOverlayAt(now + OverlayEveryNs)

proc setDebugActive*(on: bool) =
  if on == active:
    return
  active = on
  # The hook only while shown: an installed overlay makes every render
  # present, which a hidden one must not cost.
  setOverlay(if on: drawOverlay else: nil)
  setWidgetTrace(on)
  setRefreshRecording(on)
  history.setLen(0)
  widgetStats = initTable[uint64, WidgetStat]()
  boxes.setLen(0)
  requestFullRedraw()      # paint the overlay on, or wipe it off

proc debugKeys() =
  ## The input hook: F1 toggles, and nobody else sees it.
  var toggled = false
  let evs = keyEvents()
  for ev in evs:
    if ev.kind == kevF1:
      toggled = not toggled
  if toggled:
    setDebugActive(not active)
  consumeKeys(kevF1)

proc installDebugMode*() =
  ## Make F1 toggle the debug overlay in this app. Call once after `bootup`.
  if installed:
    return
  installed = true
  onInputFrame(debugKeys)
