## Headless check for viewport-constrained popovers: a "+ New" menu anchored
## at the top-right of a small window, where the unfitted popover would hang
## off the right edge (see the reported bug). Asserts the popover's final box
## lies fully inside the window and saves a BMP for eyeballing.
## Run: SDL_VIDEODRIVER=offscreen ./bin/render_fit_shot  (from the repo root)

import std/[syncio]

import clay
import ellipse/platform/renderer
import ellipse_ui/ui
import ellipse_ui/widgets/common

const
  winW = 420.0'f32
  winH = 260.0'f32

var count = 0

proc frame(pointer: Vec2, down: bool) {.raises.} =
  setPointerState(pointer, down)
  beginLayout()
  clay "app", col(width = grow(), height = grow())
      .bg(bgColor):
    toolBar("toolbar") do():
      spacer()
      menu("New") do():
        if menuItem("New Task"): inc count
        if menuItem("New Board"): inc count
    clay "body", col(width = grow(), height = grow(), alignX = centerX,
                     alignY = centerY):
      textElement($count, TextConfig(fontSize: 32, color: textColor))
  endLayout()

proc main() {.raises.} =
  bootup(winW, winH)

  # Frame 1: neutral, so the button's box is published. Frame 2: press the
  # right-aligned "New" button. Frame 3: popover open, pointer resting on it.
  frame(vec2(200.0, 200.0), false)
  let btnBox = elementData(elementId("menu.New")).box
  frame(vec2(btnBox.x + btnBox.width / 2, btnBox.y + btnBox.height / 2), true)
  frame(vec2(btnBox.x + 10.0, btnBox.y + 40.0), false)

  let popBox = elementData(elementId("menu.New.pop")).box
  let inside = popBox.x >= 0 and popBox.y >= 0 and
    popBox.x + popBox.width <= winW and popBox.y + popBox.height <= winH
  echo("popover box: (", popBox.x, ",", popBox.y, ", ", popBox.width, "x",
       popBox.height, ") inside window: ", inside)
  if not inside:
    quit 1

  if not saveScreenshot("build/render_fit_shot.bmp", int32(winW), int32(winH)):
    echo "readback failed"
    return
  echo "saved build/render_fit_shot.bmp"

when isMainModule:
  try:
    main()
  except ErrorCode:
    discard
