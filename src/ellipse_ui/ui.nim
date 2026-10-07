import std/[syncio, math]

import clay
export clay

import ../ellipse/logger

import ellipse/platform/platform
import ellipse/platform/renderer

import ./theme
export theme

import ./focus
export focus

import ./keys
export keys

import ./events
export events

import ./cadence
export cadence

## --- wheel feel ----------------------------------------------------------------
##
## Scroll feel borrowed from the gothivania HUD (`src/hud/gui.cpp`): a fast
## wheel spin accumulates velocity and each notch moves progressively
## farther (acceleration, capped), and the accumulated notch count bleeds
## into the engine over an exponential ease (deceleration / glide). The
## clay-side spring on top of that adds the overshoot-and-settle at the
## ends. Frames run at whatever rate the pacer picks, so every step takes the
## frame's real `frameDelta()`.

const
  wheelBaseScale = 3.0'f32    ## pixels per notch at rest (x the engine's 10)
  wheelAccelGain = 1.4'f32    ## extra scale per accumulated notch velocity
  wheelAccelMax = 6.0'f32     ## cap of the velocity-driven scale
  wheelAccelDecay = 5.0'f32   ## how fast the spin velocity dies out
  wheelEaseRate = 16.0'f32    ## how fast pending notches bleed into motion

var
  wheelPending = 0.0'f32
  wheelVelocity = 0.0'f32

proc smoothedWheel*(rawY: float32, dt: float32): float32 =
  ## One frame of the gothivania wheel filter: velocity-scaled accumulation
  ## plus exponential release of the pending travel. Returns the engine-
  ## scale wheel delta to feed `updateScrollContainers` this frame.
  wheelVelocity *= exp(-dt * wheelAccelDecay)
  if rawY != 0.0:
    wheelVelocity += abs(rawY)
    let accel = min(wheelBaseScale + wheelVelocity * wheelAccelGain,
      wheelAccelMax)
    wheelPending += rawY * accel
  result = 0.0
  if wheelPending != 0.0:
    result = wheelPending * (1.0 - exp(-dt * wheelEaseRate))
    wheelPending -= result
    if abs(wheelPending) < 0.02:
      result += wheelPending
      wheelPending = 0.0

## --- press hold ----------------------------------------------------------------
##
## Clay reports the click *edge* (`pressedThisFrame`) but not which element the
## press belongs to, so after that single frame nothing can answer "is my
## button still being held down?". `updateUI` snapshots the pointer-over list
## on the press edge; while the pointer stays down, membership in that
## snapshot is the press claim of every element that contained the down point
## -- exactly what `clickedIn` reads, stretched over the whole hold. Release
## clears it, and dragging off the button does not: a held button stays
## compressed until the finger lifts.
##
## Widgets fold the claim into a *compressed state*: `shade(over, press)`
## sinks the surface to `buttonPressBg` and `squeeze(pad, press)` moves the
## content down by `pressOffset` -- top inset grows, bottom shrinks -- so the
## control looks pushed in without changing its outer box.

var pressHeld: seq[uint32] = @[]

proc notePressState*() =
  ## Fold this frame's pointer edge into the held-press snapshot: the down
  ## edge records the elements under the pointer, release clears them.
  ## `updateUI` calls it right after `setPointerState`; frame drivers that
  ## step the clay engine directly (tests) call it themselves.
  let ctx = currentContext()
  let pstate = ctx.pointerData().state
  if pstate == pressedThisFrame:
    let overIds = ctx.pointerOverIds()
    pressHeld.setLen(0)
    for el in overIds:
      pressHeld.add(el.id)
  elif pstate == released or pstate == releasedThisFrame:
    pressHeld.setLen(0)

proc pressing*(id: ElementId): bool =
  ## The primary button went down inside `id`'s box and is still held: the
  ## widget's compressed (pressed-in) look.
  for held in pressHeld:
    if held == id.id:
      return true
  return false

proc pressing*(): bool =
  ## `pressing` for the currently open element.
  pressing(ElementId(id: openElementId()))

proc shade*(over, press: bool): Color =
  ## The three-way raised-surface pick: a held press sinks the surface to
  ## `buttonPressBg`, else the pointer lights it with hover, else it rests.
  if press:
    return buttonPressBg
  if over:
    return buttonHoverBg
  return buttonBg

proc shade*(over, press: bool, idle: Color, hover = buttonHoverBg): Color =
  ## The same idle/hover/press pick with the resting colour chosen by the
  ## caller.
  if press:
    return buttonPressBg
  if over:
    return hover
  return idle

proc squeeze*(pad: Padding, press: bool): Padding =
  ## The compressed state's inset: while `press` the content box shifts down
  ## by `pressOffset`, keeping the sum of the insets -- and so a `fit`-sized
  ## widget's outer box -- unchanged.
  result = pad
  if press:
    let off = activeTheme.metrics.pressOffset
    result.top += off
    if result.bottom >= off:
      result.bottom -= off

var motionFilterInstalled = false

type InputHook* = proc () {.closure.}

var inputHooks: seq[InputHook] = @[]
var wheelHeld = false

proc holdWheel*() =
  ## Keep this frame's wheel away from the scroll containers -- called from
  ## an input hook that spends the wheel on something else (Ctrl + wheel
  ## zoom), so the same notch does not both zoom and scroll.
  wheelHeld = true

proc onInputFrame*(hook: InputHook) =
  ## Run `hook` in every `updateUI`, right after the input frame opens and
  ## before focus and widgets see the keys -- where app-wide bindings (the
  ## debug overlay's F1) take theirs with `consumeKeys`.
  inputHooks.add hook

proc motionChangesHover(x, y: float32; down: bool): bool =
  ## The pacer's motion filter: a pointer move needs a frame only when it
  ## changes the set of elements under the pointer (hover looks, cadences)
  ## -- held buttons and `trackPointer` frames are let through upstream.
  hoverChangesAt(vec2(x, y))

proc updateUI*(skipWheel: bool = false) =
  ## Advance the clay engine one input frame: pointer, held-press snapshot,
  ## wheel scrolling, layout dimensions, error drain. `skipWheel` holds the
  ## wheel back from the scroll containers for one frame -- the seam a zoom
  ## gesture (Ctrl + wheel) uses so the same notch does not both zoom and
  ## scroll. While the wheel glide or a scroll spring is still moving it
  ## asks the pacer for the next frame.
  if not motionFilterInstalled:
    motionFilterInstalled = true
    setMotionFilter(motionChangesHover)
  beginInputFrame()
  wheelHeld = false
  for hook in inputHooks:
    hook()

  # App shortcuts take their keys before focus and the widgets see them.
  runKeymaps()

  let pointer = pointerState()
  setPointerState(vec2(pointer.x, pointer.y), pointer.down)

  # Fold this frame's press edge into the held-press snapshot (see above).
  notePressState()

  # Tab / Shift+Tab walk the focus chain the last frame registered.
  stepFocus(keyEvents())

  # Wheel-driven scrolling for the widget set's clip containers (page and
  # panels, dropdown lists etc), through the accel/glide filter above.
  # Drag-scrolling stays off: widgets claim press themselves, and the
  # scrollbars drive containers directly via `setScrollPosition`.
  let wheel = wheelDelta()
  let dt = frameDelta()
  if skipWheel or wheelHeld:
    updateScrollContainers(false, vec2(0.0, 0.0), dt)
  else:
    updateScrollContainers(false,
      vec2(wheel.x, smoothedWheel(wheel.y, dt)), dt)
  if wheelPending != 0.0 or scrollAnimating():
    requestFrame()

  let (w, h) = windowPixelSize()
  let dims = layoutDimensions()
  if dims.width != w or dims.height != h:
    setLayoutDimensions(size(w, h))

  let errs = takeErrors()
  if errs.len > 0:
    var msg = ""
    for e in errs:
      msg.add e.message
      msg.add "; "
    error "clay: ", msg
    discard

template layout*(blk: untyped) =
  beginLayout()
  blk
  endLayout()

proc text*(value: string, fontSize: uint16 = activeTheme.text.control,
           color: Color = activeTheme.palette.textColor) =
  ## `textElement` with the live theme's body size and text colour -- the
  ## one-liner for labels inside items and layout blocks; pass a size
  ## (from `TextSizes`) to step off the default voice.
  textElement(value, TextConfig(fontSize: fontSize, color: color))

proc focusRing*(decl: ElementDeclaration, id: ElementId): ElementDeclaration =
  ## `decl` ringed in the accent colour while `id` holds keyboard focus --
  ## the one-liner a focusable widget adds to its frame:
  ## `.bg(...).corner(...).focusRing(id)`. Unfocused, `decl` is unchanged.
  if focused(id):
    let t = activeTheme
    return decl.border(max(t.metrics.borderRaised, 2), t.palette.accent)
  return decl

proc shade*(over: bool): Color =
  if over:
    return buttonHoverBg
  return buttonBg

proc shade*(over: bool, idle: Color, hover = buttonHoverBg): Color =
  ## The same raised/idle pick with the resting colour chosen by the
  ## caller: `.bg(shade(hovered(), panelBg))` for a list row that lives on
  ## a panel, `fieldBg` for one inside a sunken box.
  if over:
    return hover
  return idle

## --- items: bracketed child elements ------------------------------------------
##
## The low-level clay rhythm -- `openElement` / `configureOpenElement` /
## children / `closeElement` -- is what every repeated row or card dances
## to. `item` brackets that rhythm so screens read as nesting and content;
## the declaration stays a free-form clay builder at the call site. Like
## the `clay` blocks, the declaration is configured *while the element is
## open*, so it may call `hovered()` and `currentScrollOffset()`.
##
##   var r = 0
##   while r < 24:
##     item("list.row", r, row(width = grow(), padding = padAll(padItem))
##         .bg(shade(hovered(), panelBg)).corner(itemRadius)):
##       text("Entry " & $r)
##     inc r
##
## `listRow` and `listCard` are that pattern with the theme's list styling
## pre-answered -- take them when the default look fits, drop to `item`
## the moment it doesn't. The styling lives in the `listRowDecl` /
## `listCardDecl` procs, so a call site can reuse or fork it:
## `item(label, i, listRowDecl(idle = fieldBg)):`.

proc listRowDecl*(idle: Color = panelBg, hover = buttonHoverBg): ElementDeclaration =
  ## The standard list-row declaration (see `listRow`): `grow` wide,
  ## `fit` tall, `padItem` padded, vertically centred, `itemRadius`
  ## corners, `idle` at rest, `hover` under the pointer and the compressed
  ## fill while held. Reads the hover and press state of whatever element
  ## is open at the call.
  let t = activeTheme
  let press = pressing()
  result = row(width = grow(), height = fit(),
      padding = squeeze(padAll(t.metrics.padItem), press), alignY = centerY)
    .bg(shade(hovered(), press, idle, hover))
    .corner(t.radii.item)

proc listCardDecl*(width: SizingAxis, idle: Color = buttonBg,
                   hover = buttonHoverBg): ElementDeclaration =
  ## The standard hover-card declaration (see `listCard`): `width` across,
  ## full height, centred content, `padCard` inset, hairline border,
  ## `button` corners, `idle` at rest, `hover` under the pointer and the
  ## compressed fill while held.
  let t = activeTheme
  let press = pressing()
  result = col(width = width, height = grow(),
      alignX = centerX, alignY = centerY,
      padding = squeeze(padAll(t.metrics.padCard), press))
    .bg(shade(hovered(), press, idle, hover))
    .corner(t.radii.button)
    .border(t.metrics.borderHairline, t.palette.panelBorder)

template item*(id: untyped, decl: untyped, body: untyped): untyped =
  ## One element with an explicit id: open, configure, children, close.
  openElement(id)
  configureOpenElement(decl)
  body
  closeElement()

template item*(label: untyped, index: untyped, decl: untyped,
               body: untyped): untyped =
  ## The loop-child form: clay's local id for `label` at position `index`
  ## inside the open parent -- the stable hover identity repeating rows
  ## and cards need, without spelling out `localIdWithIndex`.
  item(localIdWithIndex(label, uint32(index)), decl, body)

template listRow*(label: untyped, index: untyped, body: untyped): untyped =
  ## A themed hover row inside a list panel, per `listRowDecl()`.
  item(label, index, listRowDecl(), body)

template listCard*(label: untyped, index: untyped, width: untyped,
                   body: untyped): untyped =
  ## A themed hover card for horizontal strips, per `listCardDecl(width)`.
  item(label, index, listCardDecl(width), body)

type MenuBody* = proc() {.closure.}

## Menus are Tab stops too. On a focused menu button Enter, Space or Down
## opens it; in an open menu Up/Down move the highlight, Enter picks,
## Escape closes, and Left/Right step to the neighbouring menu of the bar
## (staying open). Focus leaving the button -- Tab, a click elsewhere --
## closes its menu.

var
  openMenuId = 0'u32
  menuPress = false
  menuSelected = false
  menuCursor = -1          ## keyboard-highlighted item of the open menu
  menuItemIdx = 0          ## items declared so far by the open menu
  menuItemCount = 0        ## items the open menu declared last frame
  menuEnter = false        ## Enter picks the highlighted item this frame
  menuBarNow: seq[uint32] = @[]   ## menu buttons of the bar being laid out
  menuBarLast: seq[uint32] = @[]  ## ... and of the previous frame
  menuKeysGen = 0'u32      ## frame whose keys a menu already handled

proc menuPressed(): bool =
  currentContext().pointerData().state == pressedThisFrame

proc openMenu(id: uint32, cursor = -1) =
  ## Open menu `id`; a keyboard open passes `cursor = 0` to highlight the
  ## first item, a click leaves the highlight to the pointer.
  openMenuId = id
  menuCursor = cursor
  menuItemCount = 0

proc stepMenuBar(id: uint32, dir: int, wasOpen: bool) =
  ## Left/Right: hand focus (and the open state) to the neighbouring menu.
  var at = -1
  for i in 0 ..< menuBarLast.len:
    if menuBarLast[i] == id:
      at = i
  if at < 0 or menuBarLast.len < 2:
    return
  let next = menuBarLast[(at + dir + menuBarLast.len) mod menuBarLast.len]
  setFocus(ElementId(id: next))
  if wasOpen:
    openMenu(next, 0)

proc menuKeys(btnId: ElementId) =
  ## Fold the focused menu button's keys into the open-menu state. Once
  ## per frame: a Left/Right hands focus to a menu laid out later in the
  ## same frame, which must not see the key again.
  let gen = currentContext().generation
  if menuKeysGen == gen:
    return
  menuKeysGen = gen
  let evs = keyEvents()
  for ev in evs:
    let isOpen = openMenuId == btnId.id
    case ev.kind
    of kevEnter:
      if not isOpen:
        openMenu(btnId.id, 0)
      elif menuCursor >= 0:
        menuEnter = true
      else:
        openMenuId = 0'u32
    of kevDown:
      if not isOpen:
        openMenu(btnId.id, 0)
      elif menuItemCount > 0:
        menuCursor = (menuCursor + 1) mod menuItemCount
    of kevUp:
      if isOpen and menuItemCount > 0:
        menuCursor = if menuCursor <= 0: menuItemCount - 1 else: menuCursor - 1
    of kevEscape:
      if isOpen:
        openMenuId = 0'u32
    of kevLeft:
      stepMenuBar(btnId.id, -1, isOpen)
    of kevRight:
      stepMenuBar(btnId.id, 1, isOpen)
    else:
      if isSpace(ev) and not isOpen:
        openMenu(btnId.id, 0)

proc toolBar*(id: string, blk: MenuBody) =
  let t = activeTheme
  menuPress = false
  menuBarLast = menuBarNow
  menuBarNow = @[]
  openElement(elementId(id))
  configureOpenElement(row(width = grow(), height = fixedPx(t.metrics.toolbarHeight),
                           gap = t.metrics.padToolbar,
                           padding = padAll(t.metrics.padToolbar)).bg(t.palette.panelBg))
  blk()
  closeElement()

proc menu*(label: string, blk: MenuBody) =
  let t = activeTheme
  let btnId = elementId("menu." & label)
  let popId = elementId("menu." & label & ".pop")
  menuBarNow.add btnId.id
  registerFocus(btnId, 0, popId)
  let clicked = menuPressed()
  if clicked:
    if pointerOver(btnId):
      if openMenuId == btnId.id: openMenuId = 0'u32
      else: openMenu(btnId.id)
      menuPress = true
    elif openMenuId == btnId.id:
      if pointerOver(popId): menuPress = true   # press inside the popover
      else: openMenuId = 0'u32                  # press elsewhere: dismiss
  if focused(btnId):
    menuKeys(btnId)
  elif openMenuId == btnId.id:
    openMenuId = 0'u32                          # focus left: close
  let isOpen = openMenuId == btnId.id

  let over = pointerOver(btnId)
  let press = pressing(btnId) or isOpen   # an open menu sits pressed in
  openElement(btnId)
  configureOpenElement(col(width = fit(), height = grow(), alignX = centerX,
      alignY = centerY, padding = squeeze(padAll(t.metrics.padButton), press))
      .bg(shade(over, press))
      .corner(t.radii.button)
      .border(t.metrics.borderHairline, t.palette.panelBorder)
      .focusRing(btnId))
  textElement(label, TextConfig(fontSize: t.text.menu, color: t.palette.textColor))
  closeElement()

  if isOpen:
    openElement(popId)
    configureOpenElement(col(width = fit(), height = fit(), gap = t.metrics.gapList,
                             padding = padAll(t.metrics.padOption))
        .bg(t.palette.panelBg).border(t.metrics.borderHairline, t.palette.panelBorder)
        .corner(t.radii.popover)
        .floating(attachElementId,
                  offset = vec2(0.0, t.metrics.popoverOffset), zIndex = 100,
                  points = AttachPoints(element: pointLeftTop,
                                        parent: pointLeftBottom),
                  parentId = btnId.id,
                  fitViewport = true))
    menuSelected = false
    menuItemIdx = 0
    if elementData(popId).found:
      # The shadow attaches to the popover's last-frame box; on the popover's
      # very first frame no box is published yet, so paint it transparent for
      # one frame instead of flashing at a stale anchor. The element is still
      # declared, keeping the rows' auto-ids stable across frames.
      var sh = col(width = grow(), height = grow())
        .bg(if elementData(popId).box.width > 0: t.palette.shadow else: rgb(0, 0, 0, 0)).corner(t.radii.popoverShadow)
        .floating(attachParent,
                  offset = vec2(0.0, 4.0), zIndex = 99,
                  points = AttachPoints(element: pointLeftTop,
                                        parent: pointLeftTop),
                  capture = passThroughPointer)
      sh.floating.expand = size(4.0, 4.0)
      openElement(elementId("menu." & label & ".shadow"))
      configureOpenElement(sh)
      closeElement()
    blk()
    menuItemCount = menuItemIdx
    if menuCursor >= menuItemCount:
      menuCursor = menuItemCount - 1
    menuEnter = false
    if menuSelected:
      openMenuId = 0'u32
    closeElement()

proc menuSeparator*() =
  let t = activeTheme
  openElement()
  var d = row(width = grow(), height = fixedPx(9))
  d.border = BorderConfig(color: t.palette.panelBorder,
                          width: BorderWidth(top: t.metrics.borderHairline))
  configureOpenElement(d)
  closeElement()

## --- widgets ------------------------------------------------------------------
##
## Reusable UI components with *slots*: parameters of type `proc(): void`
## that call sites fill with procs or a trailing block. `widget` is a
## Nimony template plugin (`ellipse_ui/deps/mwidget`) that turns a
## definition like
##
##   widget PageWrapper(title: string, rightAction: proc(): void,
##                      body: proc(): void):
##     clay "page", col(width = grow(), height = grow()).bg(bgColor):
##       clay "toolbar", row(width = grow(), height = fixedPx(48)):
##         textElement(title, TextConfig(fontSize: 24))
##         rightAction()
##       body()
##
## into the pair `proc PageWrapperImpl*` (the widget proper: slots are real
## `{.closure.}` proc params with `emptySlot` defaults, so `slot()` is an
## ordinary call -- conditional, repeated, or passed on like
## `toolBar("bar", body)`) plus a template `PageWrapper*` providing the
## trailing-block call syntax:
##
##   PageWrapper(title = "Home", rightAction = renderAct):
##     textElement("This is the body")
##
## Named arguments bind slots by name, the block after the colon fills the
## last declared slot, and the wrapper routes it through a named
## `{.closure.}` proc -- so the block may read and modify the *caller's*
## locals. One Nimony constraint still applies inside a widget body: a
## `do:` literal there cannot reference the widget's own slots (plain
## `do:` procs don't capture); pass the slot as an argument instead.
##
## A widget may produce a value -- `-> T` after the parameters -- and give
## parameters defaults with `name = value` (the type is inferred from the
## value, as for a proc parameter):
##
##   widget focusable checkbox(label: string, checked: bool,
##                             fontSize = activeTheme.text.control) -> bool:
##     ...
##     result = if clicked: not checked else: checked
##
##   agree = checkbox(hashId("agree"), "Agree", agree)
##
## The default is repeated in the wrapper template and evaluated at the
## call site, so it should only name things every caller can see.
##
## Keyboard focus is opt-in per widget with the `focusable` modifier:
##
##   widget focusable Chip(label: string):
##     item(id, row(padding = padAll(6)).bg(panelBg).focusRing(id)):
##       text(label)
##     if clickedIn(id) or keyActivated(id):
##       ...
##
##   Chip(id = hashId("save"), label = "Save", tabIndex = 1)
##
## The widget gains an `id: ElementId` parameter (first) and a
## `tabIndex: int = 0` one (last before the block slot), and registers on
## the Tab chain before its body runs: click focuses it, Tab / Shift+Tab
## walk the chain in `tabIndex` order, and the body reads `focused(id)`,
## `gainedFocus(id)` and `keyActivated(id)`. See `ellipse_ui/focus`.
##
## Widgets talk upward with *events*: typed payloads that bubble from the
## emitting widget through its enclosing widgets until one catches them.
## A widget declares what it emits and catches at the top of its body:
##
##   widget focusable Toggle(label: string, on: bool):
##     emits Toggled(on: bool)        # declares the event type
##     ...
##     if clickedIn(id) or keyActivated(id):
##       emit Toggled(on: not on)
##
##   widget Settings(body: proc(): void):
##     event Toggled(e):              # caught: stops here...
##       dirty = true
##       reemit                       # ...unless passed on
##     body()
##
## The emitter's own handlers run first, then each enclosing widget's, then
## a `handleEvents:` block around the whole tree. A handler may change the
## payload before a `reemit`, or `emit` a different event, which starts at
## the handler's parent. Every emit is recorded per frame (`eventLog`) with
## the widgets it passed and the ones that handled it. See
## `ellipse_ui/events`.

proc emptySlot*() =
  ## The no-op slot: what a widget renders where a call site passed nothing.

template widget*(head: untyped, body: untyped) {.
  plugin: "ellipse_ui/deps/mwidget".}

## --- standard widget events ----------------------------------------------------
##
## What the stock widgets emit, each tagged with the emitter's element id so
## one handler can serve several controls (`if e.id == saveId: ...`). The
## widgets still return their value too -- `checked = checkbox(...)` keeps
## working -- the event is the same news for code further up the tree.

## `button` / `textLink` clicked, or Enter/Space on it while focused.
defineEvent Pressed(id: ElementId)
## `checkbox` / `switch` flipped; `on` is the new state.
defineEvent Toggled(id: ElementId, on: bool)
## A single choice moved: `comboBox` selection, `tabStrip` tab.
defineEvent Picked(id: ElementId, index: int)
## A text widget's contents changed this frame (`textField`,
## `multilineField`, `editor`); `text` is the new value.
defineEvent TextChanged(id: ElementId, text: string)
## Enter in a `textField`: the value the field is left with.
defineEvent TextCommitted(id: ElementId, text: string)
## `numberField` produced a new value (typed, stepped or committed).
defineEvent NumberChanged(id: ElementId, value: float)
## A `menuItem` was chosen; menu items are identified by their label.
defineEvent MenuPicked(label: string)

widget focusable button(label: string, width = fit(), height = fit(),
                        fontSize = 0'u16) -> bool:
  ## A themed push button: the three-way raised surface (`shade`), the
  ## compressed hold state (`squeeze`), and the label centred in it.
  ## `fontSize` overrides the theme's button size -- dialogs pass the
  ## smaller `control` size so compact footers fit their labels. A Tab
  ## stop at `tabIndex`; Enter or Space presses it while focused. Returns
  ## true and emits `Pressed` on the press.
  emits Pressed
  let t = activeTheme
  let fs = if fontSize > 0: fontSize else: t.text.button
  let over = pointerOver(id)
  let press = pressing(id)
  result = (over and currentContext().pointerData().state == pressedThisFrame) or
    keyActivated(id)
  openElement(id)
  configureOpenElement(col(width = width, height = height, alignX = centerX,
      alignY = centerY, padding = squeeze(padAll(t.metrics.padButton), press))
      .bg(shade(over, press))
      .corner(t.radii.button)
      .border(t.metrics.borderRaised, t.palette.panelBorder)
      .focusRing(id))
  textElement(label, TextConfig(fontSize: fs, color: t.palette.textColor))
  closeElement()
  if result:
    emit Pressed(id: id)

widget menuItem(label: string, shortcut = "") -> bool:
  ## One row of an open `menu`: true -- and a `MenuPicked` event carrying
  ## `label` -- when it is clicked or Enter picks it from the keyboard.
  emits MenuPicked
  let t = activeTheme
  openElement()
  let idx = menuItemIdx
  inc menuItemIdx
  let cursor = idx == menuCursor
  let press = pressing()
  result = (menuPressed() and hovered()) or (menuEnter and cursor)
  if result:
    menuSelected = true
  var d = row(width = grow(), height = fit(), gap = 16,
              padding = squeeze(padAll(t.metrics.padMenuItem), press))
  if press:
    d.background = buttonPressBg
  elif hovered() or cursor:
    d.background = buttonHoverBg
  d.corner = allCorners(t.radii.inner)
  configureOpenElement(d)
  textElement(label, TextConfig(fontSize: t.text.menu, color: t.palette.textColor))
  if shortcut.len > 0:
    openElement()
    configureOpenElement(row(width = grow(), height = fit(), alignX = right))
    textElement(shortcut, TextConfig(fontSize: t.text.menu, color: t.palette.dimColor))
    closeElement()
  closeElement()
  if result:
    emit MenuPicked(label: label)
