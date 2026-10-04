## A single-choice dropdown. The field shows the selection; clicking opens
## a floating option list attached to it, dismissed by a click anywhere
## else. All of that scaffolding -- the open-dropdown slot, the summary
## field, the floating clipped panel, the option-row chrome -- is shared
## with `multiSelect` through `common` (`toggleDropdown`, `dropdownField`,
## `dropdownPanel`, `optionRow`), so opening either dropdown closes the
## other.

import clay
import ../ui

import ./common
import ./scrollbars

proc comboBox*(id: ElementId, options: seq[string], selected: int,
               placeholder = "", width = grow(),
               height = fixedPx(activeTheme.metrics.controlHeight)): int =
  ## Returns the selection index to store back -- the clicked row, or
  ## `selected` unchanged. -1 shows `placeholder`.
  result = selected
  let t = activeTheme
  let popId = localId("combo.pop", id.id)
  let isOpen = toggleDropdown(id, popId)

  var shown = placeholder
  var shownColor = t.palette.dimColor
  if selected >= 0 and selected < options.len:
    shown = options[selected]
    shownColor = t.palette.textColor
  dropdownField(id, isOpen, shown, shownColor, width, height)

  if isOpen:
    dropdownPanel(popId, id, t.metrics.listMaxHeight):
      var i = 0
      while i < options.len:
        optionRow(localIdWithIndex("combo.opt", uint32(i), id.id),
            i == result):
          textElement(options[i], TextConfig(fontSize: t.text.control,
            color: t.palette.textColor))
          if pressedNow() and hovered():
            result = i
            closeDropdown()
        inc i
      scrollbar(popId, popId)
