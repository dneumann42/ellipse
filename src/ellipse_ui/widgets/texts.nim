## Reading matter: the body-text scale that pairs with the headings, plus a
## few small named styles so screens share one voice. Everything here is a
## static (non-interactive) presentation of `textElement` except `textLink`,
## which borrows the checkbox's click detection. Sizes and colours follow
## the live theme (see `ellipse_ui/theme`).
##
## Text elements wrap at their container's width: give the paragraph room
## (a `grow`-width parent, e.g. `Prose`) and long lines break on
## whitespace.

import clay
import ../ui

import ./common

proc label*(text: string) =
  ## Small field/section label, like a `<label>`.
  let t = activeTheme
  openElement()
  configureOpenElement(row(width = fit(), height = fit()))
  textElement(text, TextConfig(fontSize: t.text.label, color: t.palette.labelColor))
  closeElement()

proc bodyText*(text: string, fontSize: uint16 = activeTheme.text.control,
               color = textColor) =
  ## A reading paragraph: grows to the container width and word-wraps.
  openElement()
  configureOpenElement(row(width = grow(), height = fit()))
  textElement(text, TextConfig(fontSize: fontSize, color: color))
  closeElement()

proc caption*(text: string) =
  ## De-emphasised helper text under a control.
  let t = activeTheme
  openElement()
  configureOpenElement(row(width = grow(), height = fit()))
  textElement(text, TextConfig(fontSize: t.text.caption, color: t.palette.dimColor))
  closeElement()

proc overline*(text: string) =
  ## A short accent-coloured kicker above a heading or panel title.
  let t = activeTheme
  openElement()
  configureOpenElement(row(width = grow(), height = fit()))
  textElement(text, TextConfig(fontSize: t.text.overline, color: t.palette.accent))
  closeElement()

proc badge*(text: string) =
  ## A pill of status text; sits inline in toolbars and rows.
  let t = activeTheme
  openElement()
  configureOpenElement(row(width = fit(), height = fit(),
      padding = Padding(left: 8, right: 8, top: 2, bottom: 2),
      alignX = centerX, alignY = centerY)
    .bg(t.palette.accent)
    .corner(t.radii.pill))
  textElement(text, TextConfig(fontSize: t.text.badge, color: t.palette.onAccent))
  closeElement()

proc textLink*(id: ElementId, text: string): bool =
  ## Accent text that lights up and underlines on hover; true on click.
  let t = activeTheme
  let over = pointerOver(id)
  let clicked = over and pressedNow()
  openElement(id)
  var d = row(width = fit(), height = fit())
  d.corner = allCorners(4)
  if over:
    d.border = BorderConfig(color: t.palette.accent,
      width: BorderWidth(bottom: t.metrics.borderHairline))
  configureOpenElement(d)
  textElement(text, TextConfig(fontSize: t.text.control, color: t.palette.accent))
  closeElement()
  result = clicked

widget Prose(body: proc(): void):
  ## A column sized for reading: full-width flow with comfortable gaps,
  ## holding `bodyText`/`caption`/heading calls.
  openElement()
  configureOpenElement(col(width = grow(), gap = activeTheme.metrics.gapProse))
  body()
  closeElement()
