## Checkboxes: `checkbox` toggles a caller-owned bool.
##
## The tick box itself is a filled inner square rather than a glyph -- the
## renderer only promises rectangles and the UI font, so no `✓` to tofu out.
## That square is `common.tickBox`; both widgets here hang it in a
## `ui.item` over a `common.toggleRowDecl` frame. All geometry and colour
## comes from the live theme (see `ellipse_ui/theme`).

import clay
import ../ui

import ./common

proc checkbox*(id: ElementId, label: string, checked: bool,
               fontSize: uint16 = activeTheme.text.control): bool =
  ## A labelled tick box. Returns the state to store back: `checked` flipped
  ## when the user clicked it this frame. A held press compresses the row.
  let t = activeTheme
  let over = pointerOver(id)
  let press = pressing(id)
  let clicked = clickedIn(id)
  item(id, toggleRowDecl(over, press)):
    tickBox(checked)
    textElement(label, TextConfig(fontSize: fontSize, color: t.palette.textColor))
  result = if clicked: not checked else: checked

proc switch*(id: ElementId, label: string, on: bool): bool =
  ## The same control dressed as an on/off slider: the knob rides on the
  ## left edge off, the right edge on. Returns the state to store back.
  ## The track squeezes its knob down while a press is held.
  let t = activeTheme
  let over = pointerOver(id)
  let press = pressing(id)
  let clicked = clickedIn(id)
  item(id, toggleRowDecl(over, press, showBg = false)):
    openElement()
    configureOpenElement(row(width = fixedPx(t.metrics.switchWidth),
        height = fixedPx(t.metrics.switchHeight),
        alignX = if on: right else: left,
        padding = squeeze(padAll(t.metrics.padSwitch), press))
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
  result = if clicked: not on else: on
