## A single-choice dropdown. The field shows the selection; clicking opens
## a floating option list attached to it, dismissed by a click anywhere
## else -- the same press bookkeeping `ui.menu` does, with per-widget ids
## so several combos can share the screen.

import clay
import ../ui

import ./common
import ./scrollbars

var openComboId = 0'u32

proc comboBox*(id: ElementId, options: seq[string], selected: int,
               placeholder = "", width = grow(),
               height = fixedPx(activeTheme.metrics.controlHeight)): int =
  ## Returns the selection index to store back -- the clicked row, or
  ## `selected` unchanged. -1 shows `placeholder`.
  result = selected
  let t = activeTheme
  let began = pressedNow()
  let popId = localId("combo.pop", id.id)

  if began:
    if pointerOver(id):
      openComboId = if openComboId == id.id: 0'u32 else: id.id
    elif openComboId == id.id and not pointerOver(popId):
      openComboId = 0'u32
  let isOpen = openComboId == id.id

  openElement(id)
  configureOpenElement(row(width = width, height = height, gap = 8,
      padding = padAll(t.metrics.padButton), alignY = centerY)
    .bg(shade(pointerOver(id) or isOpen))
    .corner(t.radii.field)
    .border(t.metrics.borderHairline,
      if isOpen: t.palette.accent else: t.palette.panelBorder))
  var shown = placeholder
  var shownColor = t.palette.dimColor
  if selected >= 0 and selected < options.len:
    shown = options[selected]
    shownColor = t.palette.textColor
  textElement(shown, TextConfig(fontSize: t.text.control, color: shownColor,
    wrap: noWrap))
  # spacer pushing the chevron to the right edge
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
        width = pct(1.0), height = fit(max = t.metrics.listMaxHeight))
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
      openElement(localIdWithIndex("combo.opt", uint32(i), id.id))
      let picked = began and hovered()
      var d = row(width = grow(), height = fit(),
          padding = padAll(t.metrics.padOption))
      d.corner = allCorners(t.radii.inner)
      if i == result:
        d.background = t.palette.selectedBg
      elif hovered():
        d.background = t.palette.buttonHoverBg
      configureOpenElement(d)
      textElement(options[i], TextConfig(fontSize: t.text.control,
        color: t.palette.textColor))
      closeElement()
      if picked:
        result = i
        openComboId = 0'u32
      inc i
    scrollbar(popId, popId)
    closeElement()
