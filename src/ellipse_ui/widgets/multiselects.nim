## A multi-choice dropdown: the field summarises the set, the popover holds
## checkbox rows plus an All/None footer. The selection is a caller-owned
## bitmask -- `bit(i)` is option `i`'s flag -- so one value travels through
## the immediate-mode round trip without allocating.
##
## The dropdown scaffolding (open-dropdown slot, summary field, floating
## panel, option rows, shaded footer buttons) comes from `common`, shared
## with `comboBox`; only the tick rows and their bitmask bookkeeping are
## this widget's own.
##
## Keyboard: a Tab stop at `tabIndex`; Enter toggles the list, Space opens
## it, Escape closes it. In the open list Up/Down move a highlight and
## Space ticks the highlighted option.

import clay
import ../ui

import ellipse/platform/platform

import ./common
import ./scrollbars

type Selection* = uint64

var
  cursorId = 0'u32   ## the multiselect whose list the highlight belongs to
  cursor = -1        ## keyboard-highlighted option, -1 none

func bit*(i: int): Selection =
  ## The mask for option `i`.
  1'u64 shl uint32(i)

func isSet*(sel: Selection, i: int): bool =
  ((sel shr uint32(i)) and 1'u64) == 1'u64

func allSelected*(n: int): Selection =
  ## A mask with the first `n` bits set (`n` up to 64).
  if n <= 0:
    return 0'u64
  if n >= 64:
    return not 0'u64
  result = (1'u64 shl uint32(n)) - 1'u64

func countSelected*(sel: Selection): int =
  result = 0
  var b = sel
  while b != 0'u64:
    if (b and 1'u64) == 1'u64:
      inc result
    b = b shr 1

func selectionSummary*(sel: Selection, options: seq[string]): string =
  ## Up to two names joined, else `"<n> selected"`, else nothing selected.
  let n = countSelected(sel)
  if n == 0:
    return ""
  if n > 2:
    return $n & " selected"
  result = ""
  var i = 0
  while i < options.len:
    if isSet(sel, i):
      if result.len > 0:
        result.add ", "
      result.add options[i]
    inc i

proc multiSelect*(id: ElementId, options: seq[string], selection: Selection,
                  placeholder = "Select...", width = grow(),
                  height = fixedPx(activeTheme.metrics.controlHeight),
                  tabIndex: int = 0): Selection =
  ## Returns the selection mask to store back. The popover stays open while
  ## the user ticks items; a click outside it closes.
  result = selection
  let t = activeTheme
  let popId = localId("multi.pop", id.id)
  let wasOpen = dropdownIsOpen(id)
  let isOpen = dropdownFocus(id, popId, tabIndex)
  if isOpen and not wasOpen:
    cursorId = id.id
    cursor = if focused(id): 0 else: -1
  if isOpen and wasOpen and focused(id) and cursorId == id.id and
      options.len > 0:
    # keys the open list owns (the opening key itself belongs to the field)
    let evs = keyEvents()
    for ev in evs:
      if ev.kind == kevDown:
        cursor = (cursor + 1) mod options.len
      elif ev.kind == kevUp:
        cursor = if cursor <= 0: options.len - 1 else: cursor - 1
      elif isSpace(ev) and cursor >= 0 and cursor < options.len:
        result = result xor bit(cursor)

  let summary = selectionSummary(result, options)
  var shown = placeholder
  var shownColor = t.palette.dimColor
  if summary.len > 0:
    shown = summary
    shownColor = t.palette.textColor
  dropdownField(id, isOpen, shown, shownColor, width, height)

  if isOpen:
    dropdownPanel(popId, id, t.metrics.multiListMaxHeight):
      var i = 0
      while i < options.len:
        let oid = localIdWithIndex("multi.opt", uint32(i), id.id)
        optionRow(oid, cursorId == id.id and i == cursor, 8, centerY):
          let picked = pressedNow() and hovered()
          # tick already flipped when this is the frame the row was hit
          tickBox(isSet(result, i) != picked, box = t.metrics.checkSizeSm,
                  tick = t.metrics.tickSizeSm)
          textElement(options[i], TextConfig(fontSize: t.text.option,
            color: t.palette.textColor))
          if picked:
            result = result xor bit(i)
        inc i

      # All / None footer
      openElement()
      configureOpenElement(row(width = grow(), height = fit(), gap = 6,
          padding = Padding(left: 4, right: 4, top: 6, bottom: 2)))
      for pair in 0 ..< 2:
        let btnId = localId(if pair == 0: "multi.all" else: "multi.none",
          id.id)
        let picked = clickedIn(btnId)
        item(btnId, shadeDecl(btnId, grow(), fit(),
            padding = padAll(t.metrics.padMinor), alignX = centerX)):
          textElement(if pair == 0: "All" else: "None",
            TextConfig(fontSize: t.text.label, color: t.palette.textColor))
        if picked:
          result = if pair == 0: allSelected(options.len) else: 0'u64
      closeElement()

      scrollbar(popId, popId)
