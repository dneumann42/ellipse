## Card containers: the framed surface panes of content sit on. All three
## are `widget` definitions -- `Card` is the general container with an
## optional header, `StatCard` a compact metric tile, `CardRow` the row
## that spreads sibling cards evenly.
##
## Cards take no id and use clay's auto ids, so any number repeat inside
## one parent; interactive content inside them carries its own ids.

import clay
import ../ui

import ./common

widget Card(title: string, actions: proc(): void, body: proc(): void):
  ## A padded panel -- background, border, rounded corners -- holding
  ## `body`, with an optional header row:
  ##
  ##   Card(title = "Network", actions = renderRefresh):
  ##     bodyText("Linked at 1 Gb/s")
  ##
  ## An empty `title` drops the header; `actions` renders at the
  ## header's right edge (it needs the title to be shown). The trailing
  ## block fills the slot *after the last named argument*, so a call
  ## without actions must name the default explicitly:
  ## `Card(title = "Status", actions = emptySlot): ...`. The card hugs
  ## its content vertically and grows to its container's width.
  openElement()
  let t = activeTheme
  configureOpenElement(col(width = grow(), height = fit(), gap = t.metrics.gapCard,
      padding = padAll(t.metrics.padCard))
    .bg(t.palette.panelBg)
    .border(t.metrics.borderHairline, t.palette.panelBorder)
    .corner(t.radii.card))
  if title.len > 0:
    openElement()
    configureOpenElement(row(width = grow(), height = fit(), gap = 8,
        alignY = centerY))
    textElement(title, TextConfig(fontSize: t.text.cardTitle,
      color: t.palette.textColor))
    # spacer pushing the actions to the right edge
    openElement()
    configureOpenElement(row(width = grow(), height = fit()))
    closeElement()
    actions()
    closeElement()
  body()
  closeElement()

widget StatCard(label: string, value: string, hint: string):
  ## A centred metric tile: dim caption, large value, optional footnote
  ## (pass `""` to omit the hint). Grows to share its row's width --
  ## natural inside `CardRow`.
  openElement()
  let t = activeTheme
  configureOpenElement(col(width = grow(), height = fit(), gap = t.metrics.gapList,
      padding = padAll(t.metrics.padStat), alignX = centerX)
    .bg(t.palette.panelBg)
    .border(t.metrics.borderHairline, t.palette.panelBorder)
    .corner(t.radii.card))
  textElement(label, TextConfig(fontSize: t.text.statLabel, color: t.palette.dimColor))
  textElement(value, TextConfig(fontSize: t.text.statValue, color: t.palette.textColor))
  if hint.len > 0:
    textElement(hint, TextConfig(fontSize: t.text.statHint, color: t.palette.labelColor))
  closeElement()

widget CardRow(body: proc(): void):
  ## A row that spreads its cards evenly: children grow to equal widths
  ## with one gap between them, heights hugging the tallest.
  ##
  ##   CardRow:
  ##     StatCard(label = "Up", value = "4d", hint = "since boot")
  ##     StatCard(label = "Pings", value = "12", hint = "")
  ##
  ## `Card`s work here too, and nest the same way.
  openElement()
  configureOpenElement(row(width = grow(), height = fit(),
      gap = activeTheme.metrics.gapCardRow))
  body()
  closeElement()
