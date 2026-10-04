## Checkboxes: `checkbox` toggles a caller-owned bool.
##
## The tick box itself is a filled inner square rather than a glyph -- the
## renderer only promises rectangles and the UI font, so no `✓` to tofu out.

import clay
import ../ui

import ./common

proc checkbox*(id: ElementId, label: string, checked: bool,
               fontSize: uint16 = 18): bool =
  ## A labelled tick box. Returns the state to store back: `checked` flipped
  ## when the user clicked it this frame.
  let over = pointerOver(id)
  let clicked = over and pressedNow()

  openElement(id)
  configureOpenElement(row(gap = 10, width = fit(), height = fit(),
      alignY = centerY, padding = padAll(4))
    .bg(if over: buttonBg else: Color())
    .corner(8))

  openElement()
  configureOpenElement(col(width = fixedPx(20), height = fixedPx(20),
      alignX = centerX, alignY = centerY)
    .bg(fieldBg)
    .corner(5)
    .border(1, if checked: accent else: panelBorder))
  if checked:
    openElement()
    configureOpenElement(col(width = fixedPx(10), height = fixedPx(10))
        .bg(accent).corner(3))
    closeElement()
  closeElement()

  textElement(label, TextConfig(fontSize: fontSize, color: textColor))
  closeElement()

  result = if clicked: not checked else: checked

proc switch*(id: ElementId, label: string, on: bool): bool =
  ## The same control dressed as an on/off slider: the knob rides on the
  ## left edge off, the right edge on. Returns the state to store back.
  let over = pointerOver(id)
  let clicked = over and pressedNow()

  openElement(id)
  configureOpenElement(row(gap = 10, width = fit(), height = fit(),
      alignY = centerY, padding = padAll(4)))

  openElement()
  configureOpenElement(row(width = fixedPx(44), height = fixedPx(24),
      alignX = if on: right else: left, padding = padAll(3))
    .bg(if on: accent else: fieldBg)
    .corner(12)
    .border(1, if over: accent else: panelBorder))
  openElement()
  configureOpenElement(col(width = fixedPx(16), height = fixedPx(16))
      .bg(textColor).corner(8))
  closeElement()
  closeElement()

  textElement(label, TextConfig(fontSize: 18, color: textColor))
  closeElement()

  result = if clicked: not on else: on
