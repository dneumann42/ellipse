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
var noteText = "ab\ncd\nef"
var qty = 3
var noteClicked = false
var panelTab = 0
var refreshClicked = false

var comboOpts: seq[string] = @[]
comboOpts.add "Alpha"
comboOpts.add "Beta"
comboOpts.add "Gamma"

var multiOpts: seq[string] = @[]
multiOpts.add "One"
multiOpts.add "Two"
multiOpts.add "Three"

var viewTabs: seq[string] = @[]
viewTabs.add "General"
viewTabs.add "Audio"
viewTabs.add "Video"

let cbId = hashId("cb")
let swId = hashId("sw")
let comboId = hashId("combo")
let multiId = hashId("multi")
let tfId = hashId("tf")
let mlId = hashId("ml")
let nfId = hashId("qty")
let noteId = hashId("note")
let viewId = hashId("view")
let refreshId = hashId("refresh")
let cardHostId = hashId("cardhost")
let cardRowId = hashId("cardrow")

proc cardActions() =
  if button(refreshId, "Refresh"):
    refreshClicked = true

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
    noteText = multilineField(mlId, noteText, "Notes", rows = 3)
    qty = intNumberField(nfId, qty, 1)
    if textLink(noteId, "Notes"):
      noteClicked = true
    TabbedView(id = viewId, tabs = viewTabs):
      panelTab = activeTab(viewId)
      bodyText("Page " & $panelTab)
    clay "cardhost", row(width = grow(), height = fit()):
      Card(title = "Network", actions = cardActions):
        bodyText("Linked at 1 Gb/s")
    clay "cardrow", row(width = grow(), height = fit()):
      CardRow:
        StatCard(label = "Up", value = "4d", hint = "since boot")
        StatCard(label = "Pings", value = "12", hint = "")
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

proc pressChord(ch: char, ctrl = true, alt = false, shift = false) =
  pushKeyEvent KeyEvent(kind: kevLetter, ch: ch, ctrl: ctrl, alt: alt,
    shift: shift)
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

  # --- Emacs-style editing chords ------------------------------------------------
  click(tfId)                      # "AdaLac", caret at the end; snapshot "AdaLac"
  pressChord('a')                  # C-a: beginning of line
  typeStr("say ")                  # "say AdaLac", caret after the space
  pressChord('f', ctrl = false, alt = true)   # M-f: over "AdaLac"
  pressChord('b', ctrl = false, alt = true)   # M-b: back to its start
  pressChord('k')                  # C-k: kill "AdaLac"
  expect(nameText == "say ", "emacs: C-k kills to end of line, got " & $nameText)
  pressChord('a')                  # C-a
  pressChord('e')                  # C-e: end of the "say " line
  typeStr("hello ")                # "say hello "
  pressChord('y')                  # C-y: yank the kill back
  expect(nameText == "say hello AdaLac",
    "emacs: C-y reinserts the kill buffer, got " & $nameText)
  pressChord('w')                  # C-w: rub out the previous word
  expect(nameText == "say hello ",
    "emacs: C-w kills a word backward, got " & $nameText)
  pressChord('d', ctrl = false, alt = true)   # M-d at the edge: no-op
  pressChord('a')                  # C-a
  pressChord('f')                  # C-f: one char
  pressChord('d')                  # C-d: delete forward the 'a'
  expect(nameText == "sy hello ",
    "emacs: C-f moves a char, C-d deletes it, got " & $nameText)
  pressChord('h')                  # C-h: backspace the 's'
  expect(nameText == "y hello ", "emacs: C-h deletes backward, got " & $nameText)
  pressChord('e')                  # C-e: end of line
  pressChord('u')                  # C-u: kill to the line's start
  expect(nameText == "", "emacs: C-u kills to start of line, got " & $nameText)
  typeStr("keep")
  pressChord('g')                  # C-g: cancel -> revert to the snapshot
  expect(nameText == "AdaLac", "emacs: C-g cancels like Escape, got " & $nameText)

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

  # --- multiline field: Enter is text, line motions cross newlines --------------
  pressKey(kevEnter)                     # leave the text field behind
  click(mlId)                            # "ab\ncd\nef", caret at the end
  pressKey(kevUp)                        # to the end of line two
  pressChord('a')                        # C-a: start of "cd"
  typeStr("X")                           # "ab\nXcd\nef"
  pressKey(kevEnter)                     # a plain newline, not a commit
  expect(noteText == "ab\nX\ncd\nef",
    "multilineField: Enter inserts a newline, got " & $noteText)
  pressKey(kevUp)                        # back to the "X" line
  pressChord('e')                        # C-e: end of that line
  typeStr("!")                           # "ab\nX!\ncd\nef"
  pressChord('d', ctrl = false, alt = true)  # M-d must not cross the line edge
  expect(noteText == "ab\nX!\ncd\nef",
    "multilineField: line motions stay on their line, got " & $noteText)
  pressKey(kevDown)                      # caret down to line "cd"
  pressChord('b')                        # C-b: one left, off the line edge
  pressChord('k')                        # C-k: kill the rest of that line
  expect(noteText == "ab\nX!\nc\nef",
    "multilineField: C-k kills to line end, got " & $noteText)
  click(tfId)                            # blur commits the buffer

  # --- text link ---------------------------------------------------------------------
  click(noteId)
  expect(noteClicked, "textLink: click reports true for the frame")

  # --- tabbed view -------------------------------------------------------------------
  let strip = localId("tabs.strip", viewId.id)
  let panel = localId("tabs.panel", viewId.id)
  let tab1 = localIdWithIndex("tabs.tab", 1'u32, viewId.id)
  expect(elementData(strip).found and elementData(panel).found,
    "TabbedView: strip and panel laid out")
  expect(elementData(tab1).found, "TabbedView: every tab laid out")
  expect(activeTab(viewId) == 0 and panelTab == 0,
    "TabbedView: the first tab starts selected")
  click(tab1)
  expect(activeTab(viewId) == 1, "TabbedView: clicking a tab selects it")
  expect(panelTab == 1, "TabbedView: the body sees the new index in-frame")
  setActiveTab(viewId, 2)
  frame()
  expect(panelTab == 2, "TabbedView: setActiveTab moves the selection")
  viewTabs.setLen(2)                        # the third tab goes away
  frame()
  expect(activeTab(viewId) == 0, "TabbedView: a stale index clamps to the first tab")
  viewTabs.add "Video"
  setActiveTab(viewId, 2)

  # --- cards ---------------------------------------------------------------------------
  let cardRoot = ElementId(id: textChildId(cardHostId.id))
  let card = elementData(cardRoot)
  let host = elementData(cardHostId)
  expect(card.found, "Card: laid out inside its host")
  expect(card.found and host.found and
      card.box.width > host.box.width - 1.0,
    "Card: grows to its container, got " & $card.box.width)
  expect(elementData(refreshId).found, "Card: the actions slot renders")
  click(refreshId)
  expect(refreshClicked, "Card: actions stay interactive")
  let rowRoot = ElementId(id: textChildId(cardRowId.id))
  let statA = elementData(ElementId(id: hashNumber(0'u32, rowRoot.id)))
  let statB = elementData(ElementId(id: hashNumber(1'u32, rowRoot.id)))
  expect(statA.found and statB.found, "CardRow: both stat cards laid out")
  let dw = statA.box.width - statB.box.width
  expect(dw < 0.5 and dw > -0.5, "CardRow: siblings share the width evenly, got " &
    $statA.box.width & " vs " & $statB.box.width)

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
