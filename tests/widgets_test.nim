## Tests for the standard widget set (ellipse_ui/widgets).
##
## Lays the widgets out in a clay context frame by frame, drives them with
## pointer presses (last-frame boxes, as the frame contract wants) and with
## synthetic key events through the platform queue, and checks the values
## they hand back to their callers.

import std/syncio

import clay
import ellipse/platform/platform
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

proc mono(text: string; cfg: TextConfig): Size =
  Size(width: float32(text.len) * float32(cfg.fontSize), height: float32(cfg.fontSize))

# --- caller state, immediate-mode style ------------------------------------------------

var agree = false
var wifi = false
var comboSel = 1
var multiSel: Selection = 0'u64
var nameText = "Ada"
var qty = 3
var noteClicked = false

var comboOpts: seq[string] = @[]
comboOpts.add "Alpha"
comboOpts.add "Beta"
comboOpts.add "Gamma"

var multiOpts: seq[string] = @[]
multiOpts.add "One"
multiOpts.add "Two"
multiOpts.add "Three"

let cbId = hashId("cb")
let swId = hashId("sw")
let comboId = hashId("combo")
let multiId = hashId("multi")
let tfId = hashId("tf")
let nfId = hashId("qty")
let noteId = hashId("note")

proc draw() =
  beginLayout()
  clay "root", col(width = grow(), height = grow(), gap = 8,
                   padding = padAll(16)):
    heading("Widgets", 1)
    h3("Inputs")
    label("Name")
    agree = checkbox(cbId, "Agree", agree)
    wifi = switch(swId, "Wifi", wifi)
    comboSel = comboBox(comboId, comboOpts, comboSel, "Pick one")
    multiSel = multiSelect(multiId, multiOpts, multiSel)
    nameText = textField(tfId, nameText, "Your name")
    qty = intNumberField(nfId, qty, 1)
    if textLink(noteId, "Notes"):
      noteClicked = true
  endLayout()

proc frame() =
  draw()

proc boxCenter(id: ElementId): Vec2 =
  let b = elementData(id).box
  vec2(b.x + b.width / 2.0, b.y + b.height / 2.0)

proc clickAt(p: Vec2) =
  beginInputFrame()
  setPointerState(p, true)
  frame()
  beginInputFrame()
  setPointerState(p, false)
  frame()

proc click(id: ElementId) =
  clickAt(boxCenter(id))

proc typeStr(s: string) =
  var i = 0
  while i < s.len:
    var one = ""
    one.add s[i]
    pushKeyEvent KeyEvent(kind: kevText, text: one)
    inc i
  beginInputFrame()
  frame()

proc pressKey(kind: KeyEventKind, shift = false) =
  pushKeyEvent KeyEvent(kind: kind, shift: shift)
  beginInputFrame()
  frame()

proc main() {.raises.} =
  setCurrentContext(initContext(size(800.0, 600.0)))
  setMeasureText(mono)

  # settle clay's pointer state machine the way `updateUI` does every frame
  setPointerState(vec2(-100.0, -100.0), false)
  frame()
  expect(elementData(hashId("root")).found, "widgets: root lays out")
  expect(takeErrors().len == 0, "widgets: frame reports no clay errors")

  # --- checkbox + switch -----------------------------------------------------------
  click(cbId)
  expect(agree, "checkbox: click toggles on")
  click(swId)
  expect(wifi, "switch: click toggles on")
  click(cbId)
  expect(not agree, "checkbox: second click toggles off")

  # --- combobox ---------------------------------------------------------------------
  click(comboId)
  let popId = localId("combo.pop", comboId.id)
  expect(elementData(popId).found, "comboBox: click opens the popover")
  let opt0 = localIdWithIndex("combo.opt", 0'u32, comboId.id)
  expect(elementData(opt0).found, "comboBox: options laid out in the popover")
  click(opt0)
  expect(comboSel == 0, "comboBox: row click selects, got " & $comboSel)
  expect(not elementData(popId).found, "comboBox: selecting closes the popover")

  # --- multiselect -------------------------------------------------------------------
  click(multiId)
  let mpop = localId("multi.pop", multiId.id)
  expect(elementData(mpop).found, "multiSelect: click opens the popover")
  click(localIdWithIndex("multi.opt", 0'u32, multiId.id))
  expect(isSet(multiSel, 0), "multiSelect: row toggles its bit")
  click(localIdWithIndex("multi.opt", 2'u32, multiId.id))
  expect(isSet(multiSel, 0) and isSet(multiSel, 2),
    "multiSelect: rows accumulate")
  expect(not isSet(multiSel, 1), "multiSelect: untouched bit stays clear")
  click(localId("multi.all", multiId.id))
  expect(countSelected(multiSel) == 3, "multiSelect: All selects everything")
  click(localId("multi.none", multiId.id))
  expect(multiSel == 0'u64, "multiSelect: None clears")
  clickAt(vec2(700.0, 550.0))   # far from the field and its pop
  expect(not elementData(mpop).found, "multiSelect: click outside dismisses")

  # --- text field ---------------------------------------------------------------------
  click(tfId)
  typeStr("Lace")
  expect(nameText == "AdaLace", "textField: typing appends at the caret, got " &
    $nameText)
  pressKey(kevBackspace)
  expect(nameText == "AdaLac", "textField: backspace deletes one char")
  pressKey(kevEnter)
  pressKey(kevText)           # (ignored: no focus anymore)
  typeStr("x")
  expect(nameText == "AdaLac", "textField: Enter commits and blurs")

  # Escape reverts to the value focused with
  click(tfId)
  typeStr("!")
  expect(nameText == "AdaLac!", "textField: refocus keeps editing")
  pressKey(kevEscape)
  expect(nameText == "AdaLac", "textField: Escape reverts to the snapshot")

  # --- number field ---------------------------------------------------------------------
  click(tfId)
  pressKey(kevEnter)                     # leave the text field behind
  let incId = localId("num.inc", nfId.id)
  let decId = localId("num.dec", nfId.id)
  expect(elementData(incId).found and elementData(decId).found,
    "numberField: steppers laid out")
  click(incId)
  expect(qty == 4, "numberField: stepper click steps, got " & $qty)
  pressKey(kevEnter)                     # commit + blur the number field
  pressKey(kevUp)                        # unfocused: must not step
  expect(qty == 4, "numberField: arrows only act while focused")
  click(nfId)
  pressKey(kevUp)
  expect(qty == 5, "numberField: Up arrow steps while focused")
  pressKey(kevDown)
  pressKey(kevDown)
  expect(qty == 3, "numberField: Down arrow steps down")
  click(tfId)                            # click elsewhere: commit

  # --- text link ---------------------------------------------------------------------
  click(noteId)
  expect(noteClicked, "textLink: click reports true for the frame")

  expect(takeErrors().len == 0, "widgets: no clay errors after the session")

  echo "widgets_test: ", passed, " passed, ", failures, " failed"
  if failures > 0:
    quit 1

when isMainModule:
  try:
    main()
  except ErrorCode:
    echo "widgets_test aborted by ErrorCode"
    quit 1
