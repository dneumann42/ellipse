import std/[syncio]

import clay
import ellipse/logger
import ellipse/platform/platform
import ellipse/platform/renderer

addHandler initStandardLogger()

const
  bgColor = rgb(12, 12, 16)
  panelBg = rgb(28, 30, 38)
  panelBorder = rgb(60, 64, 78)
  buttonBg = rgb(52, 56, 72)
  buttonHoverBg = rgb(84, 90, 116)
  textColor = rgb(230, 232, 238)

var count = 0

proc shade(over: bool): Color =
  if over:
    return buttonHoverBg
  return buttonBg

proc update() {.raises.} =
  let pointer = pointerState()
  setPointerState(vec2(pointer.x, pointer.y), pointer.down)

  # Keep the layout root in sync with the window: resize on the very first
  # update tick after the platform pumps a pixel-resize event.
  let (w, h) = windowPixelSize()
  let dims = layoutDimensions()
  if dims.width != w or dims.height != h:
    setLayoutDimensions(size(w, h))

  # Drain the previous frame's layout errors (if any) before declaring.
  let errs = takeErrors()
  if errs.len > 0:
    var msg = ""
    for e in errs:
      msg.add e.message
      msg.add "; "
    error "clay: ", msg
    # NOTE: a `{.varargs.}` template may not be the *last* statement of a
    # nested block yet -- Nimony asserts in finalir ("TagLit") if it is.
    discard

  # Clay's pointer queries hit *last* frame's boxes: handle input right here,
  # between `setPointerState` and this frame's `beginLayout` (frame contract).
  let clicked = pointerData(currentContext()).state == pressedThisFrame
  if clicked and pointerOver(hashId("dec")):
    dec count
  if clicked and pointerOver(hashId("inc")):
    inc count

  beginLayout()
  clay "app", row(width = grow(), height = grow(), alignX = centerX, alignY = centerY)
      .withBg(bgColor):
    clay "counter", col(gap = 16, padding = padAll(24), alignX = centerX)
        .withBg(panelBg).withBorder(1, panelBorder).withCorner(12):
      textElement($count, TextConfig(fontSize: 48, color: textColor))
      clay "buttons", row(gap = 8):
        clay "dec", col(width = fixedPx(64), height = fixedPx(48),
            alignX = centerX, alignY = centerY)
            .withBg(shade(pointerOver(hashId("dec")))).withCorner(8):
          textElement("-", TextConfig(fontSize: 28, color: textColor))
        clay "inc", col(width = fixedPx(64), height = fixedPx(48),
            alignX = centerX, alignY = centerY)
            .withBg(shade(pointerOver(hashId("inc")))).withCorner(8):
          textElement("+", TextConfig(fontSize: 28, color: textColor))
  endLayout()

proc render() {.raises.} =
  drawCommands()

when isMainModule:
  try:
    initialize()
    initializeRenderer()
    let (w, h) = windowPixelSize()
    setCurrentContext(initContext(size(w, h)))
    setMeasureText(measureText)
    start(update, render)
  except ErrorCode:
    discard
