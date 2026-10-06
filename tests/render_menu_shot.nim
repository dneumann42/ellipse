## Headless check for the toolbar menu/popover flow: lays out a few frames,
## simulates a pointer press over the "File" menu button and saves a BMP with
## the popover (and its drop shadow) open.
## Run: SDL_VIDEODRIVER=offscreen ./bin/render_menu_shot  (from the repo root)

import std/[syncio]

import clay
import ellipse/platform/renderer
import ellipse_ui/ui

var count = 0

proc frame(pointer: Vec2, down: bool) {.raises.} =
  setPointerState(pointer, down)
  beginLayout()
  clay "app", col(width = grow(), height = grow(), alignX = centerX)
      .bg(bgColor):
    toolBar("toolbar") do():
      menu("File") do():
        if menuItem("Increment", "Ctrl++"): inc count
        if menuItem("Decrement", "Ctrl+-"): dec count
        menuSeparator()
        if menuItem("Reset"): count = 0
      menu("View") do():
        if menuItem("Large count"): discard
    clay "body", col(width = grow(), height = grow(), alignX = centerX,
                     alignY = centerY):
      clay "counter", col(gap = 16, padding = padAll(24), alignX = centerX)
          .bg(panelBg).border(1, panelBorder).corner(12):
        textElement($count, TextConfig(fontSize: 48, color: textColor))
  endLayout()

proc main() {.raises.} =
  bootup()

  # Frame 1: neutral. Frame 2: press over the "File" button (top-left of the
  # toolbar). Frame 3+: popover open, shadow attached -- this is what we save.
  frame(vec2(640.0, 400.0), false)
  frame(vec2(30.0, 24.0), true)
  frame(vec2(60.0, 120.0), false)   # pointer moved onto the popover

  if not saveScreenshot("build/render_menu_shot.bmp"):
    echo "readback failed"
    return
  echo "saved build/render_menu_shot.bmp"

when isMainModule:
  try:
    main()
  except ErrorCode:
    discard
