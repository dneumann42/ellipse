## A single-choice dropdown. See `documentation/nim-tutorial.md` §6.3
## (Single-choice dropdown).
{.push gcsafe.}


import clay
import ../ui

import ellipse/platform/platform

import ./common
import ./scrollbars

widget comboBox(id: ElementId, options: seq[string], selected: int,
               placeholder = "", width = grow(),
               height = fixedPx(activeTheme.metrics.controlHeight),
               tabIndex = 0) -> int:
  ## Returns the selection index to store back -- the clicked row, the
  ## arrow-stepped one, or `selected` unchanged. -1 shows `placeholder`.
  emits Picked
  result = selected
  let t = activeTheme
  let popId = localId("combo.pop", id.id)
  let isOpen = dropdownFocus(id, popId, tabIndex)
  if focused(id) and options.len > 0:
    let evs = keyEvents()
    for ev in evs:
      if ev.kind == kevDown:
        result = min(max(result, -1) + 1, options.len - 1)
      elif ev.kind == kevUp:
        result = max(result - 1, 0)

  var shown = placeholder
  var shownColor = t.palette.dimColor
  if result >= 0 and result < options.len:
    shown = options[result]
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
  if result != selected:
    emit Picked(id: id, index: result)
