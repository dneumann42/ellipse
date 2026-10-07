## Bar -- a status-bar strip, the frame pacer's showcase.
##
## Every segment refreshes on its own cadence and the loop only wakes for
## the one that is due (see `ellipse_ui/cadence`):
##
##   segment      cadence                         wakes the loop
##   ----------+---------------------------------+---------------------------
##   workspaces   input; hover eases with          on hover changes / clicks,
##                `approach`                       at vsync while easing
##   title        every(250)                       4x a second (a WM would
##                                                 `invalidate` on its event)
##   cpu          every(2000)                      every 2 s
##   memory       onHover(every(1000))             only while hovered
##   clock        every(1000, wall = true)         as the second turns over
##
## Run:   make run_bar
## Stats: ELLIPSE_FRAME_STATS=1 make run_bar   (frames/presents per second),
##        or F1 in the window for the debug overlay

import std/[syncio, strutils]

import ellipse/clock
import ellipse_ui/app

## --- data sources ----------------------------------------------------------------

proc pad2(n: int): string =
  if n < 10: "0" & $n else: $n

proc readProc(path: string): string =
  try:
    result = readFile(path)
  except:
    result = ""

proc cpuSample(): tuple[busy, total: int64] =
  ## The aggregate `cpu` line of /proc/stat: (non-idle, all) jiffies.
  let stat = readProc("/proc/stat")
  let nl = stat.find('\n')
  if nl < 0:
    return (0'i64, 0'i64)
  let fields = substr(stat, 0, nl - 1).splitWhitespace()
  var total = 0'i64
  var idle = 0'i64
  var i = 1
  while i < fields.len:
    var v = 0'i64
    try:
      v = int64(parseInt(fields[i]))
    except:
      v = 0
    total += v
    if i == 4 or i == 5:   # idle, iowait
      idle += v
    inc i
  (total - idle, total)

proc memLine(): string =
  ## "used / total GiB" from /proc/meminfo.
  var totalKb = 0
  var availKb = 0
  for line in readProc("/proc/meminfo").splitLines():
    let f = line.splitWhitespace()
    if f.len >= 2:
      try:
        if f[0] == "MemTotal:": totalKb = parseInt(f[1])
        elif f[0] == "MemAvailable:": availKb = parseInt(f[1])
      except:
        discard
  if totalKb == 0:
    return "mem ?"
  let usedTenths = (totalKb - availKb) * 10 div (1024 * 1024)
  let totalTenths = totalKb * 10 div (1024 * 1024)
  "mem " & $(usedTenths div 10) & "." & $(usedTenths mod 10) & " / " &
    $(totalTenths div 10) & "." & $(totalTenths mod 10) & " GiB"

## --- state -----------------------------------------------------------------------

var
  workspace = 1
  titles: seq[string] = @[]
  titleIndex = 0
  titleText = ""
  cpuText = "cpu --"
  cpuLast = (0'i64, 0'i64)
  memText = "mem"
  clockText = ""

proc fillTitles() =
  titles.add "ellipse -- src/ellipse/platform/pacing.nim"
  titles.add "Firefox -- frame pacing in immediate-mode UIs"
  titles.add "foot -- ~/ellipse"
  titles.add "Duck -- notes.txt"

## --- segments --------------------------------------------------------------------

widget focusable WorkspaceButton(index: int, active: bool) -> bool:
  ## A workspace pill. Hover eases in and out over a few frames: `approach`
  ## asks the pacer for vsync frames only while the colour is moving.
  let t = activeTheme
  let over = pointerOver(id)
  let target = if active: t.palette.accent
               elif over: buttonHoverBg
               else: panelBg
  let fill = approach(id, target, 18.0)
  result = (over and currentContext().pointerData().state == pressedThisFrame) or
    keyActivated(id)
  item(id, row(width = fixedPx(28), height = fixedPx(22), alignX = centerX,
               alignY = centerY).bg(fill).corner(6).focusRing(id)):
    text($index, 13, t.palette.textColor)

proc workspaces() =
  var i = 1
  while i <= 5:
    if WorkspaceButton(id = elementIdWithIndex("ws", uint32(i)), index = i, active = i == workspace):
      workspace = i
    inc i

widget Title():
  ## Polls a (simulated) focused-window title. Against a real WM IPC the
  ## better shape is `refresh "title", onInput()` plus `invalidate("title")`
  ## from the socket handler -- zero wakes until the title actually changes.
  refresh every(250):
    titleText = titles[(titleIndex div 12) mod titles.len]
    inc titleIndex
  text(titleText, 13, activeTheme.palette.labelColor)

widget Cpu():
  refresh every(2000):
    let s = cpuSample()
    let busy = s[0] - cpuLast[0]
    let total = s[1] - cpuLast[1]
    if total > 0:
      cpuText = "cpu " & $(busy * 100 div total) & "%"
    cpuLast = s
  text(cpuText, 13, activeTheme.palette.textColor)

widget Memory():
  ## Read only while someone is looking: the guard sits inside the
  ## segment's own element, so hover means "over this segment".
  let t = activeTheme
  item(hashId("mem"), row(height = fixedPx(22), padding = padAll(4),
                          alignY = centerY)
      .bg(if hovered(): buttonHoverBg else: panelBg).corner(6)):
    refresh onHover(every(1000)):
      memText = if hovered(): memLine() else: "mem"
    text(memText, 13, t.palette.textColor)

widget Clock():
  refresh every(1000, wall = true):
    let c = now()
    clockText = pad2(c.hour) & ":" & pad2(c.minute) & ":" & pad2(c.second)
  text(clockText, 13, activeTheme.palette.textColor)

## --- frame -----------------------------------------------------------------------

proc view() {.raises.} =
  let t = activeTheme
  clay "root", col(width = grow(), height = grow()).bg(bgColor):
    clay "bar", row(width = grow(), height = grow(), gap = 12,
                    padding = padAll(4), alignY = centerY).bg(panelBg)
        .border(t.metrics.borderHairline, t.palette.panelBorder):
      workspaces()
      spacer()
      Title()
      spacer()
      Cpu()
      Memory()
      Clock()

proc setup() {.raises.} =
  fillTitles()

when isMainModule:
  # Docked along the top edge on layer-shell compositors (Sway, Hyprland,
  # KDE, niri, ...), reserving its height; a borderless strip elsewhere.
  run App(window: WindowConfig(title: "bar", layer: LayerConfig(enabled: true,
            edge: edgeTop, thickness: 30, namespace: "ellipse-bar")),
          setup: setup, view: view)
