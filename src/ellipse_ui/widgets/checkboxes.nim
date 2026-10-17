## Checkboxes: `checkbox` toggles a caller-owned bool. See
## `documentation/nim-tutorial.md` §6.2 (Checkboxes and switches).

import clay
import ../ui

import ./common

widget focusable checkbox(label: string, checked: bool,
                          fontSize = activeTheme.text.control) -> bool:
  ## A labelled tick box. Returns the state to store back: `checked` flipped
  ## when the user clicked it (or pressed Space/Enter on it) this frame. A
  ## held press compresses the row.
  emits Toggled
  let t = activeTheme
  let over = pointerOver(id)
  let press = pressing(id)
  let clicked = clickedIn(id) or keyActivated(id)
  item(id, toggleRowDecl(over, press).focusRing(id)):
    tickBox(checked)
    textElement(label, TextConfig(fontSize: fontSize, color: t.palette.textColor))
  result = if clicked: not checked else: checked
  if clicked:
    emit Toggled(id: id, on: result)

widget focusable switch(label: string, on: bool) -> bool:
  ## The same control dressed as an on/off slider: the knob rides on the
  ## left edge off, the right edge on. Returns the state to store back.
  ## The track squeezes its knob down while a press is held.
  emits Toggled
  let t = activeTheme
  let over = pointerOver(id)
  let press = pressing(id)
  let clicked = clickedIn(id) or keyActivated(id)
  item(id, toggleRowDecl(over, press, showBg = false).focusRing(id)):
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
  if clicked:
    emit Toggled(id: id, on: result)
