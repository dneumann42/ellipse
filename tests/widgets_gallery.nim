## Headless gallery of the widget set: lays the widgets out for real, drives
## a focus/click/type sequence through the event seams, draws one frame
## through the SDL3 renderer and saves a BMP for inspection.
## Run: SDL_VIDEODRIVER=offscreen ./bin/widgets_gallery  (from the repo root)

import std/[syncio]

import clay
import ellipse/platform/platform
import ellipse/platform/renderer
import ellipse_ui/ui
import ellipse_ui/widgets

# --- caller state -----------------------------------------------------------------

var agree = true
var wifi = false
var comboSel = 1
var multiSel: Selection = bit(0) or bit(2)
var nameText = ""
var noteText = "first line\nsecond line"
var qty = 2

var comboOpts: seq[string] = @[]
var multiOpts: seq[string] = @[]

let cbId = hashId("cb")
let swId = hashId("sw")
let comboId = hashId("combo")
let multiId = hashId("multi")
let tfId = hashId("tf")
let mlId = hashId("ml")
let nfId = hashId("qty")
let noteId = hashId("note")
let vbarId = hashId("vpanel.bar")   # `scrollPanel` names bars `<panel>.bar`

proc fillOptions() =
  for i in 0 ..< 12:
    comboOpts.add "Option " & $i
  multiOpts.add "Render"
  multiOpts.add "Audio"
  multiOpts.add "Input"
  multiOpts.add "Networking"
  multiOpts.add "Logging"

proc draw() =
  beginLayout()
  clay "app", col(width = grow(), height = grow(), gap = 6,
                  padding = padAll(24)):
    heading("Widget Gallery", 1)
    overline("built on clay")
    bodyText("The standard widgets of the new UI system: checkboxes, dropdowns, text and number entry, and a type scale -- all immediate-mode over clay layout blocks.")
    h3("Inputs")
    clay "grid", row(width = grow(), gap = 24, alignY = top):
      clay "col1", col(width = pct(0.5), gap = 12):
        Labeled(label = "Backend"):
          comboSel = comboBox(comboId, comboOpts, comboSel, "Pick one")
        Labeled(label = "Name"):
          nameText = textField(tfId, nameText, "Your name")
        Labeled(label = "Notes"):
          noteText = multilineField(mlId, noteText, "Leave a note...",
                                    rows = 3)
        Labeled(label = "Quantity"):
          qty = intNumberField(nfId, qty, 1)
      clay "col2", col(width = grow(), gap = 12):
        agree = checkbox(cbId, "Enable vsync", agree)
        wifi = switch(swId, "Wifi", wifi)
        Section(title = "Modules"):
          multiSel = multiSelect(multiId, multiOpts, multiSel)
    caption("Keyboard editing is Emacs-style: C-a/C-e, C-b/C-f, M-b/M-f words, C-k/C-u/C-w kills, C-y yank, Enter commit (newline in multiline).")
    if textLink(noteId, "Read the docs"):
      discard
    badge("beta")
    h3("Scrolling")
    clay "scrow", row(width = grow(), height = fixedPx(200), gap = 16,
                      alignY = top):
      scrollPanel "vpanel", col(width = pct(0.5), height = grow(), gap = 2,
          padding = padAll(padItem))
          .bg(fieldBg)
          .border(hairline, panelBorder)
          .corner(panelRadius)
          .clip(horizontal = false, vertical = true,
                childOffset = currentScrollOffset()):
        var r = 0
        while r < 18:
          listRow("vpanel.row", r):
            text("Row " & $r)
          inc r
      scrollPanel "hstrip", row(width = grow(), height = grow(), gap = 10,
          padding = padAll(8))
          .bg(fieldBg)
          .border(hairline, panelBorder)
          .corner(panelRadius)
          .clip(horizontal = true, vertical = false,
                childOffset = currentScrollOffset()):
        var c = 0
        while c < 10:
          listCard("hstrip.card", c, fixedPx(130)):
            text("Card " & $c)
          inc c
  endLayout()

proc boxCenter(id: ElementId): Vec2 =
  let b = elementData(id).box
  vec2(b.x + b.width / 2.0, b.y + b.height / 2.0)

proc framePointer(x, y: float32, down: bool) =
  beginInputFrame()
  setPointerState(vec2(x, y), down)
  notePressState()
  draw()

proc frameWheel(x, y: float32, down: bool, wheel: Vec2) =
  ## One frame that also feeds `wheel` straight into the scroll engine --
  ## in the app this is `updateUI`, minus the wheel-acceleration filter.
  beginInputFrame()
  setPointerState(vec2(x, y), down)
  notePressState()
  updateScrollContainers(false, wheel, 0.016'f32)
  draw()

proc typeStr(s: string) =
  var i = 0
  while i < s.len:
    var one = ""
    one.add s[i]
    pushKeyEvent KeyEvent(kind: kevText, text: one)
    inc i
  beginInputFrame()
  setPointerState(vec2(-100.0, -100.0), false)
  draw()

proc pressChord(ch: char, ctrl = true, alt = false) =
  pushKeyEvent KeyEvent(kind: kevLetter, ch: ch, ctrl: ctrl, alt: alt)
  beginInputFrame()
  setPointerState(vec2(-100.0, -100.0), false)
  draw()

proc pressEnter() =
  pushKeyEvent KeyEvent(kind: kevEnter)
  beginInputFrame()
  setPointerState(vec2(-100.0, -100.0), false)
  draw()

proc saveShot(path: string) {.raises.} =
  let errs = takeErrors()
  for e in errs:
    echo "clay error: ", e.message
  let vd = scrollContainerData(hashId("vpanel"))
  echo "vpanel found=", vd.found, " pos=", vd.position.x, ",", vd.position.y,
    " cont=", vd.contentDimensions.width, "x", vd.contentDimensions.height,
    " view=", vd.containerDimensions.width, "x", vd.containerDimensions.height
  let hd = scrollContainerData(hashId("hstrip"))
  echo "hstrip found=", hd.found, " cont=", hd.contentDimensions.width,
    " view=", hd.containerDimensions.width
  let vt = elementData(localId("sb.vthumb", vbarId.id))
  echo "vthumb found=", vt.found, " box=", vt.box.x, ",", vt.box.y,
    " ", vt.box.width, "x", vt.box.height
  if not saveScreenshot(path):
    echo "readback failed"
    return
  echo "saved screenshot"

proc main() {.raises.} =
  fillOptions()
  bootup()

  # publish boxes, then click into the name field and edit it with Emacs
  # chords, continue in the multiline field, then open the dropdown: the
  # saved frame shows edited + focused + open states
  framePointer(-100.0, -100.0, false)
  framePointer(-100.0, -100.0, false)

  let tfp = boxCenter(tfId)
  framePointer(tfp.x, tfp.y, true)
  framePointer(tfp.x, tfp.y, false)
  typeStr("Hopper")
  pressChord('a')              # C-a: line start
  typeStr("Grace ")
  pressChord('e')              # C-e: line end

  let mlp = boxCenter(mlId)
  framePointer(mlp.x, mlp.y, true)
  framePointer(mlp.x, mlp.y, false)
  pressEnter()                 # Enter inserts a newline here (multiline)
  typeStr("typed in emacs ")

  saveShot("build/widgets_gallery_edited.bmp")   # caret + typed text, before
                                                 # the popover covers fields

  # --- compressed state: hold a press on the checkbox row. The down edge
  # claims the press; the held frame renders the row sunk and its content
  # shifted down, then the release restores it.
  let cbp = boxCenter(cbId)
  framePointer(cbp.x, cbp.y, true)
  framePointer(cbp.x, cbp.y, true)
  saveShot("build/widgets_gallery_pressed.bmp")
  framePointer(cbp.x, cbp.y, false)
  framePointer(-100.0, -100.0, false)

  let cp = boxCenter(comboId)
  framePointer(cp.x, cp.y, true)
  framePointer(cp.x, cp.y, false)   # popover open

  saveShot("build/widgets_gallery.bmp")   # popover open over the fields

  # --- scrolling containers: drag the vertical panel's scrollbar thumb,
  # then wheel-scroll the horizontal strip. The bars themselves need one
  # frame of published container geometry before they appear.
  framePointer(-100.0, -100.0, false)
  framePointer(-100.0, -100.0, false)

  let vtId = localId("sb.vthumb", vbarId.id)
  let vt = boxCenter(vtId)
  framePointer(vt.x, vt.y, true)          # grab the thumb
  framePointer(vt.x, vt.y + 60.0, true)   # drag it down
  framePointer(vt.x, vt.y + 60.0, false)  # release
  framePointer(-100.0, -100.0, false)     # let the new position render

  let hp = boxCenter(hashId("hstrip"))
  var n = 0
  while n < 20:   # a brisk wheel flick to the right
    frameWheel(hp.x, hp.y, false, vec2(-2.0, 0.0))
    inc n
  n = 0
  while n < 24:   # coast the spring to rest
    frameWheel(hp.x, hp.y, false, vec2(0.0, 0.0))
    inc n

  saveShot("build/widgets_gallery_scrolled.bmp")

when isMainModule:
  try:
    main()
  except ErrorCode:
    discard
