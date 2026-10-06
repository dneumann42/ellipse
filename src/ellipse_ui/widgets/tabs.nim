## The tabbed view container: a strip of tab buttons over one content
## panel that swaps pages with the selection.
##
## Which tab is active is *view* state, not screen data, so -- like an
## open dropdown -- it lives in this module keyed by the view's element
## id. `TabbedView` renders the strip, folds the click into its table,
## then calls the body slot inside the panel; the body asks `activeTab`
## which page to draw, so a click takes effect in the very frame it
## happens:
##
##   let settingsId = hashId("settings")
##   TabbedView(id = settingsId, tabs = @["General", "Audio"]):
##     case activeTab(settingsId)
##     of 0: generalPane()
##     else: audioPane()
##
## `setActiveTab` moves the selection from anywhere (tab counts shifting
## between frames are clamped by the view). For callers who own the
## selection themselves, `tabStrip` is the standalone checkbox-style
## piece: `tab = tabStrip(id, labels, tab)`.
##
## The strip is one Tab stop (`tabStripId(id)`); while it holds focus
## Left/Right step the selection (wrapping) and Home/End jump to the ends.
##
## A selection change emits `Picked` with the view's `id` and the new tab.

import std/tables

import clay
import ../ui

import ellipse/platform/platform

import ./common

var tabState = initTable[uint32, int]()

proc activeTab*(id: ElementId): int =
  ## `id`'s selected tab index; 0 until something selects otherwise.
  tabState.getOrDefault(id.id, 0)

proc setActiveTab*(id: ElementId, index: int) =
  ## Move `id`'s selection; the view picks it up on the next frame.
  tabState[id.id] = max(index, 0)

proc tabButtonDecl*(th: Theme, over: bool, selected: bool,
                    press = false): ElementDeclaration =
  ## One tab's shape: fit content, top corners only, the panel fill plus
  ## accent underline when selected, the plain button fill on hover, and
  ## the compressed fill with content shifted down while a press is held.
  var d = col(width = fit(), height = fit(), alignX = centerX,
      padding = squeeze(Padding(left: th.metrics.padTabX,
                        right: th.metrics.padTabX,
                        top: th.metrics.padTabTop,
                        bottom: th.metrics.padTabBottom), press))
  d.corner = CornerRadius(topLeft: th.radii.tab, topRight: th.radii.tab,
                          bottomLeft: 0, bottomRight: 0)
  if selected:
    d.background = th.palette.panelBg
    d.border = BorderConfig(color: th.palette.accent,
      width: BorderWidth(bottom: th.metrics.borderTab))
  elif press:
    d.background = th.palette.buttonPressBg
  elif over:
    d.background = th.palette.buttonBg
  result = d

proc tabStripId*(id: ElementId): ElementId =
  ## The focusable strip element of `id`'s tabs.
  localId("tabs.strip", id.id)

widget tabStrip(id: ElementId, labels: seq[string], selected: int,
               tabIndex = 0) -> int:
  ## Draw a tab strip as a child of `id`'s element and return the index
  ## of a tab clicked (or arrow-stepped) this frame, else `selected`. The
  ## strip and its buttons take ids local to `id`, so several strips can
  ## share a screen.
  emits Picked
  result = selected
  let th = activeTheme
  let stripId = tabStripId(id)
  registerFocus(stripId, tabIndex)
  if focused(stripId) and labels.len > 0:
    let evs = keyEvents()
    for ev in evs:
      case ev.kind
      of kevLeft: result = (result - 1 + labels.len) mod labels.len
      of kevRight: result = (result + 1) mod labels.len
      of kevHome: result = 0
      of kevEnd: result = labels.len - 1
      else: discard
  var d = row(width = grow(), height = fit(), gap = th.metrics.padToolbar,
      padding = Padding(left: th.metrics.padToolbar, right: th.metrics.padToolbar,
                        top: th.metrics.padToolbar, bottom: 0))
  d.border = BorderConfig(color: th.palette.panelBorder,
    width: BorderWidth(bottom: th.metrics.borderHairline))
  openElement(stripId)
  configureOpenElement(d)
  var i = 0
  while i < labels.len:
    let tabId = localIdWithIndex("tabs.tab", uint32(i), id.id)
    let over = pointerOver(tabId)
    let press = pressing(tabId)
    let clicked = clickedIn(tabId)
    var decl = tabButtonDecl(th, over, i == result, press)
    if i == result:
      decl = decl.focusRing(stripId)    # the ring marks the selected tab
    item(tabId, decl):
      textElement(labels[i], TextConfig(fontSize: th.text.option,
        color: if i == result or over: th.palette.textColor
               else: th.palette.dimColor))
    if clicked:
      result = i
    inc i
  closeElement()
  if result != selected:
    emit Picked(id: id, index: result)

widget TabbedView(id: ElementId, tabs: seq[string], body: proc(): void):
  ## The full container: tab strip plus the page panel `body` renders
  ## into. `body` runs after the selection has been updated, so
  ## `activeTab(id)` inside it names the page to draw. The panel grows
  ## to fill the view and clips nothing -- pages scroll themselves.
  openElement(id)
  configureOpenElement(col(width = grow(), height = grow(), gap = 0))
  var sel = activeTab(id)
  if tabs.len > 0 and (sel < 0 or sel >= tabs.len):
    sel = 0
    setActiveTab(id, sel)
  let picked = tabStrip(id, tabs, sel)
  if picked != sel:
    setActiveTab(id, picked)
  item(localId("tabs.panel", id.id), col(width = grow(), height = grow(),
      gap = 8, padding = padAll(activeTheme.metrics.padPanel))
    .bg(panelBg)
    .border(activeTheme.metrics.borderHairline, panelBorder)
    .corner(0, activeTheme.radii.tabPanel, activeTheme.radii.tabPanel,
            activeTheme.radii.tabPanel)):
    body()
  closeElement()
