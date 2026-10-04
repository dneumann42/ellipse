## Headless check for the toolbar menu/popover flow: lays out a few frames,
## simulates a pointer press over the "File" menu button and saves a BMP with
## the popover (and its drop shadow) open.
## Run: SDL_VIDEODRIVER=offscreen ./bin/render_menu_shot  (from the repo root)

import std/[syncio]

import clay
import ellipse/platform/platform
import ellipse/platform/renderer
import ellipse_ui/ui

type
  SDL_Rect {.importc: "SDL_Rect", header: "<SDL3/SDL.h>".} = object
    x, y, w, h: int32
  SDL_Surface {.importc: "SDL_Surface", header: "<SDL3/SDL.h>".} = object

proc SDL_SetRenderDrawColor(ren: ptr SDL_Renderer; r, g, b, a: uint8): bool {.
  importc: "SDL_SetRenderDrawColor", header: "<SDL3/SDL.h>".}
proc SDL_RenderClear(ren: ptr SDL_Renderer): bool {.
  importc: "SDL_RenderClear", header: "<SDL3/SDL.h>".}
proc SDL_RenderReadPixels(ren: ptr SDL_Renderer; rect: ptr SDL_Rect): ptr SDL_Surface {.
  importc: "SDL_RenderReadPixels", header: "<SDL3/SDL.h>".}
proc SDL_SaveBMP(surf: ptr SDL_Surface; file: cstring): bool {.
  importc: "SDL_SaveBMP", header: "<SDL3/SDL.h>".}
proc SDL_DestroySurface(surf: ptr SDL_Surface) {.
  importc: "SDL_DestroySurface", header: "<SDL3/SDL.h>".}

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
  initialize()
  initializeRenderer()
  setCurrentContext(initContext(size(1280.0, 720.0)))
  setMeasureText(measureText)

  # Frame 1: neutral. Frame 2: press over the "File" button (top-left of the
  # toolbar). Frame 3+: popover open, shadow attached -- this is what we save.
  frame(vec2(640.0, 400.0), false)
  frame(vec2(30.0, 24.0), true)
  frame(vec2(60.0, 120.0), false)   # pointer moved onto the popover

  let ren = sdlRenderer()
  discard SDL_SetRenderDrawColor(ren, 12, 12, 16, 255)
  discard SDL_RenderClear(ren)
  drawCommands()

  var full = SDL_Rect(x: 0, y: 0, w: 1280, h: 720)
  let surf = SDL_RenderReadPixels(ren, addr full)
  if surf == nil:
    echo "readback failed"
    return
  discard SDL_SaveBMP(surf, "build/render_menu_shot.bmp")
  SDL_DestroySurface(surf)
  echo "saved build/render_menu_shot.bmp"

when isMainModule:
  try:
    main()
  except ErrorCode:
    discard
