## A multi-choice dropdown: the field summarises the set, the popover holds
## checkbox rows plus an All/None footer. The selection is a caller-owned
## bitmask -- `bit(i)` is option `i`'s flag -- so one value travels through
## the immediate-mode round trip without allocating.

import clay
import ../ui

import ./common
import ./scrollbars

type Selection* = uint64

var openMultiId = 0'u32

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
                  height = fixedPx(40)): Selection =
  ## Returns the selection mask to store back. The popover stays open while
  ## the user ticks items; a click outside it closes.
  result = selection
  let began = pressedNow()
  let popId = localId("multi.pop", id.id)

  if began:
    if pointerOver(id):
      openMultiId = if openMultiId == id.id: 0'u32 else: id.id
    elif openMultiId == id.id and not pointerOver(popId):
      openMultiId = 0'u32
  let isOpen = openMultiId == id.id

  openElement(id)
  configureOpenElement(row(width = width, height = height, gap = 8,
      padding = padAll(8), alignY = centerY)
    .bg(shade(pointerOver(id) or isOpen))
    .corner(8)
    .border(1, if isOpen: accent else: panelBorder))
  let summary = selectionSummary(result, options)
  var shown = placeholder
  var shownColor = dimColor
  if summary.len > 0:
    shown = summary
    shownColor = textColor
  textElement(shown, TextConfig(fontSize: 18, color: shownColor,
    wrap: noWrap))
  openElement()
  configureOpenElement(row(width = grow(), height = fit()))
  closeElement()
  textElement(if isOpen: "^" else: "v",
    TextConfig(fontSize: 16, color: dimColor))
  closeElement()

  if isOpen:
    openElement(popId)
    configureOpenElement(col(gap = 2, padding = padAll(4),
        width = pct(1.0), height = fit(max = 260))
      .bg(panelBg)
      .border(1, panelBorder)
      .corner(10)
      .floating(attachElementId,
        offset = vec2(0.0, 6.0), zIndex = 200,
        points = AttachPoints(element: pointLeftTop,
                              parent: pointLeftBottom),
        parentId = id.id)
      .clip(horizontal = false, vertical = true,
            childOffset = currentScrollOffset()))

    var i = 0
    while i < options.len:
      openElement(localIdWithIndex("multi.opt", uint32(i), id.id))
      let picked = began and hovered()
      if picked:
        result = result xor bit(i)
      var d = row(width = grow(), height = fit(), gap = 8,
          padding = padAll(6), alignY = centerY)
      d.corner = allCorners(6)
      if hovered():
        d.background = buttonHoverBg
      configureOpenElement(d)
      openElement()
      configureOpenElement(col(width = fixedPx(18), height = fixedPx(18),
          alignX = centerX, alignY = centerY)
        .bg(fieldBg)
        .corner(4)
        .border(1, if isSet(result, i): accent else: panelBorder))
      if isSet(result, i):
        openElement()
        configureOpenElement(col(width = fixedPx(9), height = fixedPx(9))
            .bg(accent).corner(2))
        closeElement()
      closeElement()
      textElement(options[i], TextConfig(fontSize: 17, color: textColor))
      closeElement()
      inc i

    # All / None footer
    let allId = localId("multi.all", id.id)
    let noneId = localId("multi.none", id.id)
    if began and pointerOver(allId):
      result = allSelected(options.len)
    if began and pointerOver(noneId):
      result = 0'u64
    openElement()
    configureOpenElement(row(width = grow(), height = fit(), gap = 6,
        padding = Padding(left: 4, right: 4, top: 6, bottom: 2)))
    for pair in 0 ..< 2:
      let btnId = if pair == 0: allId else: noneId
      openElement(btnId)
      configureOpenElement(row(width = grow(), height = fit(),
          padding = padAll(4), alignX = centerX)
        .bg(shade(pointerOver(btnId)))
        .corner(6))
      textElement(if pair == 0: "All" else: "None",
        TextConfig(fontSize: 15, color: textColor))
      closeElement()
    closeElement()

    scrollbar(popId, popId)
    closeElement()   # pop
