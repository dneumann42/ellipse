## A type scale: six heading levels plus a `Section` widget that wraps a
## heading and its content. Levels differ in size, colour, spacing and --
## for the top two -- a bottom rule, all on one proc so the look stays
## consistent across screens.

import clay
import ../ui

import ./common

proc headingFontSize*(level: int): uint16 =
  case level
  of 1: return 42.uint16
  of 2: return 32.uint16
  of 3: return 26.uint16
  of 4: return 21.uint16
  of 5: return 18.uint16
  else: return 16.uint16

proc headingTopPad(level: int): int =
  case level
  of 1: return 28
  of 2: return 20
  of 3: return 14
  else: return 10

proc heading*(text: string, level: int = 1) =
  ## One heading line. Elements use clay's auto ids, so any number of
  ## headings can repeat inside one parent without id collisions.
  openElement()
  var d = row(width = grow(), height = fit(),
      padding = Padding(left: 0, right: 0,
                        top: headingTopPad(level), bottom: 6))
  if level <= 2:
    d.border = BorderConfig(color: panelBorder, width: BorderWidth(bottom: 1))
  configureOpenElement(d)
  let fg = if level <= 4: textColor else: dimColor
  textElement(text, TextConfig(fontSize: headingFontSize(level), color: fg))
  closeElement()

proc h1*(text: string) =
  heading(text, 1)

proc h2*(text: string) =
  heading(text, 2)

proc h3*(text: string) =
  heading(text, 3)

proc h4*(text: string) =
  heading(text, 4)

proc h5*(text: string) =
  heading(text, 5)

proc h6*(text: string) =
  heading(text, 6)

widget Section(title: string, body: proc(): void):
  ## A heading-2 followed by its content, spaced as one block:
  ##
  ##   Section(title = "Audio"):
  ##     volume = textField(hashId("vol"), volume)
  openElement()
  configureOpenElement(col(width = grow(), gap = 10))
  heading(title, 2)
  openElement()
  configureOpenElement(col(width = grow(), gap = 6))
  body()
  closeElement()
  closeElement()
