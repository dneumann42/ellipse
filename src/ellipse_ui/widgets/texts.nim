## Reading matter: the body-text scale that pairs with the headings, plus a
## few small named styles so screens share one voice. See
## `documentation/nim-tutorial.md` §6.7 (Headings and reading text) and
## `documentation/reference-widgets.md` §2.

import clay
import ../ui

import ./common

proc label*(text: string) =
  ## Small field/section label, like a `<label>`.
  let t = activeTheme
  textLine(text, TextConfig(fontSize: t.text.label, color: t.palette.labelColor),
    width = fit())

proc bodyText*(text: string, fontSize: uint16 = activeTheme.text.control,
               color = textColor) =
  ## A reading paragraph: grows to the container width and word-wraps.
  textLine(text, TextConfig(fontSize: fontSize, color: color))

proc caption*(text: string) =
  ## De-emphasised helper text under a control.
  let t = activeTheme
  textLine(text, TextConfig(fontSize: t.text.caption, color: t.palette.dimColor))

proc overline*(text: string) =
  ## A short accent-coloured kicker above a heading or panel title.
  let t = activeTheme
  textLine(text, TextConfig(fontSize: t.text.overline, color: t.palette.accent))

proc badge*(text: string) =
  ## A pill of status text; sits inline in toolbars and rows.
  let t = activeTheme
  container(row(width = fit(), height = fit(),
      padding = Padding(left: 8, right: 8, top: 2, bottom: 2),
      alignX = centerX, alignY = centerY)
    .bg(t.palette.accent)
    .corner(t.radii.pill)):
    textElement(text, TextConfig(fontSize: t.text.badge, color: t.palette.onAccent))

widget focusable textLink(text: string) -> bool:
  ## Accent text that lights up and underlines on hover, sinks onto a dim
  ## fill while a press is held; true -- and a `Pressed` event -- on click,
  ## or on Enter/Space while it holds focus (a Tab stop at `tabIndex`).
  emits Pressed
  let t = activeTheme
  let over = pointerOver(id)
  let press = pressing(id)
  var d = row(width = fit(), height = fit())
  d.corner = allCorners(4)
  if press:
    d.background = t.palette.buttonPressBg
  if over or press:
    d.border = BorderConfig(color: t.palette.accent,
      width: BorderWidth(bottom: t.metrics.borderHairline))
  item(id, d.focusRing(id)):
    textElement(text, TextConfig(fontSize: t.text.control, color: t.palette.accent))
  result = clickedIn(id) or keyActivated(id)
  if result:
    emit Pressed(id: id)

widget Prose(body: proc(): void):
  ## A column sized for reading: full-width flow with comfortable gaps,
  ## holding `bodyText`/`caption`/heading calls.
  container(col(width = grow(), gap = activeTheme.metrics.gapProse)):
    body()
