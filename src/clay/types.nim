## Clay public types: geometry, configuration and render commands.
##
## This fragment is `include`d by clay.nim; it must not import anything.
## See clay.nim for the porting notes and the overall design.

## Geometry ------------------------------------------------------------------

type
  Vec2* = object
    ## A 2d point or vector.
    x*, y*: float32

  Size* = object
    ## A width/height pair.
    width*, height*: float32

  Rect* = object
    ## A bounding box: position relative to the layout root, plus size.
    x*, y*, width*, height*: float32

  Color* = object
    ## RGBA colour. Channels are conventionally 0-255 (as in Clay), but the
    ## interpretation is up to the renderer. A fully transparent colour
    ## (`a <= 0`) means "unset": elements only emit a rectangle command when
    ## their background has a non-zero alpha.
    r*, g*, b*, a*: float32

  CornerRadius* = object
    ## Per-corner rounding radius. A circle of the given radius is inset into
    ## each corner of the element's bounding box.
    topLeft*, topRight*, bottomLeft*, bottomRight*: float32

func vec2*(x, y: float32): Vec2 =
  Vec2(x: x, y: y)

func size*(w, h: float32): Size =
  Size(width: w, height: h)

func rect*(x, y, w, h: float32): Rect =
  Rect(x: x, y: y, width: w, height: h)

func rgb*(r, g, b: float32; a: float32 = 255.0): Color =
  Color(r: r, g: g, b: b, a: a)

func allCorners*(radius: float32): CornerRadius =
  CornerRadius(topLeft: radius, topRight: radius,
               bottomLeft: radius, bottomRight: radius)

## Element identity -----------------------------------------------------------

type
  ElementId* = object
    ## A hashed identifier for an element, used for cross-frame queries
    ## (`elementData`, `pointerOver`, `scrollContainerData`) and as the seed
    ## for `localId`. Hash 0 is reserved as the "null id".
    id*: uint32
    offset*: uint32      ## numeric offset mixed into the hash after `label`
    baseId*: uint32      ## hash of `label` alone (before `offset`)
    label*: string       ## best-effort original text, for debug tooling

## Enums ----------------------------------------------------------------------

type
  Direction* = enum
    ## How children of a container are stacked.
    leftToRight,  ## (default) children advance along +x
    topToBottom   ## children advance along +y

  AlignX* = enum
    ## Cross/main axis alignment of children along x.
    left,   ## (default)
    right,
    centerX ## centered within the parent

  AlignY* = enum
    ## Cross/main axis alignment of children along y.
    top,    ## (default)
    bottom,
    centerY ## centered within the parent

  SizingKind* = enum
    ## How an element takes space along one axis inside its parent.
    fitContent, ## (default) hug the content
    grow,       ## fill leftover space, shared among siblings
    percent,    ## fixed fraction of the parent's inner size (0-1)
    fixed       ## exact size in pixels

  WrapMode* = enum
    ## How text breaks into lines.
    wordWrap,     ## (default) break on whitespace
    newlineWrap,  ## break only on newlines
    noWrap        ## never break

  TextJustify* = enum
    ## How wrapped lines align inside the text bounding box.
    justifyLeft,   ## (default)
    justifyCenter,
    justifyRight

  AttachPoint* = enum
    ## One of nine anchor points on an element or its floating parent.
    pointLeftTop, pointLeftCenter, pointLeftBottom,
    pointCenterTop, pointCenterCenter, pointCenterBottom,
    pointRightTop, pointRightCenter, pointRightBottom

  AttachTo* = enum
    ## What a floating element positions itself relative to.
    attachNone,      ## (default) element is not floating
    attachParent,    ## the direct hierarchical parent
    attachElementId, ## the element with `FloatingConfig.parentId`
    attachRoot       ## the layout root ("absolute" positioning)

  ClipTo* = enum
    ## Whether a floating element inherits its attach target's clipping.
    clipToNone,             ## (default)
    clipToAttachedParent

  PointerCapture* = enum
    ## How a floating element handles pointer queries from beneath it.
    capturePointer,    ## (default) hides elements below it from `pointerOver`
    passThroughPointer ## elements below keep receiving pointer events

  PointerState* = enum
    ## The state of the primary pointer this frame.
    pressedThisFrame,
    pressed,
    releasedThisFrame,
    released

  RenderKind* = enum
    ## The type tag of a render command emitted by `endLayout`.
    renderRectangle,
    renderBorder,
    renderText,
    renderImage,
    renderClipStart,
    renderClipEnd,
    renderOverlayStart,
    renderOverlayEnd,
    renderCustom

## Layout configuration --------------------------------------------------------

type
  SizingAxis* = object
    ## Sizing of one axis. `min`/`max` override `fitContent`/`grow`; a `max`
    ## of 0 means "unbounded" and is filled in at element close. `percent` is
    ## only read when `kind == percent` and is expected in 0-1.
    kind*: SizingKind = fitContent
    min*, max*: float32
    percent*: float32

  Sizing* = object
    ## Both axes of an element.
    width*, height*: SizingAxis

  Padding* = object
    ## Gap between the element's box and where children start.
    left*, right*, top*, bottom*: int

  ChildAlignment* = object
    ## How children are aligned on each axis (main axis = "justify").
    x*: AlignX = left
    y*: AlignY = top

  LayoutConfig* = object
    ## Everything that affects the size/position of this element's box and
    ## its children.
    sizing*: Sizing
    padding*: Padding
    gap*: int = 0             ## space between consecutive children
    align*: ChildAlignment
    direction*: Direction = leftToRight

  BorderWidth* = object
    left*, right*, top*, bottom*: int
    betweenChildren*: int     ## lines drawn between each child pair

  BorderConfig* = object
    ## A BORDER render command is emitted when any width > 0.
    color*: Color
    width*: BorderWidth

  ImageConfig* = object
    ## When `data` is non-nil, the element emits an IMAGE command instead of
    ## a RECTANGLE. `tint` defaults to transparent = "untinted".
    data*: nil pointer
    tint*: Color

  CustomConfig* = object
    ## CUSTOM commands for content the built-in command set cannot express.
    data*: nil pointer

  AttachPoints* = object
    ## Which point of a floating element attaches to which point of its
    ## target. Both default to the top-left corner, matching Clay.
    element*, parent*: AttachPoint

  FloatingConfig* = object
    ## Floating elements are removed from the normal flow: they attach to
    ## their parent (or another element, or the root), overlap freely, and do
    ## not influence siblings. They are emitted as independent tree roots in
    ## ascending `zIndex` order.
    offset*: Vec2             ## added to the computed attach position
    expand*: Size             ## grows the painted box without moving children
    parentId*: uint32         ## used with `attachElementId`
    zIndex*: int16
    attachPoints*: AttachPoints
    capture*: PointerCapture = capturePointer
    attachTo*: AttachTo = attachNone
    clipTo*: ClipTo = clipToNone

  ClipConfig* = object
    ## Clipping on each axis plus a child offset; together they form a
    ## scroll container. `childOffset` is applied to every child position.
    horizontal*: bool
    vertical*: bool
    childOffset*: Vec2

  TransitionData* = object
    ## Snapshot of the animatable visual state of an element. Nim-friendly
    ## alternative to Clay's built-in transition engine: keep a `current`
    ## value of this type in your app state, lerp it towards the target each
    ## frame (`lerp`, `easeOut`) and write the result into the declaration.
    box*: Rect
    background*: Color
    overlay*: Color
    border*: Color
    borderWidth*: BorderWidth

  TextConfig* = object
    ## Settings for a text element. All measurement-relevant fields
    ## (`fontId`, `fontSize`, `letterSpacing`) are handed to the user's
    ## measure function; the layout engine only sees the returned size.
    userData*: nil pointer
    color*: Color = Color(r: 0.0, g: 0.0, b: 0.0, a: 255.0)
    fontId*: uint16 = 0
    fontSize*: uint16 = 16
    letterSpacing*: uint16 = 0
    lineHeight*: uint16 = 0       ## 0 = use the measured line height
    wrap*: WrapMode = wordWrap
    justify*: TextJustify = justifyLeft

  ElementDeclaration* = object
    ## The full configuration of a container/visual element: the single
    ## struct passed to `openElement`. Build it with `row`/`col` and the
    ## `with*` combinators, or fill the fields directly.
    layout*: LayoutConfig
    background*: Color
    overlay*: Color
    corner*: CornerRadius
    aspectRatio*: float32 = 0     ## 0 = disabled; otherwise width/height
    image*: ImageConfig
    custom*: CustomConfig
    floating*: FloatingConfig
    clip*: ClipConfig
    border*: BorderConfig
    userData*: nil pointer

## Render commands --------------------------------------------------------------

type
  RenderCommand* = object
    ## One draw instruction produced by `endLayout`. Commands arrive in paint
    ## order; clip start/end and overlay start/end form balanced regions that
    ## the renderer must push/pop.
    box*: Rect
    id*: uint32        ## owning element id, stable across frames
    zIndex*: int16
    userData*: nil pointer
    case kind*: RenderKind
    of renderRectangle:
      fill*: Color
      rectCorner*: CornerRadius
    of renderBorder:
      borderColor*: Color
      borderWidth*: BorderWidth
      borderCorner*: CornerRadius
    of renderText:
      elementIndex*: int32   ## index into `ctx`'s element pool
      lineIndex*: int32      ## index into that element's wrapped lines
      textColor*: Color
      fontId*: uint16
      fontSize*: uint16
      letterSpacing*: uint16
      lineHeight*: uint16
    of renderImage:
      imageCorner*: CornerRadius
      imageData*: nil pointer
      imageTint*: Color
    of renderCustom:
      customData*: nil pointer
      customCorner*: CornerRadius
      customBackground*: Color
    of renderClipStart:
      clipHorizontal*, clipVertical*: bool
    of renderClipEnd:
      nil
    of renderOverlayStart:
      overlay*: Color
    of renderOverlayEnd:
      nil

  TextLine* = object
    ## One wrapped line of a text element: a `[start, start+length)` slice of
    ## the element's string plus its measured size.
    start*, length*: int32
    dims*: Size

## Queries ----------------------------------------------------------------------

type
  ElementData* = object
    ## The final bounding box of an element from the previous frame.
    box*: Rect
    found*: bool

  PointerData* = object
    ## Position (relative to the layout root) and state of the primary
    ## pointer, as supplied through `setPointerState`.
    position*: Vec2
    state*: PointerState

  ScrollContainerData* = object
    ## Live state of a clip/scroll container.
    position*: Vec2            ## current scroll offset, <= 0 per axis
    containerDimensions*: Size ## outer bounding box of the container
    contentDimensions*: Size   ## laid-out content size (incl. padding)
    childOffset*: Vec2        ## the offset applied to children this frame
    horizontal*, vertical*: bool
    found*: bool

## Errors ------------------------------------------------------------------------

type
  ErrorKind* = enum
    ## Recoverable layout problems. Clay aborted on these via callbacks;
    ## here they accumulate in the context and are polled with `takeErrors`,
    ## so layout always completes.
    measureTextMissing,     ## no measure function was installed
    duplicateId,            ## two elements declared with the same id
    floatingParentMissing,  ## `attachElementId` pointed at nothing
    percentOverOne,         ## percent sizing outside 0-1
    unbalancedOpenClose     ## elements were left open at `endLayout`

  ErrorData* = object
    kind*: ErrorKind
    message*: string
    elementId*: uint32

## Small config constructors ------------------------------------------------------

func padAll*(n: int): Padding =
  Padding(left: n, right: n, top: n, bottom: n)

func fit*(min, max: float32 = 0.0): SizingAxis =
  ## Hug the content, clamped to [min, max]. `max` 0 means unbounded.
  SizingAxis(kind: fitContent, min: min, max: max)

func grow*(min, max: float32 = 0.0): SizingAxis =
  ## Fill leftover space along this axis.
  SizingAxis(kind: grow, min: min, max: max)

func fixedPx*(pixels: float32): SizingAxis =
  SizingAxis(kind: fixed, min: pixels, max: pixels)

func pct*(fraction: float32): SizingAxis =
  ## A fraction (0-1) of the parent's inner content size on this axis.
  SizingAxis(kind: percent, percent: fraction)

## Declaration factories ---------------------------------------------------------
##
## These replace Clay's `CLAY_SIZING_*` / `CLAY_BORDER_*` / designated-init
## macros. `row` and `col` build a full `ElementDeclaration` from named
## arguments (mirroring the `row(...)` / `col(...)` sketch in docs/ui.org);
## `with*` combinators decorate it visually. All take `sink` and return a new
## declaration, so they chain:
##
##   row(gap = 8, width = grow()).withBg(panel).withBorder(1, line)

func row*(
  gap: int = 0,
  padding: Padding = Padding(),
  width: SizingAxis = fit(),
  height: SizingAxis = fit(),
  alignX: AlignX = left,
  alignY: AlignY = top,
): ElementDeclaration =
  ## A left-to-right container declaration.
  result = ElementDeclaration(layout: LayoutConfig(
    sizing: Sizing(width: width, height: height),
    padding: padding,
    gap: gap,
    align: ChildAlignment(x: alignX, y: alignY),
    direction: leftToRight,
  ))

func col*(
  gap: int = 0,
  padding: Padding = Padding(),
  width: SizingAxis = fit(),
  height: SizingAxis = fit(),
  alignX: AlignX = left,
  alignY: AlignY = top,
): ElementDeclaration =
  ## A top-to-bottom container declaration.
  result = ElementDeclaration(layout: LayoutConfig(
    sizing: Sizing(width: width, height: height),
    padding: padding,
    gap: gap,
    align: ChildAlignment(x: alignX, y: alignY),
    direction: topToBottom,
  ))

proc withBg*(d: sink ElementDeclaration, color: Color): ElementDeclaration =
  result = d
  result.background = color

proc withOverlay*(d: sink ElementDeclaration, color: Color): ElementDeclaration =
  result = d
  result.overlay = color

proc withCorner*(d: sink ElementDeclaration, radius: float32): ElementDeclaration {.inline.} =
  result = d
  result.corner = allCorners(radius)

proc withCorner*(d: sink ElementDeclaration, topLeft, topRight, bottomLeft, bottomRight: float32): ElementDeclaration =
  result = d
  result.corner = CornerRadius(
    topLeft: topLeft, topRight: topRight,
    bottomLeft: bottomLeft, bottomRight: bottomRight,
  )

proc withBorder*(
  d: sink ElementDeclaration, width: int, color: Color,
  betweenChildren: int = 0,
): ElementDeclaration =
  result = d
  result.border = BorderConfig(
    color: color,
    width: BorderWidth(
      left: width, right: width, top: width, bottom: width,
      betweenChildren: betweenChildren,
    ),
  )

proc withImage*(d: sink ElementDeclaration, data: pointer, tint: Color = Color()): ElementDeclaration =
  result = d
  result.image = ImageConfig(data: data, tint: tint)

proc withCustom*(d: sink ElementDeclaration, data: pointer): ElementDeclaration =
  result = d
  result.custom = CustomConfig(data: data)

proc withClip*(d: sink ElementDeclaration, horizontal, vertical: bool, childOffset = Vec2()): ElementDeclaration =
  ## Makes this element a clip (scroll) container on the given axes.
  result = d
  result.clip = ClipConfig(horizontal: horizontal, vertical: vertical, childOffset: childOffset)

proc withGap*(d: sink ElementDeclaration, gap: int): ElementDeclaration {.inline.} =
  result = d
  result.layout.gap = gap

proc withPadding*(d: sink ElementDeclaration, padding: Padding): ElementDeclaration {.inline.} =
  result = d
  result.layout.padding = padding

proc withAlign*(d: sink ElementDeclaration, x: AlignX, y: AlignY): ElementDeclaration {.inline.} =
  result = d
  result.layout.align = ChildAlignment(x: x, y: y)

proc withSizing*(d: sink ElementDeclaration, width, height: SizingAxis): ElementDeclaration {.inline.} =
  result = d
  result.layout.sizing = Sizing(width: width, height: height)

proc withAspect*(d: sink ElementDeclaration, ratio: float32): ElementDeclaration {.inline.} =
  result = d
  result.aspectRatio = ratio

proc withFloating*(
  d: sink ElementDeclaration,
  attachTo: AttachTo,
  offset: Vec2 = Vec2(),
  zIndex: int16 = 0,
  points: AttachPoints = AttachPoints(),
  parentId: uint32 = 0,
  capture: PointerCapture = capturePointer,
  clipTo: ClipTo = clipToNone,
): ElementDeclaration =
  result = d
  result.floating = FloatingConfig(
    offset: offset, parentId: parentId, zIndex: zIndex,
    attachPoints: points, capture: capture, attachTo: attachTo, clipTo: clipTo,
  )

## Animation helpers ---------------------------------------------------------------
##
## Clay ships a per-element transition engine; in idiomatic immediate-mode Nim
## animation state lives in the app, so these helpers cover the common cases:
## interpolate colours/boxes/declarations between frames yourself.

func lerp*(a, b: float32, t: float32): float32 {.inline.} =
  a + (b - a) * clamp(t, 0.0, 1.0)

func easeOut*(t: float32): float32 {.inline.} =
  ## Cubic ease-out curve, matching Clay's `Clay_EaseOut`.
  let inv = 1.0 - clamp(t, 0.0, 1.0)
  1.0 - inv * inv * inv

func lerp*(a, b: Color, t: float32): Color =
  let k = clamp(t, 0.0, 1.0)
  Color(r: lerp(a.r, b.r, k), g: lerp(a.g, b.g, k),
        b: lerp(a.b, b.b, k), a: lerp(a.a, b.a, k))

func lerp*(a, b: Rect, t: float32): Rect =
  let k = clamp(t, 0.0, 1.0)
  Rect(x: lerp(a.x, b.x, k), y: lerp(a.y, b.y, k),
       width: lerp(a.width, b.width, k), height: lerp(a.height, b.height, k))

func lerp*(a, b: TransitionData, t: float32): TransitionData =
  let k = clamp(t, 0.0, 1.0)
  result = TransitionData()
  result.box = lerp(a.box, b.box, k)
  result.background = lerp(a.background, b.background, k)
  result.overlay = lerp(a.overlay, b.overlay, k)
  result.border = lerp(a.border, b.border, k)
  let ab = a.borderWidth
  let bb = b.borderWidth
  func mix(x, y: int, k: float32): int =
    int(lerp(float32(x), float32(y), k))
  result.borderWidth = BorderWidth(
    left: mix(ab.left, bb.left, k),
    right: mix(ab.right, bb.right, k),
    top: mix(ab.top, bb.top, k),
    bottom: mix(ab.bottom, bb.bottom, k),
    betweenChildren: mix(ab.betweenChildren, bb.betweenChildren, k),
  )

