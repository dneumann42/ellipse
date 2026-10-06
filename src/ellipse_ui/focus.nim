## Keyboard focus: one focus slot for the whole widget set, and the Tab
## chain that walks it.
##
## A widget becomes *focusable* by registering itself while it lays out:
##
##   registerFocus(id, tabIndex)
##
## The `widget` macro does that for you -- define it as
## `widget focusable Name(...)` and it injects the `id`/`tabIndex`
## parameters and the registration (see `ellipse_ui/ui`). Registering
## makes the widget:
##
##   - focusable by click: a press inside its box takes focus, a press
##     outside while it holds focus lets go;
##   - a stop on the Tab chain: Tab / Shift+Tab walk the widgets registered
##     during the last frame.
##
## Tab order follows the HTML `tabindex` rules: widgets with a positive
## `tabIndex` come first, ascending (ties in layout order), then every
## `tabIndex == 0` widget in layout order. A negative `tabIndex` keeps the
## widget click-focusable but off the Tab chain. The chain wraps around.
##
## Tab only moves focus when nothing is focused or the focus holder is on
## the chain itself: an element that took focus by hand (`setFocus`) without
## registering -- the full document editor, say -- keeps its Tab key.
##
## The chain is rebuilt every frame from the registrations, so it always
## matches what is on screen; it rotates lazily on clay's frame generation,
## so frame drivers need nothing beyond calling `stepFocus` with the frame's
## keys (`updateUI` does).

import clay

import ellipse/platform/platform

type
  FocusEntry = object
    id: uint32
    tabIndex: int

var
  focusId = 0'u32          ## the element holding keyboard focus, 0 = none
  serial = 0'u32           ## bumped on every focus change
  seenSerial = 0'u32       ## the serial the focus holder last laid out with
  gainedId = 0'u32         ## the holder that saw focus arrive this frame
  chainNow: seq[FocusEntry] = @[]   ## registrations of the frame in layout
  chainNowGen = 0'u32               ## clay generation `chainNow` belongs to
  chainLast: seq[FocusEntry] = @[]  ## the frame before `chainNow`'s
  chainLastGen = 0'u32

proc focusedId*(): uint32 =
  ## The element id holding focus now, 0 for none.
  focusId

proc focused*(id: ElementId): bool =
  ## `id` holds keyboard focus.
  focusId != 0'u32 and focusId == id.id

proc focusSerial*(): uint32 =
  ## A counter bumped on every focus change. State that belongs to one
  ## *focus session* (a field's caret and Escape snapshot) records it and
  ## re-seeds when it no longer matches.
  serial

proc setFocusId(id: uint32) =
  if focusId != id:
    focusId = id
    serial += 1'u32

proc setFocus*(id: ElementId) =
  ## Give `id` keyboard focus.
  setFocusId(id.id)

proc blur*() =
  ## Drop keyboard focus: nothing holds it.
  setFocusId(0'u32)

proc gainedFocus*(id: ElementId): bool =
  ## Focus arrived at `id` this frame -- by click, Tab or `setFocus` -- the
  ## edge a widget uses to select-all or scroll itself into view. Valid
  ## after the widget's `registerFocus`.
  gainedId != 0'u32 and gainedId == id.id

proc chain(): seq[FocusEntry] =
  ## The Tab chain: the registrations of the last *complete* frame. Mid-
  ## layout that is the previous generation, between frames the one just
  ## laid out; a frame that registered nothing yields an empty chain.
  let ctx = currentContext()
  var complete = ctx.generation
  if ctx.openStack.len > 1:     # mid-layout: root + its scope are open
    complete -= 1'u32
  if chainNowGen == complete:
    return chainNow
  if chainLastGen == complete:
    return chainLast
  return @[]

proc noteRegistration(id: uint32, tabIndex: int) =
  let gen = currentContext().generation
  if gen != chainNowGen:
    chainLast = chainNow
    chainLastGen = chainNowGen
    chainNow = @[]
    chainNowGen = gen
  for e in chainNow:
    if e.id == id:
      return
  chainNow.add FocusEntry(id: id, tabIndex: tabIndex)

proc registerFocus*(id: ElementId, tabIndex: int = 0,
                    inside: ElementId = ElementId()) =
  ## Declare `id` focusable for this frame (call it while laying the
  ## widget out): it joins the Tab chain at `tabIndex`, and this frame's
  ## press folds in -- a press inside takes focus, a press elsewhere while
  ## it holds focus lets go. `inside` names a floating part that counts as
  ## the widget's own (a dropdown's popover): pressing it keeps focus.
  noteRegistration(id.id, tabIndex)
  let ctx = currentContext()
  if ctx.pointerData().state == pressedThisFrame:
    if pointerOver(id):
      setFocusId(id.id)
    elif focusId == id.id and not (inside.id != 0'u32 and pointerOver(inside)):
      setFocusId(0'u32)
  if focusId == id.id:
    gainedId = if seenSerial != serial: id.id else: 0'u32
    seenSerial = serial
  elif gainedId == id.id:
    gainedId = 0'u32

proc tabOrder(entries: seq[FocusEntry]): seq[uint32] =
  ## Chain ids in Tab order: positive indices ascending (stable), then the
  ## zeros in layout order; negatives are left out.
  result = @[]
  var ranked: seq[FocusEntry] = @[]
  for e in entries:
    if e.tabIndex > 0:
      # insertion sort; strict `>` keeps equal indices in layout order
      ranked.add e
      var at = ranked.len - 1
      while at > 0 and ranked[at - 1].tabIndex > e.tabIndex:
        let prev = ranked[at - 1]
        ranked[at] = prev
        dec at
      ranked[at] = e
  for e in ranked:
    result.add e.id
  for e in entries:
    if e.tabIndex == 0:
      result.add e.id

proc moveFocus(dir: int) =
  let order = tabOrder(chain())
  if order.len == 0:
    return
  var at = -1
  for i in 0 ..< order.len:
    if order[i] == focusId:
      at = i
  var next = 0
  if at < 0:
    next = if dir > 0: 0 else: order.len - 1
  else:
    next = (at + dir + order.len) mod order.len
  setFocusId(order[next])

proc focusNext*() =
  ## Move focus one stop forward along the Tab chain (wrapping).
  moveFocus(1)

proc focusPrev*() =
  ## Move focus one stop back along the Tab chain (wrapping).
  moveFocus(-1)

proc onChain(id: uint32): bool =
  let entries = chain()
  for e in entries:
    if e.id == id:
      return true
  return false

proc stepFocus*(evs: seq[KeyEvent]) =
  ## Fold a frame's Tab / Shift+Tab presses into the focus slot. Run it
  ## between frames, before layout -- `updateUI` does, with the frame's
  ## key events. Ctrl/Alt+Tab are left to the app.
  if focusId != 0'u32 and not onChain(focusId):
    return
  for ev in evs:
    if ev.kind == kevTab and not ev.ctrl and not ev.alt:
      moveFocus(if ev.shift: -1 else: 1)

proc isSpace*(ev: KeyEvent): bool =
  ## The space bar: arrives as text, so non-text widgets test for it.
  ev.kind == kevText and ev.text == " "

proc keyHit*(id: ElementId, kind: KeyEventKind): bool =
  ## A `kind` key went down this frame while `id` holds focus.
  if not focused(id):
    return false
  let evs = keyEvents()
  for ev in evs:
    if ev.kind == kind:
      return true
  return false

proc spaceHit*(id: ElementId): bool =
  ## Space went down this frame while `id` holds focus.
  if not focused(id):
    return false
  let evs = keyEvents()
  for ev in evs:
    if isSpace(ev):
      return true
  return false

proc keyActivated*(id: ElementId): bool =
  ## Enter or Space went down this frame while `id` holds focus -- the
  ## keyboard twin of a click, for buttons and toggles.
  keyHit(id, kevEnter) or spaceHit(id)
