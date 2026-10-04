## Checkboxes: `checkbox` toggles a caller-owned bool.
##
## The tick box itself is a filled inner square rather than a glyph -- the
## renderer only promises rectangles and the UI font, so no `✓` to tofu out.
## All geometry and colour comes from the live theme (see `ellipse_ui/theme`).

import clay
import ../ui

import ./common

proc checkbox*(id: ElementId, label: string, checked: bool,
               fontSize: uint16 = activeTheme.text.control): bool =
  ## A labelled tick box. Returns the state to store back: `checked` flipped
  ## when the user clicked it this frame.
  let t = activeTheme
  let over = pointerOver(id)
  let clicked = over and pressedNow()

  openElement(id)
  configureOpenElement(row(gap = 10, width = fit(), height = fit(),
      alignY = centerY, padding = padAll(t.metrics.padCheckRow))
    .bg(if over: t.palette.buttonBg else: Color())
    .corner(t.radii.button))

  openElement()
  configureOpenElement(col(width = fixedPx(t.metrics.checkSize),
      height = fixedPx(t.metrics.checkSize),
      alignX = centerX, alignY = centerY)
    .bg(t.palette.fieldBg)
    .corner(t.radii.check)
    .border(t.metrics.borderHairline,
      if checked: t.palette.accent else: t.palette.panelBorder))
  if checked:
    openElement()
    configureOpenElement(col(width = fixedPx(t.metrics.tickSize),
        height = fixedPx(t.metrics.tickSize))
        .bg(t.palette.accent).corner(t.radii.tick))
    closeElement()
  closeElement()

  textElement(label, TextConfig(fontSize: fontSize, color: t.palette.textColor))
  closeElement()

  result = if clicked: not checked else: checked

proc switch*(id: ElementId, label: string, on: bool): bool =
  ## The same control dressed as an on/off slider: the knob rides on the
  ## left edge off, the right edge on. Returns the state to store back.
  let t = activeTheme
  let over = pointerOver(id)
  let clicked = over and pressedNow()

  openElement(id)
  configureOpenElement(row(gap = 10, width = fit(), height = fit(),
      alignY = centerY, padding = padAll(t.metrics.padCheckRow)))

  openElement()
  configureOpenElement(row(width = fixedPx(t.metrics.switchWidth),
      height = fixedPx(t.metrics.switchHeight),
      alignX = if on: right else: left, padding = padAll(t.metrics.padSwitch))
    .bg(if on: t.palette.accent else: t.palette.fieldBg)
    .corner(t.radii.switch)
    .border(t.metrics.borderHairline,
      if over: t.palette.accent else: t.palette.panelBorder))
  openElement()
  configureOpenElement(col(width = fixedPx(t.metrics.switchKnob),
      height = fixedPx(t.metrics.switchKnob))
      .bg(t.palette.textColor).corner(t.radii.switchKnob))
  closeElement()
  closeElement()

  textElement(label, TextConfig(fontSize: t.text.control,
    color: t.palette.textColor))
  closeElement()

  result = if clicked: not on else: on
