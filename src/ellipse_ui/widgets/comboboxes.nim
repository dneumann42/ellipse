## A single-choice dropdown. The field shows the selection; clicking opens
## a floating option list attached to it, dismissed by a click anywhere
## else -- the same press bookkeeping `ui.menu` does, with per-widget ids
## so several combos can share the screen.

import clay
import ../ui

import ./common

var openComboId = 0'u32

proc comboBox*(id: ElementId, options: seq[string], selected: int,
               placeholder = "", width = grow(), height = fixedPx(40)): int =
  ## Returns the selection index to store back -- the clicked row, or
  ## `selected` unchanged. -1 shows `placeholder`.
  result = selected
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
      padding = padAll(8), alignY = centerY)
    .bg(shade(pointerOver(id) or isOpen))
    .corner(8)
    .border(1, if isOpen: accent else: panelBorder))
  var shown = placeholder
  var shownColor = dimColor
  if selected >= 0 and selected < options.len:
    shown = options[selected]
    shownColor = textColor
  textElement(shown, TextConfig(fontSize: 18, color: shownColor,
    wrap: noWrap))
  # spacer pushing the chevron to the right edge
  openElement()
  configureOpenElement(row(width = grow(), height = fit()))
  closeElement()
  textElement(if isOpen: "^" else: "v",
    TextConfig(fontSize: 16, color: dimColor))
  closeElement()

  if isOpen:
    openElement(popId)
    configureOpenElement(col(gap = 2, padding = padAll(4),
        width = pct(1.0), height = fit(max = 240))
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
      openElement(localIdWithIndex("combo.opt", uint32(i), id.id))
      let picked = began and hovered()
      var d = row(width = grow(), height = fit(), padding = padAll(6))
      d.corner = allCorners(6)
      if i == result:
        d.background = selectedBg
      elif hovered():
        d.background = buttonHoverBg
      configureOpenElement(d)
      textElement(options[i], TextConfig(fontSize: 18, color: textColor))
      closeElement()
      if picked:
        result = i
        openComboId = 0'u32
      inc i
    closeElement()
