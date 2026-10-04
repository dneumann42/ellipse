import std/[syncio]

import clay
export clay

import ../ellipse/logger

import ellipse/platform/platform
import ellipse/platform/renderer

const
  bgColor* = rgb(12, 12, 16)
  panelBg* = rgb(28, 30, 38)
  panelBorder* = rgb(60, 64, 78)
  buttonBg* = rgb(52, 56, 72)
  buttonHoverBg* = rgb(84, 90, 116)
  textColor* = rgb(230, 232, 238)

proc updateUI*() =
  beginInputFrame()

  let pointer = pointerState()
  setPointerState(vec2(pointer.x, pointer.y), pointer.down)

  # Wheel-driven scrolling for the widget set's clip containers (dropdown
  # lists etc). Drag-scrolling stays off: widgets claim press themselves.
  let wheel = wheelDelta()
  updateScrollContainers(false, vec2(wheel.x, wheel.y), 0.016'f32)

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
  let over = pointerOver(id)
  result = over and currentContext().pointerData().state == pressedThisFrame
  openElement(id)
  configureOpenElement(col(width = width, height = height, alignX = centerX,
      alignY = centerY, padding = padAll(8))
      .bg(shade(over))
      .corner(8)
      .border(2, panelBorder))
  textElement(label, TextConfig(fontSize: 28, color: textColor))
  closeElement()

type MenuBody* = proc() {.closure.}

var
  openMenuId = 0'u32
  menuPress = false
  menuSelected = false

proc menuPressed(): bool =
  currentContext().pointerData().state == pressedThisFrame

proc toolBar*(id: string, blk: MenuBody) =
  menuPress = false
  openElement(elementId(id))
  configureOpenElement(row(width = grow(), height = fixedPx(48), gap = 4,
                           padding = padAll(4)).bg(panelBg))
  blk()
  closeElement()

proc menu*(label: string, blk: MenuBody) =
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
                           alignY = centerY, padding = padAll(8))
      .bg(shade(over or isOpen))
      .corner(8)
      .border(1, panelBorder))
  textElement(label, TextConfig(fontSize: 18, color: textColor))
  closeElement()

  if isOpen:
    openElement(popId)
    configureOpenElement(col(width = fit(), height = fit(), gap = 2,
                             padding = padAll(6))
        .bg(panelBg).border(1, panelBorder).corner(10)
        .floating(attachElementId,
                  offset = vec2(0.0, 6.0), zIndex = 100,
                  points = AttachPoints(element: pointLeftTop,
                                        parent: pointLeftBottom),
                  parentId = btnId.id))
    menuSelected = false
    if elementData(popId).found:
      var sh = col(width = grow(), height = grow())
        .bg(rgb(0, 0, 0, 70)).corner(14)
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
  openElement()
  result = menuPressed() and hovered()
  if result:
    menuSelected = true
  var d = row(width = grow(), height = fit(), gap = 16, padding = padAll(8))
  if hovered():
    d.background = buttonHoverBg
  d.corner = allCorners(6)
  configureOpenElement(d)
  textElement(label, TextConfig(fontSize: 18, color: textColor))
  if shortcut.len > 0:
    openElement()
    configureOpenElement(row(width = grow(), height = fit(), alignX = right))
    textElement(shortcut, TextConfig(fontSize: 18, color: rgb(130, 134, 150)))
    closeElement()
  closeElement()

proc menuSeparator*() =
  openElement()
  var d = row(width = grow(), height = fixedPx(9))
  d.border = BorderConfig(color: panelBorder, width: BorderWidth(top: 1))
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

