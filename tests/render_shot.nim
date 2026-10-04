## Headless render check: lays out a showcase of rounded panels/borders,
## draws one frame through the SDL3 renderer and saves a BMP for inspection.
## Run: SDL_VIDEODRIVER=offscreen ./bin/render_shot  (from the repo root)

import std/[syncio]

import clay
import ellipse/platform/platform
import ellipse/platform/renderer

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
  panelBg = rgb(28, 30, 38)
  panelBorder = rgb(60, 64, 78)
  accent = rgb(96, 130, 220)
  warm = rgb(220, 140, 80)
  textColor = rgb(230, 232, 238)

proc layoutShowcase() {.raises.} =
  setPointerState(vec2(-100.0, -100.0), false)
  let (w, h) = windowPixelSize()
  setLayoutDimensions(size(w, h))
  beginLayout()
  clay "app", row(width = grow(), height = grow(), alignX = centerX, alignY = centerY,
                  gap = 24, padding = padAll(24))
      .bg(rgb(12, 12, 16)):
    # Classic demo panel: 1px border around a 12px radius.
    clay "panel", col(gap = 16, padding = padAll(24), alignX = centerX,
                      width = fit(), height = fit())
        .bg(panelBg).border(1, panelBorder).corner(12):
      textElement("corner(12) + border(1)", TextConfig(fontSize: 20, color: textColor))
      clay "buttons", row(gap = 8):
        clay "b1", col(padding = padAll(8), width = fit(), height = fixedPx(48))
            .bg(rgb(52, 56, 72)).corner(8).border(2, panelBorder):
          textElement("r8 b2", TextConfig(fontSize: 24, color: textColor))
        clay "b2", col(padding = padAll(8), width = fit(), height = fixedPx(48))
            .bg(rgb(52, 56, 72)).corner(22).border(2, accent):
          textElement("r22 b2", TextConfig(fontSize: 24, color: textColor))

    # Thick uniform border: inner radius must follow the outer one.
    openElement(hashId("thick"),
      col(width = fixedPx(240), height = fixedPx(160), alignX = centerX,
          alignY = centerY)
        .bg(panelBg).corner(36).border(8, accent))
    textElement("r36 b8", TextConfig(fontSize: 20, color: textColor))
    closeElement()

    # Uneven side widths with rounded corners.
    var d = col(width = fixedPx(240), height = fixedPx(160), alignX = centerX,
                alignY = centerY)
    d.background = panelBg
    d.corner = allCorners(28)
    d.border = BorderConfig(color: warm,
      width: BorderWidth(left: 2, right: 6, top: 10, bottom: 3))
    openElement(hashId("uneven"), d)
    textElement("uneven widths", TextConfig(fontSize: 20, color: textColor))
    closeElement()

    # Per-corner radii.
    openElement(hashId("mixed"),
      col(width = fixedPx(200), height = fixedPx(160), alignX = centerX,
          alignY = centerY)
        .bg(panelBg)
        .corner(0.0, 48.0, 12.0, 24.0)   # tl, tr, bl, br
        .border(3, panelBorder))
    textElement("mixed corners", TextConfig(fontSize: 18, color: textColor))
    closeElement()

    # Fully rounded pill: radius clamped to half the height.
    openElement(hashId("pill"),
      col(width = fixedPx(260), height = fixedPx(64), alignX = centerX,
          alignY = centerY)
        .bg(rgb(40, 44, 56)).corner(40).border(4, accent))
    textElement("pill r40 b4", TextConfig(fontSize: 20, color: textColor))
    closeElement()
  endLayout()

proc main() {.raises.} =
  initialize()
  initializeRenderer()
  setCurrentContext(initContext(size(1280.0, 720.0)))
  setMeasureText(measureText)
  layoutShowcase()

  let ren = sdlRenderer()
  discard SDL_SetRenderDrawColor(ren, 12, 12, 16, 255)
  discard SDL_RenderClear(ren)
  drawCommands()

  var full = SDL_Rect(x: 0, y: 0, w: 1280, h: 720)
  let surf = SDL_RenderReadPixels(ren, addr full)
  if surf == nil:
    echo "readback failed"
    return
  discard SDL_SaveBMP(surf, "build/render_shot.bmp")
  SDL_DestroySurface(surf)
  echo "saved build/render_shot.bmp"

when isMainModule:
  try:
    main()
  except ErrorCode:
    discard
