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

type
  SDL_Rect {.importc: "SDL_Rect", header: "<SDL3/SDL.h>".} = object
    x, y, w, h: int32
  SDL_Surface {.importc: "SDL_Surface", header: "<SDL3/SDL.h>".} = object

proc SDL_SetRenderDrawColor(ren: ptr SDL_Renderer; r, g, b, a: uint8): bool {.
  importc: "SDL_SetRenderDrawColor", header: "<SDL3/SDL.h>".}
proc SDL_RenderClear(ren: ptr SDL_Renderer): bool {.
  importc: "SDL_RenderClear", header: "<SDL3/SDL.h>".}
proc SDL_RenderReadPixels(ren: ptr SDL_Renderer; rect: ptr SDL_Rect): ptr SDL_Surface {.
  importc: "SDL_RenderReadPixels", header: "<SDL3/SDL.h>".}
proc SDL_SaveBMP(surf: ptr SDL_Surface; file: cstring): bool {.
  importc: "SDL_SaveBMP", header: "<SDL3/SDL.h>".}
proc SDL_DestroySurface(surf: ptr SDL_Surface) {.
  importc: "SDL_DestroySurface", header: "<SDL3/SDL.h>".}

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

proc fillOptions() =
  comboOpts.add "Alpha"
  comboOpts.add "Beta"
  comboOpts.add "Gamma"
  comboOpts.add "Delta"
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
  endLayout()

proc boxCenter(id: ElementId): Vec2 =
  let b = elementData(id).box
  vec2(b.x + b.width / 2.0, b.y + b.height / 2.0)

proc framePointer(x, y: float32, down: bool) =
  beginInputFrame()
  setPointerState(vec2(x, y), down)
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

proc saveShot(path: cstring) {.raises.} =
  let ren = sdlRenderer()
  discard SDL_SetRenderDrawColor(ren, 12, 12, 16, 255)
  discard SDL_RenderClear(ren)
  drawCommands()

  var full = SDL_Rect(x: 0, y: 0, w: 1280, h: 720)
  let surf = SDL_RenderReadPixels(ren, addr full)
  if surf == nil:
    echo "readback failed"
    return
  discard SDL_SaveBMP(surf, path)
  SDL_DestroySurface(surf)
  echo "saved screenshot"

proc main() {.raises.} =
  fillOptions()
  initialize()
  initializeRenderer()
  setCurrentContext(initContext(size(1280.0, 720.0)))
  setMeasureText(measureText)

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

  let cp = boxCenter(comboId)
  framePointer(cp.x, cp.y, true)
  framePointer(cp.x, cp.y, false)   # popover open

  saveShot("build/widgets_gallery.bmp")   # popover open over the fields

when isMainModule:
  try:
    main()
  except ErrorCode:
    discard
