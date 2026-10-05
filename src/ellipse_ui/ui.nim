import std/[syncio, math]

import clay
export clay

import ../ellipse/logger

import ellipse/platform/platform
import ellipse/platform/renderer

import ./theme
export theme

## --- wheel feel ----------------------------------------------------------------
##
## Scroll feel borrowed from the gothivania HUD (`src/hud/gui.cpp`): a fast
## wheel spin accumulates velocity and each notch moves progressively
## farther (acceleration, capped), and the accumulated notch count bleeds
## into the engine over an exponential ease (deceleration / glide). The
## clay-side spring on top of that adds the overshoot-and-settle at the
## ends. Fixed 60 Hz update ticks, so `dt` is a constant.

const
  frameDt* = 1.0'f32 / 60.0'f32
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

proc updateUI*(skipWheel: bool = false) =
  ## Advance the clay engine one input frame: pointer, held-press snapshot,
  ## wheel scrolling, layout dimensions, error drain. `skipWheel` holds the
  ## wheel back from the scroll containers for one frame -- the seam a zoom
  ## gesture (Ctrl + wheel) uses so the same notch does not both zoom and
  ## scroll.
  beginInputFrame()

  let pointer = pointerState()
  setPointerState(vec2(pointer.x, pointer.y), pointer.down)

  # Fold this frame's press edge into the held-press snapshot (see above).
  notePressState()

  # Wheel-driven scrolling for the widget set's clip containers (page and
  # panels, dropdown lists etc), through the accel/glide filter above.
  # Drag-scrolling stays off: widgets claim press themselves, and the
  # scrollbars drive containers directly via `setScrollPosition`.
  let wheel = wheelDelta()
  if skipWheel:
    updateScrollContainers(false, vec2(0.0, 0.0), frameDt)
  else:
    updateScrollContainers(false,
      vec2(wheel.x, smoothedWheel(wheel.y, frameDt)), frameDt)

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

proc button*(id: ElementId, label: string, width = fit(), height = fit(),
             fontSize: uint16 = 0): bool =
  ## A themed push button: the three-way raised surface (`shade`), the
  ## compressed hold state (`squeeze`), and the label centred in it.
  ## `fontSize` overrides the theme's button size -- dialogs pass the
  ## smaller `control` size so compact footers fit their labels.
  let t = activeTheme
  let fs = if fontSize > 0: fontSize else: t.text.button
  let over = pointerOver(id)
  let press = pressing(id)
  result = over and currentContext().pointerData().state == pressedThisFrame
  openElement(id)
  configureOpenElement(col(width = width, height = height, alignX = centerX,
      alignY = centerY, padding = squeeze(padAll(t.metrics.padButton), press))
      .bg(shade(over, press))
      .corner(t.radii.button)
      .border(t.metrics.borderRaised, t.palette.panelBorder))
  textElement(label, TextConfig(fontSize: fs, color: t.palette.textColor))
  closeElement()

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

var
  openMenuId = 0'u32
  menuPress = false
  menuSelected = false

proc menuPressed(): bool =
  currentContext().pointerData().state == pressedThisFrame

proc toolBar*(id: string, blk: MenuBody) =
  let t = activeTheme
  menuPress = false
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
  let clicked = menuPressed()
  if clicked:
    if pointerOver(btnId):
      openMenuId = if openMenuId == btnId.id: 0'u32 else: btnId.id
      menuPress = true
    elif openMenuId == btnId.id:
      if pointerOver(popId): menuPress = true   # press inside the popover
      else: openMenuId = 0'u32                  # press elsewhere: dismiss
  let isOpen = openMenuId == btnId.id

  let over = pointerOver(btnId)
  let press = pressing(btnId) or isOpen   # an open menu sits pressed in
  openElement(btnId)
  configureOpenElement(col(width = fit(), height = grow(), alignX = centerX,
      alignY = centerY, padding = squeeze(padAll(t.metrics.padButton), press))
      .bg(shade(over, press))
      .corner(t.radii.button)
      .border(t.metrics.borderHairline, t.palette.panelBorder))
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
    if menuSelected:
      openMenuId = 0'u32
    closeElement()

proc menuItem*(label: string, shortcut = ""): bool =
  let t = activeTheme
  openElement()
  let press = pressing()
  result = menuPressed() and hovered()
  if result:
    menuSelected = true
  var d = row(width = grow(), height = fit(), gap = 16,
              padding = squeeze(padAll(t.metrics.padMenuItem), press))
  if press:
    d.background = buttonPressBg
  elif hovered():
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

proc emptySlot*() =
  ## The no-op slot: what a widget renders where a call site passed nothing.

template widget*(head: untyped, body: untyped) {.
  plugin: "ellipse_ui/deps/mwidget".}

