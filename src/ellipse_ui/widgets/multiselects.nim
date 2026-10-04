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
                  height = fixedPx(activeTheme.metrics.controlHeight)): Selection =
  ## Returns the selection mask to store back. The popover stays open while
  ## the user ticks items; a click outside it closes.
  result = selection
  let t = activeTheme
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
      padding = padAll(t.metrics.padButton), alignY = centerY)
    .bg(shade(pointerOver(id) or isOpen))
    .corner(t.radii.field)
    .border(t.metrics.borderHairline,
      if isOpen: t.palette.accent else: t.palette.panelBorder))
  let summary = selectionSummary(result, options)
  var shown = placeholder
  var shownColor = t.palette.dimColor
  if summary.len > 0:
    shown = summary
    shownColor = t.palette.textColor
  textElement(shown, TextConfig(fontSize: t.text.control, color: shownColor,
    wrap: noWrap))
  openElement()
  configureOpenElement(row(width = grow(), height = fit()))
  closeElement()
  textElement(if isOpen: "^" else: "v",
    TextConfig(fontSize: t.text.chevron, color: t.palette.dimColor))
  closeElement()

  if isOpen:
    openElement(popId)
    configureOpenElement(col(gap = t.metrics.gapList,
        padding = padAll(t.metrics.padList),
        width = pct(1.0), height = fit(max = t.metrics.multiListMaxHeight))
      .bg(t.palette.panelBg)
      .border(t.metrics.borderHairline, t.palette.panelBorder)
      .corner(t.radii.popover)
      .floating(attachElementId,
        offset = vec2(0.0, t.metrics.popoverOffset), zIndex = 200,
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
          padding = padAll(t.metrics.padOption), alignY = centerY)
      d.corner = allCorners(t.radii.inner)
      if hovered():
        d.background = t.palette.buttonHoverBg
      configureOpenElement(d)
      openElement()
      configureOpenElement(col(width = fixedPx(t.metrics.checkSizeSm),
          height = fixedPx(t.metrics.checkSizeSm),
          alignX = centerX, alignY = centerY)
        .bg(t.palette.fieldBg)
        .corner(t.radii.check)
        .border(t.metrics.borderHairline,
          if isSet(result, i): t.palette.accent else: t.palette.panelBorder))
      if isSet(result, i):
        openElement()
        configureOpenElement(col(width = fixedPx(t.metrics.tickSizeSm),
            height = fixedPx(t.metrics.tickSizeSm))
            .bg(t.palette.accent).corner(t.radii.tick))
        closeElement()
      closeElement()
      textElement(options[i], TextConfig(fontSize: t.text.option,
        color: t.palette.textColor))
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
          padding = padAll(t.metrics.padMinor), alignX = centerX)
        .bg(shade(pointerOver(btnId)))
        .corner(t.radii.inner))
      textElement(if pair == 0: "All" else: "None",
        TextConfig(fontSize: t.text.label, color: t.palette.textColor))
      closeElement()
    closeElement()

    scrollbar(popId, popId)
    closeElement()   # pop
