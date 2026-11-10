## A type scale: six heading levels plus a `Section` widget that wraps a
## heading and its content. See `documentation/nim-tutorial.md` §6.7
## (Headings and reading text).
{.push gcsafe.}


import clay
import ../ui

import ./common

proc headingFontSize*(level: int): uint16 =
  let t = activeTheme.text
  case level
  of 1: return t.h1
  of 2: return t.h2
  of 3: return t.h3
  of 4: return t.h4
  of 5: return t.h5
  else: return t.h6

proc headingTopPad(level: int): int =
  let m = activeTheme.metrics
  case level
  of 1: return m.headingPadH1
  of 2: return m.headingPadH2
  of 3: return m.headingPadH3
  else: return m.headingPadMinor

proc heading*(text: string, level: int = 1) =
  ## One heading line. Elements use clay's auto ids, so any number of
  ## headings can repeat inside one parent without id collisions.
  let t = activeTheme
  var d = row(width = grow(), height = fit(),
      padding = Padding(left: 0, right: 0,
                        top: headingTopPad(level),
                        bottom: t.metrics.headingPadBottom))
  if level <= 2:
    d.border = BorderConfig(color: t.palette.panelBorder,
      width: BorderWidth(bottom: t.metrics.borderHairline))
  container(d):
    let fg = if level <= 4: t.palette.textColor else: t.palette.dimColor
    textElement(text, TextConfig(fontSize: headingFontSize(level), color: fg))

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
  container(col(width = grow(), gap = activeTheme.metrics.gapCard)):
    heading(title, 2)
    container(col(width = grow(), gap = activeTheme.metrics.gapTight)):
      body()
