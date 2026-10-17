## Damage tracking: the pure command diff, and the renderer's partial
## repaint checked pixel for pixel against a full repaint of the same frame.

import std/[syncio, envvars]

import clay
import ellipse/platform/platform
import ellipse/platform/renderer
import ellipse/platform/damage
import ellipse_ui/ui
import ellipse_ui/widgets

var failures = 0
var passed = 0

proc expect(cond: bool, msg: string) =
  if cond:
    passed += 1
  else:
    failures += 1
    echo "FAILED: ", msg

proc sig(key, hash: uint64; x, y, w, h: float32; clip = false): CmdSig =
  CmdSig(key: key, hash: hash, box: rect(x, y, w, h), isClip: clip)

let view = rect(0, 0, 1000, 1000)

proc testDiff() =
  let a = @[sig(1, 10, 0, 0, 1000, 1000), sig(2, 20, 10, 10, 50, 20),
            sig(3, 30, 500, 10, 50, 20)]
  expect(diffDamage(a, a, view).kind == dmgNone, "diff: identical -> nothing")

  var b = a
  b[2] = sig(3, 31, 500, 10, 60, 20)       # the clock's text changed
  let d = diffDamage(a, b, view)
  expect(d.kind == dmgRects and d.rects.len == 1, "diff: one change -> one rect")
  if d.rects.len == 1:
    let r = d.rects[0]
    expect(r.x <= 500 and r.x + r.width >= 560 and r.width < 80,
      "diff: rect covers old and new box, with a small bleed")

  var c = a
  c[1] = sig(2, 21, 10, 10, 50, 20)
  c[2] = sig(3, 31, 500, 10, 50, 20)
  expect(diffDamage(a, c, view).rects.len == 2, "diff: far apart -> two rects")

  var ins = a
  ins.add sig(4, 40, 300, 300, 40, 40)     # a tooltip appears
  let di = diffDamage(a, ins, view)
  expect(di.kind == dmgRects and di.rects.len == 1, "diff: insertion damages its box")
  expect(diffDamage(ins, a, view).kind == dmgRects, "diff: removal damages its box")

  var clip = a
  clip.add sig(5, 50, 0, 0, 100, 100, clip = true)
  expect(diffDamage(a, clip, view).kind == dmgFull, "diff: new clip -> full repaint")

  let swapped = @[a[0], a[2], a[1]]
  expect(diffDamage(a, swapped, view).kind == dmgFull, "diff: paint order -> full")

  var big = a
  big[0] = sig(1, 11, 0, 0, 1000, 1000)    # the background changed
  expect(diffDamage(a, big, view).kind == dmgFull, "diff: most of the view -> full")

## --- pixel equivalence ---------------------------------------------------------

var clockText = "12:00:00"
var hoverRow = -1

proc frame() =
  layout:
    clay "root", col(width = grow(), height = grow(), gap = 8,
                     padding = padAll(8)).bg(bgColor):
      clay "bar", row(width = grow(), height = fixedPx(32), gap = 8,
                      padding = padAll(4), alignY = centerY).bg(panelBg):
        text("workspaces")
        spacer()
        text(clockText)
      var r = 0
      while r < 4:
        item("row", r, row(width = fixedPx(300), height = fixedPx(28),
            padding = padAll(4))
            .bg(if r == hoverRow: buttonHoverBg else: panelBg)
            .corner(6)):
          text("row " & $r)
        inc r

proc paintsMatch(msg: string)  =
  ## The retained, damage-limited picture must equal a full repaint.
  frame()
  drawCommands()
  let partial = frameChecksum()
  invalidateFrame()
  drawCommands()
  let full = frameChecksum()
  expect(partial != 0 and partial == full, msg)

proc testPixels()  =
  frame()
  drawCommands()                          # first paint: full
  expect(presentRequested(), "pixels: first frame presents")

  beginFrame(monoNow())
  frame()
  drawCommands()
  expect(not presentRequested(), "pixels: unchanged frame does not present")

  clockText = "12:00:01"
  discard takeStats()
  frame()
  drawCommands()
  let px = takeStats().damagePx
  expect(px > 0 and px < 1280 * 720 div 20,
    "pixels: a clock tick repaints a small area, got " & $px & " px")
  clockText = "12:00:02"
  paintsMatch("pixels: clock tick repaints to the same picture")
  hoverRow = 2
  paintsMatch("pixels: hover highlight repaints to the same picture")
  hoverRow = 1
  clockText = "9:59:59"
  paintsMatch("pixels: two separate changes repaint to the same picture")

proc main()  =
  putEnv("SDL_VIDEODRIVER", "offscreen")
  testDiff()
  bootup()
  testPixels()
  echo "damage_test: ", passed, " passed, ", failures, " failed"

when isMainModule:
  try:
    main()
  except CatchableError:
    echo "damage_test: error"
    failures += 1
  if failures > 0:
    quit(1)
