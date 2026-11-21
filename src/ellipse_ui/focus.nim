## Keyboard focus: one focus slot for the whole widget set, and the Tab
## chain that walks it. See `documentation/nim-tutorial.md` §7 (Focus and
## the keyboard) and §8 (Keymaps and shortcuts).
{.push gcsafe.}


import clay
import ./reloadstate

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
  chainNow {.threadvar.}: seq[FocusEntry]
  chainNowGen = 0'u32               ## clay generation `chainNow` belongs to
  chainLast {.threadvar.}: seq[FocusEntry]
  chainLastGen = 0'u32
chainNow = @[]   ## registrations of the frame in layout
chainLast = @[]  ## the frame before `chainNow`'s

var reloadFocusId = 0'u32
registerUiState("ellipse/focus", proc(): uint32 = focusId,
  proc(value: uint32) =
    focusId = value
    reloadFocusId = value)

proc finishFocusReload*() =
  ## A removed widget must not claim focus if it is introduced later.
  reloadFocusId = 0'u32

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
                    inside: ElementId = ElementId(),
                    inside2: ElementId = ElementId()) =
  ## Declare `id` focusable for this frame (call it while laying the
  ## widget out): it joins the Tab chain at `tabIndex`, and this frame's
  ## press folds in -- a press inside takes focus, a press elsewhere while
  ## it holds focus lets go. `inside` names a floating part that counts as
  ## the widget's own (a dropdown's popover): pressing it keeps focus.
  ## `inside2` names a second such part (a popover's open submenu).
  if reloadFocusId != 0 and id.id == reloadFocusId:
    # Resolve restored focus as widgets register, after application startup
    # focus requests. This also keeps a restored popover from closing itself.
    setFocusId(id.id)
    reloadFocusId = 0'u32
  noteRegistration(id.id, tabIndex)
  let ctx = currentContext()
  if ctx.pointerData().state == pressedThisFrame:
    if pointerOver(id):
      setFocusId(id.id)
    elif focusId == id.id and not (
        (inside.id != 0'u32 and pointerOver(inside)) or
        (inside2.id != 0'u32 and pointerOver(inside2))):
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

proc releaseVanishedFocus*() =
  ## A holder absent from the frame just laid out can never run its
  ## press-elsewhere release -- its widget left the layout (a hidden
  ## panel, a virtualized table row, a switched tab). Without this sweep
  ## such a holder keeps the slot forever, and the app reads the stale id
  ## as a live caret: typing that swallows every key. Run once per
  ## completed frame; a holder the frame still shows stays put.
  if focusId != 0'u32 and not onChain(focusId):
    setFocusId(0'u32)

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
