## Tests for the standard widget set (ellipse_ui/widgets).
##
## Lays the widgets out in a clay context frame by frame, drives them with
## pointer presses (last-frame boxes, as the frame contract wants) and with
## synthetic key events through the platform queue, and checks the values
## they hand back to their callers -- and the events they emit, which a
## root `handleEvents` block records alongside.

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

proc nearly(a, b: float32): bool =
  let d = a - b
  d < 0.01'f32 and d > -0.01'f32

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

# --- events: everything the widgets emit, as "Kind id value" lines --------------

var seen: seq[string] = @[]

proc idName(id: ElementId): string =
  if id == cbId: "cb"
  elif id == swId: "sw"
  elif id == comboId: "combo"
  elif id == multiId: "multi"
  elif id == tfId: "tf"
  elif id == mlId: "ml"
  elif id == nfId: "qty"
  elif id == noteId: "note"
  elif id == viewId: "view"
  elif id == refreshId: "refresh"
  else: "?" & $id.id

proc saw(line: string): bool =
  ## `line` was emitted (and reached the root) since the last `clearSeen`.
  for x in seen:
    if x == line:
      return true
  return false

proc sawKind(prefix: string): bool =
  for x in seen:
    if x.len >= prefix.len and substr(x, 0, prefix.len - 1) == prefix:
      return true
  return false

proc clearSeen() =
  seen = @[]

proc shownSeen(): string =
  result = ""
  for x in seen:
    result.add " | "
    result.add x

proc cardActions() =
  if button(refreshId, "Refresh"):
    refreshClicked = true

proc drawWidgets()

proc draw() =
  beginLayout()
  handleEvents:
    event Pressed(e):
      seen.add "Pressed " & idName(e.id)
    event Toggled(e):
      seen.add "Toggled " & idName(e.id) & " " & $e.on
    event Picked(e):
      seen.add "Picked " & idName(e.id) & " " & $e.index
    event SelectionChanged(e):
      seen.add "SelectionChanged " & idName(e.id) & " " & $e.selection
    event TextChanged(e):
      seen.add "TextChanged " & idName(e.id) & " " & e.text
    event TextCommitted(e):
      seen.add "TextCommitted " & idName(e.id) & " " & e.text
    event NumberChanged(e):
      seen.add "NumberChanged " & idName(e.id)
    event IntChanged(e):
      seen.add "IntChanged " & idName(e.id) & " " & $e.value
    drawWidgets()
  endLayout()

proc drawWidgets() =
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
      panelTab = tabIndex
      bodyText("Page " & $tabIndex)
    clay "cardhost", row(width = grow(), height = fit()):
      Card(title = "Network", actions = cardActions):
        bodyText("Linked at 1 Gb/s")
    clay "cardrow", row(width = grow(), height = fit()):
      CardRow:
        StatCard(label = "Up", value = "4d", hint = "since boot")
        StatCard(label = "Pings", value = "12", hint = "")

proc frame() =
  notePressState()   # apps fold the press claim inside updateUI; step it here
  stepFocus(keyEvents())   # ... and Tab, likewise
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

proc main()  =
  setCurrentContext(initContext(size(800.0, 600.0)))
  setMeasureText(mono)

  # settle clay's pointer state machine the way `updateUI` does every frame
  setPointerState(vec2(-100.0, -100.0), false)
  frame()
  expect(elementData(hashId("root")).found, "widgets: root lays out")
  expect(takeErrors().len == 0, "widgets: frame reports no clay errors")

  # --- checkbox + switch -----------------------------------------------------------
  clearSeen()
  click(cbId)
  expect(agree, "checkbox: click toggles on")
  expect(saw("Toggled cb true"), "events: checkbox emits Toggled," &
    shownSeen())
  clearSeen()
  click(swId)
  expect(wifi, "switch: click toggles on")
  expect(saw("Toggled sw true") and not saw("Toggled cb false"),
    "events: switch emits Toggled with its own id," & shownSeen())
  click(cbId)
  expect(not agree, "checkbox: second click toggles off")

  # --- compressed state: the press claim spans the hold, not just its edge --
  beginInputFrame()
  setPointerState(boxCenter(cbId), true)
  frame()                       # down edge: the checkbox claims the press
  expect(pressing(cbId), "pressing: the down edge claims the checkbox")
  expect(not pressing(swId), "pressing: the claim stays where the press began")
  beginInputFrame()
  setPointerState(boxCenter(cbId), true)   # still held: state -> pressed
  frame()
  expect(pressing(cbId), "pressing: the claim survives the hold frames")
  beginInputFrame()
  setPointerState(boxCenter(cbId), false)
  frame()
  expect(not pressing(cbId), "pressing: release clears the claim")
  expect(agree, "pressing: the held press still fired exactly one click")

  # --- combobox ---------------------------------------------------------------------
  click(comboId)
  let popId = localId("combo.pop", comboId.id)
  expect(elementData(popId).found, "comboBox: click opens the popover")
  let opt0 = localIdWithIndex("combo.opt", 0'u32, comboId.id)
  expect(elementData(opt0).found, "comboBox: options laid out in the popover")
  clearSeen()
  click(opt0)
  expect(comboSel == 0, "comboBox: row click selects, got " & $comboSel)
  expect(saw("Picked combo 0"), "events: comboBox emits Picked," & shownSeen())
  expect(not elementData(popId).found, "comboBox: selecting closes the popover")

  # --- multiselect -------------------------------------------------------------------
  click(multiId)
  let mpop = localId("multi.pop", multiId.id)
  expect(elementData(mpop).found, "multiSelect: click opens the popover")
  clearSeen()
  click(localIdWithIndex("multi.opt", 0'u32, multiId.id))
  expect(isSet(multiSel, 0), "multiSelect: row toggles its bit")
  expect(saw("SelectionChanged multi 1"),
    "events: multiSelect emits SelectionChanged," & shownSeen())
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
  clearSeen()
  typeStr("Lace")
  expect(nameText == "AdaLace", "textField: typing appends at the caret, got " &
    $nameText)
  expect(saw("TextChanged tf AdaLace"),
    "events: textField emits TextChanged with the new text," & shownSeen())
  pressKey(kevBackspace)
  expect(nameText == "AdaLac", "textField: backspace deletes one char")
  clearSeen()
  pressKey(kevEnter)
  expect(saw("TextCommitted tf AdaLac") and not sawKind("TextChanged"),
    "events: Enter emits TextCommitted, no change," & shownSeen())
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
  clearSeen()
  click(incId)
  expect(qty == 4, "numberField: stepper click steps, got " & $qty)
  expect(saw("IntChanged qty 4") and not sawKind("NumberChanged"),
    "events: intNumberField translates NumberChanged to IntChanged," &
    shownSeen())
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
  clearSeen()
  pressKey(kevEnter)                     # a plain newline, not a commit
  expect(saw("TextChanged ml ab\nX\ncd\nef"),
    "events: multilineField emits TextChanged," & shownSeen())
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

  # --- multiline field: grows a line per newline, scrolls past maxLines ----------
  # mono metrics: an 18px line pitch, 8px field padding top and bottom. The
  # 600px root overflows and would squeeze the field to its `rows` minimum,
  # so give the layout room while measuring growth.
  setLayoutDimensions(size(800.0, 2000.0))
  beginInputFrame()
  frame()
  let lineH = 18.0'f32
  let padH = 16.0'f32
  expect(nearly(elementData(mlId).box.height, 4.0 * lineH + padH),
    "multilineField: four lines tall, got " & $elementData(mlId).box.height)
  pressKey(kevDown)                      # onto "ef"
  pressChord('e')                        # its end, the buffer's end
  pressKey(kevEnter)                     # a trailing newline opens line five
  beginInputFrame()
  frame()
  expect(noteText == "ab\nX!\nc\nef\n",
    "multilineField: trailing newline typed, got " & $noteText)
  expect(nearly(elementData(mlId).box.height, 5.0 * lineH + padH),
    "multilineField: a trailing newline grows the box, got " &
    $elementData(mlId).box.height)
  var n = 0
  while n < 6:                           # eleven lines: past maxLines = 8
    pressKey(kevEnter)
    inc n
  beginInputFrame()
  frame()
  beginInputFrame()
  frame()
  expect(nearly(elementData(mlId).box.height, 8.0 * lineH + padH),
    "multilineField: height caps at maxLines, got " &
    $elementData(mlId).box.height)
  let mlScroll = scrollContainerData(mlId)
  expect(mlScroll.found and nearly(mlScroll.position.y, -3.0 * lineH),
    "multilineField: scrolls to keep the caret line in view, got " &
    $mlScroll.position.y)
  setScrollPosition(mlId, vec2(0.0, 0.0))   # the wheel, back to the top
  beginInputFrame()
  frame()
  beginInputFrame()
  frame()
  expect(nearly(scrollContainerData(mlId).position.y, 0.0),
    "multilineField: a still caret lets the text scroll, got " &
    $scrollContainerData(mlId).position.y)
  noteText = "ab\nX!\nc\nef"
  setLayoutDimensions(size(800.0, 600.0))
  click(tfId)                            # blur commits the buffer

  # --- focus: every control is a Tab stop, in layout order ----------------------
  pressKey(kevEnter)                     # leave the text field: nothing focused
  expect(focusedId() == 0'u32, "focus: Enter left the field")
  var stops: seq[ElementId] = @[]
  stops.add cbId
  stops.add swId
  stops.add comboId
  stops.add multiId
  stops.add tfId
  stops.add mlId
  stops.add nfId
  stops.add noteId
  stops.add tabStripId(viewId)
  stops.add refreshId
  var k = 0
  while k < stops.len:
    pressKey(kevTab)
    expect(focused(stops[k]), "focus: Tab stop " & $k & " in layout order")
    inc k
  pressKey(kevTab)
  expect(focused(cbId), "focus: Tab wraps to the first control")
  pressKey(kevTab, shift = true)
  expect(focused(refreshId), "focus: Shift+Tab wraps back to the last")

  # button: Enter presses it
  refreshClicked = false
  clearSeen()
  pressKey(kevEnter)
  expect(refreshClicked, "focus: Enter presses a focused button")
  expect(saw("Pressed refresh"), "events: button emits Pressed," & shownSeen())

  # checkbox: Space flips it; switch: Enter flips it
  pressKey(kevTab)                       # wraps to the checkbox
  let agreeBefore = agree
  typeStr(" ")
  expect(agree != agreeBefore, "focus: Space toggles a focused checkbox")
  pressKey(kevTab)
  let wifiBefore = wifi
  pressKey(kevEnter)
  expect(wifi != wifiBefore, "focus: Enter toggles a focused switch")

  # combo: arrows step the selection, Enter opens, Tab away closes
  pressKey(kevTab)
  expect(focused(comboId), "focus: Tab -> combo")
  comboSel = 0
  pressKey(kevDown)
  expect(comboSel == 1, "focus: Down steps the combo, got " & $comboSel)
  pressKey(kevUp)
  pressKey(kevUp)
  expect(comboSel == 0, "focus: Up stops at the first option")
  let comboPop = localId("combo.pop", comboId.id)
  pressKey(kevEnter)
  expect(elementData(comboPop).found, "focus: Enter opens the combo list")
  pressKey(kevEscape)
  expect(not elementData(comboPop).found, "focus: Escape closes the list")
  expect(focused(comboId), "focus: Escape keeps the combo focused")
  pressKey(kevEnter)
  pressKey(kevTab)
  expect(not elementData(comboPop).found, "focus: Tab away closes the list")

  # multiselect: Space opens, arrows move the highlight, Space ticks
  expect(focused(multiId), "focus: Tab -> multiselect")
  let multiPop = localId("multi.pop", multiId.id)
  multiSel = 0'u64
  typeStr(" ")
  expect(elementData(multiPop).found, "focus: Space opens the multiselect")
  expect(multiSel == 0'u64, "focus: the opening Space ticks nothing")
  pressKey(kevDown)
  typeStr(" ")
  expect(isSet(multiSel, 1) and countSelected(multiSel) == 1,
    "focus: Space ticks the highlighted option")
  pressKey(kevEscape)
  expect(not elementData(multiPop).found, "focus: Escape closes the list")

  # text field: Tab seeds the caret at the end, Escape reverts to it
  pressKey(kevTab)
  expect(focused(tfId), "focus: Tab -> text field")
  let nameBefore = nameText
  typeStr("e")
  expect(nameText == nameBefore & "e",
    "focus: a tabbed-to field seeds its caret at the end, got " & $nameText)
  pressKey(kevEscape)
  expect(nameText == nameBefore,
    "focus: Escape reverts to the value Tab arrived with, got " & $nameText)

  # number field: tabbing out commits the typed buffer
  pressKey(kevTab)                       # nothing focused -> first stop
  while not focused(nfId):
    pressKey(kevTab)
  let qtyBefore = qty
  typeStr("0")                           # buffer "<qty>0"
  pressKey(kevTab)
  expect(qty == qtyBefore * 10,
    "focus: tabbing out commits the number buffer, got " & $qty)

  # link: Enter follows it
  expect(focused(noteId), "focus: Tab -> text link")
  noteClicked = false
  pressKey(kevEnter)
  expect(noteClicked, "focus: Enter follows a focused link")
  noteClicked = false

  # tab strip: Left/Right switch tabs, wrapping
  pressKey(kevTab)
  setActiveTab(viewId, 0)
  clearSeen()
  pressKey(kevRight)
  expect(activeTab(viewId) == 1, "focus: Right selects the next tab")
  expect(saw("Picked view 1"), "events: tabStrip emits Picked," & shownSeen())
  pressKey(kevLeft)
  pressKey(kevLeft)
  expect(activeTab(viewId) == viewTabs.len - 1, "focus: Left wraps")
  setActiveTab(viewId, 0)
  blur()
  pressKey(kevEscape)                    # settle a frame with nothing focused

  # --- text link ---------------------------------------------------------------------
  clearSeen()
  click(noteId)
  expect(noteClicked, "textLink: click reports true for the frame")
  expect(saw("Pressed note"), "events: textLink emits Pressed," & shownSeen())

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

  # --- items and scrollPanel -----------------------------------------------------
  # a separate, self-consistent tree: repeated layouts must see the same shape.
  proc drawItems() =
    beginLayout()
    clay "itemsroot", col(width = grow(), height = grow(), gap = 4):
      scrollPanel "list", col(width = grow(), height = fixedPx(60), gap = 1)
          .bg(fieldBg)
          .border(hairline, panelBorder)
          .corner(panelRadius)
          .clip(horizontal = false, vertical = true,
                childOffset = currentScrollOffset()):
        var i = 0
        while i < 8:
          listRow("list.row", i):
            text("Row " & $i)
          inc i
      # the raw `item` form: an explicit decl over the themed preset
      item("plain", 3, row(width = grow(), height = fit())
          .bg(shade(hovered(), panelBg))
          .corner(itemRadius)):
        text("Plain item")
      listCard("list.card", 0, fixedPx(120)):
        text("Card")
    endLayout()

  beginInputFrame()
  setPointerState(vec2(-100.0, -100.0), false)
  drawItems()
  beginInputFrame()
  drawItems()          # second frame: the clip data is published, bars appear
  let listId = elementId("list")
  expect(elementData(listId).found, "scrollPanel: the panel lays out")
  let row0 = elementData(localIdWithIndex("list.row", 0'u32, listId.id))
  let row7 = elementData(localIdWithIndex("list.row", 7'u32, listId.id))
  expect(row0.found and row7.found, "listRow: indexed rows lay out")
  expect(row0.found and nearly(row0.box.height, 30.0),
    "listRow: height = mono text + 2x padItem, got " & $row0.box.height)
  expect(row0.found and nearly(row0.box.width, 800.0),
    "listRow: grows to the panel width, got " & $row0.box.width)
  expect(elementData(localId("sb.vthumb", elementId("list.bar").id)).found,
    "scrollPanel: the bar's thumb appears once the content overflows")
  expect(elementData(localIdWithIndex("plain", 3'u32,
      elementId("itemsroot").id)).found, "item: explicit-id form lays out")
  let card0 = elementData(localIdWithIndex("list.card", 0'u32,
    elementId("itemsroot").id))
  expect(card0.found and nearly(card0.box.width, 120.0),
    "listCard: fixed width honoured, got " & $card0.box.width)
  let sc = scrollContainerData(listId)
  expect(sc.found and sc.vertical and sc.contentDimensions.height > 60.0,
    "scrollPanel: children scroll the clip container")

  expect(takeErrors().len == 0, "widgets: no clay errors after the session")

  echo "widgets_test: ", passed, " passed, ", failures, " failed"
  if failures > 0:
    quit 1

when isMainModule:
  try:
    main()
  except CatchableError:
    echo "widgets_test aborted by ErrorCode"
    quit 1
