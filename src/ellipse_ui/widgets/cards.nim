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
  configureOpenElement(col(width = grow(), height = fit(), gap = 10,
      padding = padAll(14))
    .bg(panelBg)
    .border(1, panelBorder)
    .corner(12))
  if title.len > 0:
    openElement()
    configureOpenElement(row(width = grow(), height = fit(), gap = 8,
        alignY = centerY))
    textElement(title, TextConfig(fontSize: 19, color: textColor))
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
  configureOpenElement(col(width = grow(), height = fit(), gap = 2,
      padding = padAll(12), alignX = centerX)
    .bg(panelBg)
    .border(1, panelBorder)
    .corner(12))
  textElement(label, TextConfig(fontSize: 14, color: dimColor))
  textElement(value, TextConfig(fontSize: 26, color: textColor))
  if hint.len > 0:
    textElement(hint, TextConfig(fontSize: 13, color: labelColor))
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
  configureOpenElement(row(width = grow(), height = fit(), gap = 12))
  body()
  closeElement()
