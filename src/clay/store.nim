## Internal storage types for the layout engine.
##
## Clay keeps every working set in fixed-capacity arrays carved from a user
## arena and threads raw pointers/indices between them. This port uses `seq`
## and `Table` directly: the capacity-exceeded error family and the arena API
## are gone, and cross-frame references carry a generation stamp so stale
## indices can never alias a different element.
## This fragment is included by clay.nim; it must not import anything.

type
  LayoutElement* = object
    ## One element of the layout tree. Containers own an `ElementDeclaration`;
    ## text elements carry a `TextConfig` + string + wrapped lines instead.
    ## (Mirrors Clay's config/text union, discriminated properly.)
    id*: uint32
    gen*: uint32                  ## creation frame, for stale-index guards
    clipId*: uint32               ## enclosing clip container id (0 = none)
    children*: seq[int32]         ## indices into `Context.elements`
    floatingChildren*: int        ## closed floating children (excluded from flow)
    dims*: Size                   ## final size along each axis
    minDims*: Size                ## smallest legal size (drives compression)
    case isText*: bool
    of false:
      decl*: ElementDeclaration
    of true:
      textCfg*: TextConfig
      text*: string
      preferred*: Size          ## unwrapped measurement, kept for line math
      lines*: seq[TextLine]

  MapItem* = object
    ## One entry of the persistent id -> element map. Entries survive frames
    ## so `elementData`/hover/scroll lookups can answer during the next frame;
    ## `generation > ctx.generation` means "declared this frame".
    elementIndex*: int32
    elementGen*: uint32
    box*: Rect
    generation*: uint32
    eid*: ElementId             ## the id as declared (label/offset included)
    appeared*: bool               ## first frame with this id since it vanished
    collision*: bool              ## debug aid: duplicate id this frame
    hover*: nil HoverCallback

  TreeRoot* = object
    ## A layout tree this frame: index 0 is the root container; floating
    ## elements each become their own root, sorted by zIndex before positioning.
    elementIndex*: int32
    parentId*: uint32
    clipElementId*: uint32
    zIndex*: int16

  TreeNode* = object
    ## One frame of the iterative positioning DFS.
    elementIndex*: int32
    position*: Vec2
    nextChildOffset*: Vec2
    hidden*: bool        ## inside a clip container that lies off screen:
                         ## placed and published, but paints nothing

  ScrollData* = object
    ## Per clip/scroll-container state that persists across frames.
    elementIndex*: int32
    elementGen*: uint32
    elementId*: uint32
    box*: Rect                    ## published outer bounding box
    contentSize*: Size            ## laid-out content incl. parent padding
    scrollOrigin*: Vec2           ## drag start position
    pointerOrigin*: Vec2          ## pointer at drag start
    momentum*: Vec2
    position*: Vec2               ## current scroll offset (<= 0 per axis)
    target*: Vec2                 ## where the spring is pulling `position`
    springVel*: Vec2              ## spring integrator velocity
    momentumTime*: float32
    openThisFrame*: bool
    pointerScrollActive*: bool

  MeasuredWord* = object
    ## One whitespace-delimited run of a text string, measured once per
    ## (string, font) pair. `length == 0` marks a forced newline; a trailing
    ## space is included in `length` and its width.
    start*, length*: int32
    width*: float32

  Measurement* = object
    unwrapped*: Size              ## size without any wrapping
    minWidth*: float32            ## widest single word
    containsNewlines*: bool
    words*: seq[MeasuredWord]
    generation*: uint32           ## last frame seen, for cache eviction

  TextKey* = object
    ## Identity of a measurement: the string plus every input the measure
    ## function is allowed to look at.
    text*: string
    fontId*, fontSize*, letterSpacing*: uint16

  MeasureFn* = proc(text: string; cfg: TextConfig): Size {.closure.}
    ## User-provided text measurement. Receives the exact slice to measure
    ## (a single word, `"\n"` as a zero-length probe, or `" "`) with the
    ## config it belongs to; returns that run's size.

  HoverCallback* = proc(id: ElementId, pointer: PointerData) {.closure.}
    ## Bound to an element with `onHover`; fired next frame while the pointer
    ## is inside the element's stored bounding box.

  Context* = ref object
    ## All layout state. Create one with `initContext`; multi-window apps can
    ## hold several and switch with `setCurrentContext`.
    dims*: Size                   ## layout dimensions (set every frame)
    generation*: uint32           ## frame counter
    rootResizedLastFrame*: bool

    # --- per-frame ephemeral state (reset by beginLayout)
    elements*: seq[LayoutElement]
    openStack*: seq[int32]        ## element indices of currently-open elements
    clipStack*: seq[uint32]       ## ids of enclosing clip/floating elements
    roots*: seq[TreeRoot]
    commands*: seq[RenderCommand]
    frameText*: seq[int32]        ## text elements found by the x pass
    frameAspect*: seq[int32]      ## aspect-ratio elements found by the x pass

    # --- cross-frame persistent state
    elementMap*: Table[uint32, MapItem]
    textCache*: Table[TextKey, Measurement]
    scrollDatas*: seq[ScrollData]

    # --- input state
    pointer*: PointerData
    pointerOver*: seq[ElementId]

    # --- host hooks
    measureText*: nil MeasureFn
    queryScrollOffset*: nil (proc(id: uint32): Vec2 {.closure.})
    externalScrollHandling*: bool
    cullingEnabled*: bool = true

    errors*: seq[ErrorData]

func isLive*(ctx: Context; item: MapItem): bool =
  ## True while `item` refers to an element declared this frame.
  item.generation > ctx.generation

func elementOf*(ctx: Context; index: int32): var LayoutElement =
  ctx.elements[index]

func isOpen*(ctx: Context; index: int32): bool =
  index >= 0 and index < ctx.elements.len and
    ctx.elements[index].gen == ctx.generation + 1u32
