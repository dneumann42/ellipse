## Headless render check: lays out a showcase of rounded panels/borders,
## draws one frame through the SDL3 renderer and saves a BMP for inspection.
## Run: SDL_VIDEODRIVER=offscreen ./bin/render_shot  (from the repo root)

import std/[syncio]

import clay
import ellipse/platform/platform
import ellipse/platform/renderer

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
  bootup()
  layoutShowcase()

  if not saveScreenshot("build/render_shot.bmp"):
    echo "readback failed"
    return
  echo "saved build/render_shot.bmp"

when isMainModule:
  try:
    main()
  except ErrorCode:
    discard
