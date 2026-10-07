## The inline dialog header of `ellipse_ui/dialogs`, headless: the title
## bar's drag moves the panel (and stops at the window margin), the
## fullscreen toggle and a header double-click fill the window and put it
## back, the close button cancels, and a dialog without a header has none.

import std/[syncio, envvars]

import ellipse_ui/app

var failures = 0
var passed = 0

proc expect(cond: bool, msg: string) =
  if cond:
    passed += 1
  else:
    failures += 1
    echo "FAILED: ", msg

var closedWith = DialogStatus.dsOpen
var fullSeen = false

let framed = defineDialog("test.framed", DialogSpec(
  title: "Framed", width: 360,
  header: DialogHeader(enabled: true, fullscreen: true),
  body: proc () {.closure, raises.} =
    fullSeen = dialogFullscreen()
    text("inside")))

let plain = defineDialog("test.plain", DialogSpec(
  title: "Plain", width: 360,
  body: proc () {.closure, raises.} =
    text("inside")))

proc box(label: string; i: int): Rect =
  elementData(elementIdWithIndex(label, uint32(i))).box

proc at(x, y: float32; down: bool) {.raises.} =
  setPointer(x, y, down)
  frame()

proc mid(r: Rect): (float32, float32) =
  (r.x + r.width / 2.0'f32, r.y + r.height / 2.0'f32)

proc script() {.raises.} =
  at(-100.0, -100.0, false)
  framed.open(onDone = proc (r: DialogResult) {.closure.} =
    closedWith = r.status)
  frame()
  frame()
  let p0 = box("dlg.panel", 0)
  let h0 = box("dlg.head", 0)
  expect(h0.height > 0.0, "header is drawn")
  expect(abs((p0.x + p0.width / 2.0) - 400.0) < 2.0, "panel starts centred")

  # drag the title bar 100 right, 50 down
  let gx = h0.x + 40.0'f32
  let gy = h0.y + h0.height / 2.0'f32
  at(gx, gy, true)
  at(gx + 50.0, gy + 25.0, true)
  at(gx + 100.0, gy + 50.0, true)
  at(gx + 100.0, gy + 50.0, false)
  frame()
  let p1 = box("dlg.panel", 0)
  expect(abs((p1.x - p0.x) - 100.0) < 2.0, "dragged 100 right, got " & $(p1.x - p0.x))
  expect(abs((p1.y - p0.y) - 50.0) < 2.0, "dragged 50 down, got " & $(p1.y - p0.y))
  expect(p1.width == p0.width, "the drag keeps the size")

  # a drag far past the edge stops at the 24px margin
  let h1 = box("dlg.head", 0)
  at(h1.x + 40.0, h1.y + 10.0, true)
  at(h1.x + 2000.0, h1.y + 10.0, true)
  at(h1.x + 2000.0, h1.y + 10.0, false)
  frame()
  let p2 = box("dlg.panel", 0)
  expect(abs((p2.x + p2.width) - (800.0 - 24.0)) < 2.0,
         "clamped at the right margin, right edge " & $(p2.x + p2.width))
  expect(closedWith == dsOpen, "dragging never closes it")

  # a press on the body does not drag
  let (bx, by) = mid(p2)
  at(bx, by + 20.0, true)
  at(bx - 200.0, by + 20.0, true)
  at(bx - 200.0, by + 20.0, false)
  frame()
  expect(box("dlg.panel", 0).x == p2.x, "the body is no drag handle")

  # fullscreen toggle
  let (fx, fy) = mid(box("dlg.head.fs", 0))
  at(fx, fy, true)
  at(fx, fy, false)
  frame()
  let pf = box("dlg.panel", 0)
  expect(pf.x == 0.0 and pf.y == 0.0 and pf.width == 800.0 and
         pf.height == 600.0, "fullscreen fills the window")
  expect(fullSeen, "dialogFullscreen reports it")
  let hf = box("dlg.head", 0)
  at(hf.x + 40.0, hf.y + 10.0, true)
  at(hf.x + 240.0, hf.y + 110.0, true)
  at(hf.x + 240.0, hf.y + 110.0, false)
  frame()
  expect(box("dlg.panel", 0).x == 0.0, "no dragging while fullscreen")
  let (rx, ry) = mid(box("dlg.head.fs", 0))
  at(rx, ry, true)
  at(rx, ry, false)
  frame()
  frame()
  let pr = box("dlg.panel", 0)
  expect(pr.width == p0.width and abs(pr.x - p2.x) < 2.0,
         "restoring brings back the size and the dragged spot")

  # double-click on the title toggles too
  let hd = box("dlg.head", 0)
  pushDoubleClick()
  at(hd.x + 40.0, hd.y + 10.0, true)
  at(hd.x + 40.0, hd.y + 10.0, false)
  frame()
  expect(box("dlg.panel", 0).width == 800.0, "double-click fills the window")

  # close button cancels
  let (cx, cy) = mid(box("dlg.head.close", 0))
  at(cx, cy, true)
  at(cx, cy, false)
  frame()
  expect(closedWith == dsCancelled, "close button cancels")
  expect(not anyDialogOpen(), "closed")

  # no header: no bar, the title is a heading in the panel
  plain.open()
  frame()
  frame()
  expect(not elementData(elementIdWithIndex("dlg.head", 0'u32)).found,
         "a headerless dialog has no header")
  expect(box("dlg.panel", 0).width > 0.0, "but a panel")

  echo "dialog_header_test: ", passed, " passed, ", failures, " failed"
  if failures > 0:
    quit 1

when isMainModule:
  try:
    if getEnv("SDL_VIDEODRIVER").len == 0:
      putEnv("SDL_VIDEODRIVER", "offscreen")
  except:
    discard
  run(App(window: WindowConfig(title: "header test", width: 800, height: 600),
          log: false, debugMode: false), script = script)
