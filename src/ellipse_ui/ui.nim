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

proc updateUI*() =
  beginInputFrame()

  let pointer = pointerState()
  setPointerState(vec2(pointer.x, pointer.y), pointer.down)

  # Wheel-driven scrolling for the widget set's clip containers (page and
  # panels, dropdown lists etc), through the accel/glide filter above.
  # Drag-scrolling stays off: widgets claim press themselves, and the
  # scrollbars drive containers directly via `setScrollPosition`.
  let wheel = wheelDelta()
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

proc shade*(over: bool): Color =
  if over:
    return buttonHoverBg
  return buttonBg

proc button*(id: ElementId, label: string, width = fit(), height = fit()): bool =
  let t = activeTheme
  let over = pointerOver(id)
  result = over and currentContext().pointerData().state == pressedThisFrame
  openElement(id)
  configureOpenElement(col(width = width, height = height, alignX = centerX,
      alignY = centerY, padding = padAll(t.metrics.padButton))
      .bg(shade(over))
      .corner(t.radii.button)
      .border(t.metrics.borderRaised, t.palette.panelBorder))
  textElement(label, TextConfig(fontSize: t.text.button,
    color: t.palette.textColor))
  closeElement()

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
  openElement(btnId)
  configureOpenElement(col(width = fit(), height = grow(), alignX = centerX,
      alignY = centerY, padding = padAll(t.metrics.padButton))
      .bg(shade(over or isOpen))
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
                  parentId = btnId.id))
    menuSelected = false
    if elementData(popId).found:
      var sh = col(width = grow(), height = grow())
        .bg(t.palette.shadow).corner(t.radii.popoverShadow)
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
  result = menuPressed() and hovered()
  if result:
    menuSelected = true
  var d = row(width = grow(), height = fit(), gap = 16,
              padding = padAll(t.metrics.padMenuItem))
  if hovered():
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

