import std/[syncio]

import clay
export clay

import ellipse/platform/platform
import ellipse/platform/renderer

const
  bgColor* = rgb(12, 12, 16)
  panelBg* = rgb(28, 30, 38)
  panelBorder* = rgb(60, 64, 78)
  buttonBg* = rgb(52, 56, 72)
  buttonHoverBg* = rgb(84, 90, 116)
  textColor* = rgb(230, 232, 238)

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

