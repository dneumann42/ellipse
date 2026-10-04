## Floating, draggable scrollbars for clay clip/scroll containers.
##
## The pattern follows the gothivania HUD's `clay::Scrollbar`
## (`src/hud/clay_dsl.hpp`): the bar is a pair of *floating* elements -- a
## translucent track plus a proportional thumb -- anchored over the right
## edge (or bottom edge) of the scroll container currently being declared.
## Geometry comes from the container's previous-frame layout, so a bar
## appears one frame after its container and hides whenever the content
## fits. The thumb is grabbable: press it and the container follows the
## pointer 1:1 through `setScrollPosition`; a press on the bare track
## jumps the thumb to the click.
##
## Immediate-mode contract: `scrollbar` is called *inside* the container's
## scope, after its children -- the same slot position gothivania uses:
##
##   clay "panel", col(...)
##       .clip(horizontal = false, vertical = true,
##             childOffset = currentScrollOffset()):
##     for long things...
##     scrollbar(hashId("panelbar"), hashId("panel"))
##
## `scrollPanel` wraps that whole container shape -- open, configure (the
## caller's decl), children, bar, close -- and names the bar `<panel>.bar`:
##
##   scrollPanel "panel", col(...)
##       .clip(horizontal = false, vertical = true,
##             childOffset = currentScrollOffset()):
##     for long things...
##
## Drag state lives here, keyed by container id -- like `menu`'s
## `openMenuId`, one frame's pointer decides the next frame's position.

import std/[math]

import clay
import ../ui

import ./common

## `ScrollbarStyle` and its default live in `ellipse_ui/theme` so a pushed
## theme can restyle every bar at once; callers may still pass an explicit
## style to `scrollbar`.

type
  BarAxis = enum vertical, horizontal

  Drag = object
    ## An in-progress thumb grab: the container keeps its thumb `grab`
    ## pixels above (or left of) the pointer along `axis`.
    container: uint32
    axis: BarAxis
    grab: float32

var drags: seq[Drag] = @[]

type
  BarGeom = object
    ## One axis' worth of scrollbar geometry, from last frame's data.
    scrollable: bool   ## axis overflows and is clipped: draw the bar
    dragging: bool     ## a thumb grab is live on this axis
    view: float32      ## container extent along the axis
    track: float32     ## usable length inside the margins
    thumb: float32     ## thumb length
    top: float32       ## thumb start, measured inside the track
    maxScroll: float32 ## content extent beyond the view

proc axisPosition(d: ScrollContainerData; axis: BarAxis): float32 =
  if axis == vertical: d.position.y else: d.position.x

proc barGeom(container: ElementId, axis: BarAxis,
             style: ScrollbarStyle): BarGeom =
  ## Last frame's geometry for one axis; `scrollable` false when the axis
  ## isn't clipped, the data isn't published yet, or the content fits.
  let d = scrollContainerData(container)
  if not d.found or (axis == vertical) != d.vertical or
      (axis == horizontal) != d.horizontal:
    return BarGeom(scrollable: false)
  let (view, content) = if axis == vertical:
    (d.containerDimensions.height, d.contentDimensions.height)
  else:
    (d.containerDimensions.width, d.contentDimensions.width)
  if content <= view + 1:
    return BarGeom(scrollable: false)
  let track = view - 2 * style.margin
  let maxScroll = content - view
  let thumb = clamp(view / content * view, min(style.minThumb, track), track)
  let scrolled = clamp(-axisPosition(d, axis), 0.0, maxScroll)
  let span = max(track - thumb, 0.0)
  result = BarGeom(
    scrollable: true,
    view: view, track: track, thumb: thumb, maxScroll: maxScroll,
    top: if span > 0: scrolled / maxScroll * span else: 0.0)
  for g in drags:
    if g.container == container.id and g.axis == axis:
      result.dragging = true
      break

proc pointerAlong(axis: BarAxis): float32 =
  let p = currentContext().pointerData().position
  if axis == vertical: p.y else: p.x

proc containerStart(container: ElementId, axis: BarAxis): float32 =
  let box = elementData(container).box
  if axis == vertical: box.y else: box.x

proc thumbToPointer(container: ElementId, axis: BarAxis, offset: float32,
                    geom: BarGeom, style: ScrollbarStyle) =
  ## Drive `container` so the thumb's track-relative start lands at
  ## `offset` (clamped to the run): the shared core of drag and page-jump.
  let span = geom.track - geom.thumb
  if span <= 0:
    return
  let top = clamp(offset, 0.0, span)
  let pos = -(top / span) * geom.maxScroll
  var p = Vec2()
  if axis == vertical: p.y = pos else: p.x = pos
  setScrollPosition(container, p)

proc advanceDrag(g: var Drag; style: ScrollbarStyle) =
  ## Keep a held thumb pinned under the pointer (minus the grab offset).
  let container = elementIdFromId(g.container)
  let geom = barGeom(container, g.axis, style)
  if not geom.scrollable:
    return
  let local = pointerAlong(g.axis) -
    containerStart(container, g.axis) - style.margin - g.grab
  thumbToPointer(container, g.axis, local, geom, style)

proc beginDrag(container: ElementId, axis: BarAxis, grab: float32) =
  for g in drags.mitems:
    if g.container == container.id and g.axis == axis:
      g.grab = grab
      return
  drags.add Drag(container: container.id, axis: axis, grab: grab)

proc scrollbarAxis(id: ElementId, container: ElementId, axis: BarAxis,
                   style: ScrollbarStyle) =
  ## Draw one bar: track, then thumb, both floating over the container's
  ## edge, positioned by last frame's scroll state. The thumb is declared
  ## later and floats above the track, so a press on the thumb never
  ## reaches the track's page-jump handler.
  let geom = barGeom(container, axis, style)
  if not geom.scrollable:
    return

  let trackId = localId(if axis == vertical: "sb.vtrack" else: "sb.htrack",
    id.id)
  let thumbId = localId(if axis == vertical: "sb.vthumb" else: "sb.hthumb",
    id.id)

  # Vertical hugs the right edge, horizontal the bottom: element top-left
  # pinned to the container's right-top / left-bottom, pushed inside.
  let (w, h) = if axis == vertical:
    (style.width, geom.track) else: (geom.track, style.width)
  let (points, offset) = if axis == vertical:
    (AttachPoints(element: pointLeftTop, parent: pointRightTop),
     vec2(-(style.width + style.margin), style.margin))
  else:
    (AttachPoints(element: pointLeftTop, parent: pointLeftBottom),
     vec2(style.margin, -(style.width + style.margin)))

  # Track: a click on the bare track jumps the thumb centre to the click.
  openElement(trackId)
  configureOpenElement(row(width = fixedPx(w), height = fixedPx(h))
    .bg(if pointerOver(trackId):
      lerp(style.track, style.thumb, 0.35'f32) else: style.track)
    .corner(style.radius)
    .floating(attachElementId,
      offset = offset, zIndex = 220, points = points,
      parentId = container.id))
  if clickedIn(trackId):
    let local = pointerAlong(axis) -
      containerStart(container, axis) - style.margin
    thumbToPointer(container, axis, local - geom.thumb / 2.0, geom, style)
  closeElement()

  if geom.track - geom.thumb <= 0:
    return # content nearly fills the view: nothing left to grab

  # Thumb: press to start a drag; `advanceDrag` keeps it glued while held.
  let (tw, th) = if axis == vertical:
    (style.width, geom.thumb) else: (geom.thumb, style.width)
  let toffset = if axis == vertical:
    vec2(offset.x, style.margin + geom.top)
  else:
    vec2(style.margin + geom.top, offset.y)
  openElement(thumbId)
  configureOpenElement(row(width = fixedPx(tw), height = fixedPx(th))
    .bg(if geom.dragging or pointerOver(thumbId):
      style.thumbHot else: style.thumb)
    .corner(style.radius)
    .floating(attachElementId,
      offset = toffset, zIndex = 221, points = points,
      parentId = container.id))
  if pressedNow() and pointerOver(thumbId):
    let grab = pointerAlong(axis) -
      containerStart(container, axis) - style.margin - geom.top
    beginDrag(container, axis, grab)
  closeElement()

proc advanceDrags*(container: ElementId, style: ScrollbarStyle) =
  ## Move every held thumb of `container` with the pointer; drop drags
  ## whose pointer went up. Runs from `scrollbar` before drawing, once per
  ## declared container -- by then the pointer state for this frame is in.
  let state = currentContext().pointerData().state
  let down = state == pressed or state == pressedThisFrame
  var i = 0
  while i < drags.len:
    if not down:
      drags.del(i)
    elif drags[i].container == container.id:
      advanceDrag(drags[i], style)
      inc i
    else:
      inc i

proc scrollbar*(id: ElementId, container: ElementId,
                style = activeTheme.scrollbar) =
  ## Draw and drive the floating scrollbar(s) of the scroll container
  ## `container`. Declare inside that container's scope, after its
  ## children. A vertical bar hugs the right edge, a horizontal one the
  ## bottom; each appears only while its axis actually overflows, and both
  ## hide whenever the content fits. The look comes from the live theme's
  ## `scrollbar` tokens unless a style is passed.
  advanceDrags(container, style)
  scrollbarAxis(id, container, vertical, style)
  scrollbarAxis(id, container, horizontal, style)

template scrollPanel*(label: untyped, decl: untyped, body: untyped): untyped =
  ## A framed, scrollable container with its scrollbar attached: opens the
  ## element `label`, configures `decl` -- add
  ## `.clip(horizontal = .., vertical = .., childOffset = currentScrollOffset())`
  ## for the scrolling axes -- runs `body`, then hangs the container's
  ## floating `scrollbar` (under id `label & ".bar"`) before closing it.
  ##
  ##   scrollPanel("list", col(width = grow(), height = grow(), gap = 2)
  ##       .bg(fieldBg).border(hairline, panelBorder).corner(panelRadius)
  ##       .clip(horizontal = false, vertical = true,
  ##             childOffset = currentScrollOffset())):
  ##     ...items...
  let scrollPanelId = elementId(label)
  openElement(scrollPanelId)
  configureOpenElement(decl)
  body
  scrollbar(elementId(label & ".bar"), scrollPanelId)
  closeElement()
