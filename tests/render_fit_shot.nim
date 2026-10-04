## Headless check for viewport-constrained popovers: a "+ New" menu anchored
## at the top-right of a small window, where the unfitted popover would hang
## off the right edge (see the reported bug). Asserts the popover's final box
## lies fully inside the window and saves a BMP for eyeballing.
## Run: SDL_VIDEODRIVER=offscreen ./bin/render_fit_shot  (from the repo root)

import std/[syncio]

import clay
import ellipse/platform/platform
import ellipse/platform/renderer
import ellipse_ui/ui
import ellipse_ui/widgets/common

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
  initialize()
  initializeRenderer()
  setCurrentContext(initContext(size(winW, winH)))
  setMeasureText(measureText)

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

  let ren = sdlRenderer()
  discard SDL_SetRenderDrawColor(ren, 12, 12, 16, 255)
  discard SDL_RenderClear(ren)
  drawCommands()

  var full = SDL_Rect(x: 0, y: 0, w: int32(winW), h: int32(winH))
  let surf = SDL_RenderReadPixels(ren, addr full)
  if surf == nil:
    echo "readback failed"
    return
  discard SDL_SaveBMP(surf, "build/render_fit_shot.bmp")
  SDL_DestroySurface(surf)
  echo "saved build/render_fit_shot.bmp"

when isMainModule:
  try:
    main()
  except ErrorCode:
    discard
