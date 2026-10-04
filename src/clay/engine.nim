## The layout engine: element lifecycle, sizing passes, final positioning,
## render command emission.
##
## Faithful port of Clay 0.14's three-phase pipeline:
##   1. `closeElement` folds each container's content size (Clay__CloseElement)
##   2. `sizeContainersAlongAxis` runs once per axis and resolves percent /
##      grow / compression geometry (Clay__SizeContainersAlongAxis)
##   3. the positioning DFS places children and emits render commands
##      (Clay__CalculateFinalLayout)
## Deviations from the C original are marked "NOTE:" and summarised in the
## clay.nim header.
## This fragment is included by clay.nim; it must not import anything.

const
  epsilon: float32 = 0.01'f32           ## Clay__EPSILON: size change worth reacting to
  maxFloat: float32 = 3.4028234663852886e38'f32  ## sentinel for "unbounded" sizing max

func rootContainerId*(): uint32 =
  ## The id of the synthetic fixed-size root opened by `beginLayout`.
  hashString(rootContainerLabel, 0)

func isFloatingEl(el: LayoutElement): bool =
  not el.isText and el.decl.floating.attachTo != attachNone

func isClipEl(el: LayoutElement): bool =
  not el.isText and (el.decl.clip.horizontal or el.decl.clip.vertical)

func sizingFor(el: LayoutElement; xAxis: bool): SizingAxis =
  ## Text elements have no declaration: their sizing is the default
  ## (fit / unbounded), exactly like Clay's zeroed union read.
  if el.isText:
    return SizingAxis()
  if xAxis: el.decl.layout.sizing.width else: el.decl.layout.sizing.height

func axisSize(el: LayoutElement; xAxis: bool): float32 {.inline.} =
  if xAxis: el.dims.width else: el.dims.height

func axisMin(el: LayoutElement; xAxis: bool): float32 {.inline.} =
  if xAxis: el.minDims.width else: el.minDims.height

func floatEqual(a, b: float32): bool {.inline.} =
  let d = a - b
  d < epsilon and d > -epsilon

proc setSize(el: var LayoutElement; xAxis: bool; v: float32) {.inline.} =
  if xAxis: el.dims.width = v else: el.dims.height = v

func paddingAlong(layout: LayoutConfig; xAxis: bool): float32 {.inline.} =
  float32(if xAxis: layout.padding.left + layout.padding.right
          else: layout.padding.top + layout.padding.bottom)

proc updateAspectRatio(el: var LayoutElement) =
  if el.isText: return
  let ratio = el.decl.aspectRatio
  if ratio == 0: return
  if el.dims.width == 0 and el.dims.height != 0:
    el.dims.width = el.dims.height * ratio
  elif el.dims.width != 0 and el.dims.height == 0:
    el.dims.height = el.dims.width * (1 / ratio)

## --- id -> element map ----------------------------------------------------------

proc addMapItem(ctx: Context; eid: ElementId; elementIndex: int32) =
  var item = ctx.elementMap.getOrDefault(eid.id, MapItem(elementIndex: -1))
  if item.elementIndex >= 0:
    if item.generation <= ctx.generation:
      # First sighting of a carried-over id: the element reappeared after at
      # least one missing frame.
      item.appeared = item.generation < ctx.generation
      item.generation = ctx.generation + 1
      item.elementIndex = elementIndex
      item.elementGen = ctx.generation + 1
      item.collision = false
      item.hover = nil
      item.box = Rect()
      item.eid = eid
      ctx.elementMap[eid.id] = item
      return
    # Two elements declared with the same id within this frame: keep the old
    # entry (pointer queries stay consistent with its box) and report it.
    reportError(ctx, duplicateId,
      "an element with this id was already declared during this layout", eid.id)
    item.collision = true
    ctx.elementMap[eid.id] = item
    return
  ctx.elementMap[eid.id] = MapItem(
    elementIndex: elementIndex,
    elementGen: ctx.generation + 1,
    generation: ctx.generation + 1,
    eid: eid,
    appeared: true,
    hover: nil,
  )

proc findScrollData(ctx: Context; elementId: uint32): int =
  for i in 0 ..< ctx.scrollDatas.len:
    if ctx.scrollDatas[i].elementId == elementId:
      return i
  return -1

## --- element lifecycle ------------------------------------------------------------

proc configureOpenElement*(ctx: Context; decl: ElementDeclaration) =
  ## Apply a declaration to the innermost open element and register its side
  ## effects: floating elements become tree roots, clip elements become scroll
  ## containers, and the clip stack tracks the innermost enclosing clip.
  ##
  ## Split from `openElement` -- like Clay's macro pair -- so that
  ## declaration-time expressions such as `currentScrollOffset()` observe the
  ## element already being open (matching `Clay_GetScrollOffset` semantics).
  let index = ctx.openStack[^1]
  var el = ctx.elements[index]
  el.decl = decl

  if (el.decl.layout.sizing.width.kind == percent and
      el.decl.layout.sizing.width.percent > 1) or
     (el.decl.layout.sizing.height.kind == percent and
      el.decl.layout.sizing.height.percent > 1):
    reportError(ctx, percentOverOne,
      "percent sizing expects a fraction 0-1 (20% is 0.2)", el.id)

  if el.decl.floating.attachTo != attachNone:
    # The stack always holds the implicit root plus this element.
    var parentId = el.decl.floating.parentId
    var clipElementId: uint32 = 0
    case el.decl.floating.attachTo
    of attachParent:
      parentId = ctx.elements[ctx.openStack[^2]].id
      if ctx.clipStack.len > 0:
        clipElementId = ctx.clipStack[^1]
    of attachElementId:
      let item = ctx.elementMap.getOrDefault(parentId, MapItem(elementIndex: -1))
      if item.elementIndex < 0:
        reportError(ctx, floatingParentMissing,
          "floating element attached to an id that was never declared", el.id)
      elif item.elementIndex >= 0 and
          item.elementIndex.int < ctx.elements.len and
          ctx.elements[item.elementIndex].gen == item.elementGen:
        # Inherit the clip of the attached element's subtree.
        clipElementId = ctx.elements[item.elementIndex].clipId
    of attachRoot:
      parentId = rootContainerId()
    else: discard
    el.decl.floating.parentId = parentId
    if el.decl.floating.clipTo == clipToNone:
      clipElementId = 0
    # Even a 0 clip id is pushed so closeElement can pop symmetrically.
    el.clipId = clipElementId
    ctx.elements[index] = el
    ctx.clipStack.add(clipElementId)
    ctx.roots.add TreeRoot(
      elementIndex: index,
      parentId: parentId,
      clipElementId: clipElementId,
      zIndex: el.decl.floating.zIndex,
    )

  if el.decl.clip.horizontal or el.decl.clip.vertical:
    ctx.clipStack.add(el.id)
    let existing = findScrollData(ctx, el.id)
    var position = Vec2()
    let querying = ctx.externalScrollHandling and ctx.queryScrollOffset != nil
    if querying:
      position = ctx.queryScrollOffset(el.id)
    if existing >= 0:
      ctx.scrollDatas[existing].elementIndex = index
      ctx.scrollDatas[existing].elementGen = el.gen
      ctx.scrollDatas[existing].openThisFrame = true
      if querying:
        ctx.scrollDatas[existing].position = position
        ctx.scrollDatas[existing].target = position
    else:
      ctx.scrollDatas.add ScrollData(
        elementIndex: index, elementGen: el.gen, elementId: el.id,
        position: position, target: position, openThisFrame: true,
      )

  ctx.elements[index] = el

proc openElement*(ctx: Context; declaredId: ElementId) =
  ## Begin an element with an explicit id; configure it with
  ## `configureOpenElement` (or use the combined overload below). Every
  ## `openElement` must be balanced by exactly one `closeElement` -- the
  ## `clay` DSL brackets this for you.
  var el = LayoutElement(id: declaredId.id, gen: ctx.generation + 1,
                         isText: false, children: @[])
  if ctx.clipStack.len > 0:
    el.clipId = ctx.clipStack[^1]
  let index = int32(ctx.elements.len)
  ctx.elements.add(el)
  ctx.openStack.add(index)
  addMapItem(ctx, declaredId, index)

proc openElement*(ctx: Context) =
  ## Begin an element with a generated id: hash of (parent id, sibling index),
  ## stable while the declaration order of siblings is stable. This is Clay's
  ## `CLAY_AUTO_ID`.
  assert ctx.openStack.len >= 1, "call beginLayout before declaring elements"
  let parent = ctx.elements[ctx.openStack[^1]]
  let offset = uint32(parent.children.len + parent.floatingChildren)
  let h = hashNumber(offset, parent.id)
  openElement(ctx, makeId(h, h, ""))

proc openElement*(ctx: Context; declaredId: ElementId; decl: ElementDeclaration) =
  ## Combined convenience: open with an explicit id and configure at once.
  openElement(ctx, declaredId)
  configureOpenElement(ctx, decl)

proc openElement*(ctx: Context; decl: ElementDeclaration) =
  ## Combined convenience: auto-generated id + configure.
  openElement(ctx)
  configureOpenElement(ctx, decl)

proc textElement*(ctx: Context; text: string; cfg: TextConfig = TextConfig()) =
  ## Declare a leaf text element in the currently open container. Its size is
  ## the cached measurement of `text`; line breaking happens later, between
  ## the horizontal and vertical sizing passes.
  assert ctx.openStack.len >= 1, "call beginLayout before declaring elements"
  let parentIdx = ctx.openStack[^1]
  let parent = ctx.elements[parentIdx]
  let h = hashNumber(uint32(parent.children.len + parent.floatingChildren), parent.id)
  let m = measureTextCached(ctx, text, cfg)
  var el = LayoutElement(
    id: h, gen: ctx.generation + 1, isText: true,
    textCfg: cfg, text: text, lines: @[], children: @[],
    dims: Size(
      width: m.unwrapped.width,
      height: if cfg.lineHeight > 0: float32(cfg.lineHeight) else: m.unwrapped.height),
    minDims: Size(width: m.minWidth, height: 0),
  )
  el.minDims.height = el.dims.height
  el.preferred = m.unwrapped
  if ctx.clipStack.len > 0:
    el.clipId = ctx.clipStack[^1]
  let index = int32(ctx.elements.len)
  ctx.elements.add(el)
  addMapItem(ctx, makeId(h, h, ""), index)
  ctx.elements[parentIdx].children.add(index)

proc closeElement*(ctx: Context) =
  ## Finish the innermost open element: fold child sizes into the container,
  ## apply sizing clamps, and attach it to its parent (or count it as a
  ## floating child, which is excluded from normal flow).
  let closeIndex = ctx.openStack[^1]
  var el = ctx.elements[closeIndex]
  if isClipEl(el) or isFloatingEl(el):
    ctx.clipStack.setLen(ctx.clipStack.len - 1)

  let layout = el.decl.layout
  let leftRight = float32(layout.padding.left + layout.padding.right)
  let topBottom = float32(layout.padding.top + layout.padding.bottom)
  let clipH = el.decl.clip.horizontal
  let clipV = el.decl.clip.vertical
  let gap = float32(max(el.children.len - 1, 0) * layout.gap)

  if layout.direction == leftToRight:
    el.dims.width = leftRight
    el.minDims.width = leftRight
    for childIndex in el.children:
      let child = ctx.elements[childIndex]
      el.dims.width += child.dims.width
      el.dims.height = max(el.dims.height, child.dims.height + topBottom)
      # A clip container's children can scroll out of view, so their minimum
      # size does not constrain this element along the clipped axes.
      if not clipH:
        el.minDims.width += child.minDims.width
      if not clipV:
        el.minDims.height = max(el.minDims.height, child.minDims.height + topBottom)
    el.dims.width += gap
    if not clipH:
      el.minDims.width += gap
  elif layout.direction == topToBottom:
    el.dims.height = topBottom
    el.minDims.height = topBottom
    for childIndex in el.children:
      let child = ctx.elements[childIndex]
      el.dims.height += child.dims.height
      el.dims.width = max(el.dims.width, child.dims.width + leftRight)
      if not clipV:
        el.minDims.height += child.minDims.height
      if not clipH:
        el.minDims.width = max(el.minDims.width, child.minDims.width + leftRight)
    el.dims.height += gap
    if not clipV:
      el.minDims.height += gap

  # Clamp measured sizes to the configured min/max. An unset (<= 0) max is
  # materialised as "unbounded" so later passes treat it uniformly.
  var decl = el.decl
  if decl.layout.sizing.width.kind != percent:
    if decl.layout.sizing.width.max <= 0:
      decl.layout.sizing.width.max = maxFloat
    el.dims.width = clamp(el.dims.width, decl.layout.sizing.width.min,
                          decl.layout.sizing.width.max)
    el.minDims.width = clamp(el.minDims.width, decl.layout.sizing.width.min,
                             decl.layout.sizing.width.max)
  else:
    el.dims.width = 0   # percent elements start empty; resolved in the x pass
  if decl.layout.sizing.height.kind != percent:
    if decl.layout.sizing.height.max <= 0:
      decl.layout.sizing.height.max = maxFloat
    el.dims.height = clamp(el.dims.height, decl.layout.sizing.height.min,
                           decl.layout.sizing.height.max)
    el.minDims.height = clamp(el.minDims.height, decl.layout.sizing.height.min,
                              decl.layout.sizing.height.max)
  else:
    el.dims.height = 0
  el.decl = decl
  updateAspectRatio(el)
  ctx.elements[closeIndex] = el

  ctx.openStack.setLen(ctx.openStack.len - 1)
  if ctx.openStack.len > 1:
    var parent = ctx.elements[ctx.openStack[^1]]
    if isFloatingEl(el):
      parent.floatingChildren += 1
    else:
      parent.children.add(closeIndex)
    ctx.elements[ctx.openStack[^1]] = parent

## --- sizing passes ------------------------------------------------------------------

proc sizeContainersAlongAxis*(ctx: Context; xAxis: bool) =
  ## One BFS pass over every tree root sizing this axis: expands percent
  ## elements, compresses overflow towards content minimums, and distributes
  ## leftover space among grow elements. The horizontal pass also collects the
  ## text and aspect-ratio elements that need follow-up handling (into
  ## `ctx.frameText` / `ctx.frameAspect`).
  var bfs = newSeq[int32]()
  var resizable = newSeq[int32]()
  let collecting = xAxis

  for rootIndex in 0 ..< ctx.roots.len:
    let root = ctx.roots[rootIndex]
    bfs.setLen(0)
    bfs.add(root.elementIndex)
    var rootEl = ctx.elements[root.elementIndex]

    # Floating roots size themselves to their attach target first: grow takes
    # the parent's dimension verbatim, percent scales it.
    if isFloatingEl(rootEl):
      let item = ctx.elementMap.getOrDefault(
        rootEl.decl.floating.parentId, MapItem(elementIndex: -1))
      if item.elementIndex >= 0 and item.elementIndex.int < ctx.elements.len and
          ctx.elements[item.elementIndex].gen == item.elementGen:
        let parentEl = ctx.elements[item.elementIndex]
        case rootEl.decl.layout.sizing.width.kind
        of grow:
          rootEl.dims.width = parentEl.dims.width
        of percent:
          rootEl.dims.width = parentEl.dims.width *
            rootEl.decl.layout.sizing.width.percent
        else: discard
        case rootEl.decl.layout.sizing.height.kind
        of grow:
          rootEl.dims.height = parentEl.dims.height
        of percent:
          rootEl.dims.height = parentEl.dims.height *
            rootEl.decl.layout.sizing.height.percent
        else: discard
        ctx.elements[root.elementIndex] = rootEl
        rootEl = ctx.elements[root.elementIndex]

    # Clamp the root against its own min/max; percent roots are exempt.
    if rootEl.decl.layout.sizing.width.kind != percent:
      rootEl.dims.width = clamp(rootEl.dims.width,
        rootEl.decl.layout.sizing.width.min, rootEl.decl.layout.sizing.width.max)
    if rootEl.decl.layout.sizing.height.kind != percent:
      rootEl.dims.height = clamp(rootEl.dims.height,
        rootEl.decl.layout.sizing.height.min, rootEl.decl.layout.sizing.height.max)
    ctx.elements[root.elementIndex] = rootEl

    var i = 0
    while i < bfs.len:
      let parentIndex = bfs[i]
      inc i
      let parentEl = ctx.elements[parentIndex]
      # bfs only ever holds containers (text children are never enqueued),
      # so `parentEl.decl` is always valid here.
      let layout = parentEl.decl.layout
      var growCount = 0
      let parentSize = axisSize(parentEl, xAxis)
      let parentPadding = paddingAlong(layout, xAxis)
      var innerContentSize: float32 = 0
      var totalPaddingAndGaps = parentPadding
      let sizingAlongAxis = (xAxis and layout.direction == leftToRight) or
                            (not xAxis and layout.direction == topToBottom)
      let parentGap = float32(layout.gap)
      resizable.setLen(0)
      var isFirstChild = true

      for childIndex in parentEl.children:
        let child = ctx.elements[childIndex]
        let childSizing = sizingFor(child, xAxis)
        let childSize = axisSize(child, xAxis)

        if child.isText:
          if collecting:
            ctx.frameText.add(childIndex)
        elif child.children.len > 0:
          bfs.add(childIndex)
        if collecting and not child.isText and child.decl.aspectRatio != 0:
          ctx.frameAspect.add(childIndex)

        # Fixed and percent children are never compressed, grown, or
        # cross-axis clamped; text only joins when it wraps on words.
        if childSizing.kind != percent and childSizing.kind != fixed and
            (not child.isText or child.textCfg.wrap == wordWrap):
          resizable.add(childIndex)

        if sizingAlongAxis:
          if childSizing.kind != percent:
            innerContentSize += childSize
          if childSizing.kind == grow:
            inc growCount
          if not isFirstChild:
            innerContentSize += parentGap
            totalPaddingAndGaps += parentGap
        else:
          innerContentSize = max(childSize, innerContentSize)
        isFirstChild = false

      # Percent expansion is a second full scan: its base size (parent minus
      # padding and gaps) is only final once every sibling contributes.
      for childIndex in parentEl.children:
        var child = ctx.elements[childIndex]
        let childSizing = sizingFor(child, xAxis)
        if childSizing.kind == percent:
          child.setSize(xAxis, (parentSize - totalPaddingAndGaps) * childSizing.percent)
          if sizingAlongAxis:
            innerContentSize += axisSize(child, xAxis)
          updateAspectRatio(child)
          ctx.elements[childIndex] = child

      if sizingAlongAxis:
        var sizeToDistribute = parentSize - parentPadding - innerContentSize

        if sizeToDistribute < 0:
          # Overflow: compress children. A parent that clips this axis keeps
          # children at their natural size and lets content overflow instead.
          let clipsAxis = (xAxis and parentEl.decl.clip.horizontal) or
                          (not xAxis and parentEl.decl.clip.vertical)
          if not clipsAxis:
            while sizeToDistribute < -epsilon and resizable.len > 0:
              # Water-fill down to the second-largest size, but never slower
              # than an even share of the deficit. NOTE: the two comparisons
              # run independently, exactly like the C original: a new largest
              # can immediately register as the second largest of itself.
              var largest: float32 = 0
              var secondLargest: float32 = 0
              var widthToAdd = sizeToDistribute
              for j in 0 ..< resizable.len:
                let ch = ctx.elements[resizable[j]]
                let cs = axisSize(ch, xAxis)
                if not floatEqual(cs, largest):
                  if cs > largest:
                    secondLargest = largest
                    largest = cs
                  if cs < largest:
                    secondLargest = max(secondLargest, cs)
                    widthToAdd = secondLargest - largest
              widthToAdd = max(widthToAdd, sizeToDistribute / float32(resizable.len))
              var k = 0
              while k < resizable.len:
                var ch = ctx.elements[resizable[k]]
                let minSize = axisMin(ch, xAxis)
                let previous = axisSize(ch, xAxis)
                var popped = false
                if floatEqual(previous, largest):
                  ch.setSize(xAxis, previous + widthToAdd)
                  if axisSize(ch, xAxis) <= minSize:
                    ch.setSize(xAxis, minSize)
                    ctx.elements[resizable[k]] = ch
                    # Hit the floor: drop from the frontier; stay on slot k so
                    # the swapped-in element gets re-visited.
                    let last = resizable[^1]
                    resizable[k] = last
                    resizable.setLen(resizable.len - 1)
                    popped = true
                  else:
                    sizeToDistribute -= axisSize(ch, xAxis) - previous
                    ctx.elements[resizable[k]] = ch
                if not popped:
                  inc k

        elif sizeToDistribute > 0 and growCount > 0:
          # Surplus: only grow elements participate.
          var k = 0
          while k < resizable.len:
            if sizingFor(ctx.elements[resizable[k]], xAxis).kind != grow:
              let last = resizable[^1]
              resizable[k] = last
              resizable.setLen(resizable.len - 1)
            else:
              inc k
          while sizeToDistribute > epsilon and resizable.len > 0:
            var smallest = maxFloat
            var secondSmallest = maxFloat
            var widthToAdd = sizeToDistribute
            for j in 0 ..< resizable.len:
              let ch = ctx.elements[resizable[j]]
              let cs = axisSize(ch, xAxis)
              if not floatEqual(cs, smallest):
                if cs < smallest:
                  secondSmallest = smallest
                  smallest = cs
                if cs > smallest:
                  secondSmallest = min(secondSmallest, cs)
                  widthToAdd = secondSmallest - smallest
            widthToAdd = min(widthToAdd, sizeToDistribute / float32(resizable.len))
            k = 0
            while k < resizable.len:
              var ch = ctx.elements[resizable[k]]
              let maxSize = sizingFor(ch, xAxis).max
              let previous = axisSize(ch, xAxis)
              var popped = false
              if floatEqual(previous, smallest):
                ch.setSize(xAxis, previous + widthToAdd)
                if axisSize(ch, xAxis) >= maxSize:
                  ch.setSize(xAxis, maxSize)
                  ctx.elements[resizable[k]] = ch
                  let last = resizable[^1]
                  resizable[k] = last
                  resizable.setLen(resizable.len - 1)
                  popped = true
                else:
                  sizeToDistribute -= axisSize(ch, xAxis) - previous
                  ctx.elements[resizable[k]] = ch
              if not popped:
                inc k

      else:
        # Cross axis: clamp every resizable child into the parent's inner box.
        var k = 0
        while k < resizable.len:
          var ch = ctx.elements[resizable[k]]
          let childSizing = sizingFor(ch, xAxis)
          let minSize = axisMin(ch, xAxis)
          var maxSize = parentSize - parentPadding
          let clipsAxis = (xAxis and parentEl.decl.clip.horizontal) or
                          (not xAxis and parentEl.decl.clip.vertical)
          if clipsAxis:
            # Grow children of a scroll container expand to content size, not
            # viewport size.
            maxSize = max(maxSize, innerContentSize)
          if childSizing.kind == grow:
            ch.setSize(xAxis, min(maxSize, childSizing.max))
          ch.setSize(xAxis, max(minSize, min(axisSize(ch, xAxis), maxSize)))
          ctx.elements[resizable[k]] = ch
          inc k

## --- final layout ------------------------------------------------------------------

func attachCol(p: AttachPoint): int {.inline.} =
  ## 0 = left, 1 = center, 2 = right -- the enum is ordered so that the
  ## horizontal component is the slow one, matching Clay's attach matrix.
  p.int div 3

func attachRow(p: AttachPoint): int {.inline.} =
  ## 0 = top, 1 = center, 2 = bottom.
  p.int mod 3

proc hasBorder(el: LayoutElement): bool =
  let w = el.decl.border.width
  w.left > 0 or w.right > 0 or w.top > 0 or w.bottom > 0 or w.betweenChildren > 0

proc offscreen(ctx: Context; box: Rect): bool {.inline.} =
  if not ctx.cullingEnabled:
    return false
  box.x > ctx.dims.width or box.y > ctx.dims.height or
    box.x + box.width < 0 or box.y + box.height < 0

proc propagateHeights(ctx: Context) =
  ## Re-fold container heights from children after text wrapping may have
  ## changed them (Clay 12.4). Iterative post-order DFS: a node is updated
  ## only once every child has been visited.
  var stack: seq[tuple[idx: int32, next: int]] = @[]
  for root in ctx.roots:
    stack.setLen(0)
    stack.add((root.elementIndex, 0))
    while stack.len > 0:
      let topIdx = stack.high
      let el = ctx.elements[stack[topIdx].idx]
      if stack[topIdx].next < el.children.len:
        let childIdx = el.children[stack[topIdx].next]
        stack[topIdx].next += 1
        stack.add((childIdx, 0))
      else:
        # Post-order visit: pop, then fold children heights into this element.
        let myIdx = stack[topIdx].idx
        stack.setLen(stack.len - 1)
        if not el.isText:
          var cur = el
          let layout = cur.decl.layout
          if layout.direction == leftToRight:
            for childIndex in el.children:
              let child = ctx.elements[childIndex]
              let childHeight = max(child.dims.height +
                  float32(layout.padding.top + layout.padding.bottom), cur.dims.height)
              cur.dims.height = clamp(childHeight, layout.sizing.height.min,
                                      layout.sizing.height.max)
          elif layout.direction == topToBottom:
            var contentHeight = float32(layout.padding.top + layout.padding.bottom)
            for childIndex in el.children:
              contentHeight += ctx.elements[childIndex].dims.height
            contentHeight += float32(max(el.children.len - 1, 0) * layout.gap)
            cur.dims.height = clamp(contentHeight, layout.sizing.height.min,
                                    layout.sizing.height.max)
          ctx.elements[myIdx] = cur

proc sortRootsStable(ctx: Context) =
  ## Ascending zIndex, insertion sort: stable, so equal zIndex keeps the
  ## declaration order (Clay uses a bubble sort for the same reason).
  for i in 1 ..< ctx.roots.len:
    var j = i
    while j > 0 and ctx.roots[j].zIndex < ctx.roots[j-1].zIndex:
      let prev = ctx.roots[j-1]
      let tmp = ctx.roots[j]
      ctx.roots[j] = prev
      ctx.roots[j-1] = tmp
      dec j

proc positionAndEmit(ctx: Context) =
  ## Place every tree root (floating roots last, in ascending zIndex),
  ## publish bounding boxes to the id map and emit render commands in paint
  ## order. This is Clay's `Clay__CalculateFinalLayout` final pass.
  ctx.commands.setLen(0)
  for root in ctx.roots:
    # NOTE: Clay bubble-sorts roots (stable); we sort once before the pass
    # with a stable sort. Equal zIndex keeps declaration order.
    let rootEl = ctx.elements[root.elementIndex]
    var rootPos = Vec2()
    var parentItem = ctx.elementMap.getOrDefault(root.parentId, MapItem(elementIndex: -1))

    # ---- floating attach point mapping
    if isFloatingEl(rootEl) and parentItem.elementIndex >= 0:
      let f = rootEl.decl.floating
      let pb = parentItem.box
      let colP = attachCol(f.attachPoints.parent)
      let rowP = attachRow(f.attachPoints.parent)
      let colE = attachCol(f.attachPoints.element)
      let rowE = attachRow(f.attachPoints.element)
      let pf = [float32(0), pb.width / 2, pb.width]
      let pr = [float32(0), pb.height / 2, pb.height]
      let ef = [float32(0), rootEl.dims.width / 2, rootEl.dims.width]
      let er = [float32(0), rootEl.dims.height / 2, rootEl.dims.height]
      rootPos = vec2(pb.x + pf[colP] - ef[colE] + f.offset.x,
                     pb.y + pr[rowP] - er[rowE] + f.offset.y)

    # ---- scissor for the whole floating subtree
    if root.clipElementId != 0:
      let clipItem = ctx.elementMap.getOrDefault(root.clipElementId, MapItem(elementIndex: -1))
      if clipItem.elementIndex >= 0 and not offscreen(ctx, clipItem.box):
        if ctx.externalScrollHandling and clipItem.elementIndex.int < ctx.elements.len and
            ctx.elements[clipItem.elementIndex].gen == clipItem.elementGen:
          # Floating attached to scrolled contents: re-apply the inner offset.
          let clipEl = ctx.elements[clipItem.elementIndex]
          if clipEl.decl.clip.horizontal:
            rootPos.x += clipEl.decl.clip.childOffset.x
          if clipEl.decl.clip.vertical:
            rootPos.y += clipEl.decl.clip.childOffset.y
        ctx.commands.add RenderCommand(
          kind: renderClipStart, box: clipItem.box, zIndex: root.zIndex,
          id: hashNumber(rootEl.id, uint32(rootEl.children.len + 10)),
          clipHorizontal: true, clipVertical: true)

    # ---- DFS
    var stack: seq[TreeNode] = @[]
    var visited: seq[bool] = @[]
    stack.add TreeNode(
      elementIndex: root.elementIndex, position: rootPos,
      nextChildOffset: vec2(
        float32(if not rootEl.isText: rootEl.decl.layout.padding.left else: 0),
        float32(if not rootEl.isText: rootEl.decl.layout.padding.top else: 0)))
    visited.add(false)

    while stack.len > 0:
      let topIdx = stack.high
      let el = ctx.elements[stack[topIdx].elementIndex]
      let layout =
        if el.isText: LayoutConfig() else: el.decl.layout

      if visited[topIdx]:
        # ================= up-pass: close overlays / scissors / borders ====
        if not el.isText:
          var item = ctx.elementMap.getOrDefault(el.id, MapItem(elementIndex: -1))
          if item.elementIndex >= 0 and not offscreen(ctx, item.box):
            var closeClip = false
            var scrollOffset = Vec2()
            if isClipEl(el):
              closeClip = true
              for i in 0 ..< ctx.scrollDatas.len:
                if ctx.scrollDatas[i].elementIndex == stack[topIdx].elementIndex and
                    ctx.scrollDatas[i].elementGen == el.gen:
                  scrollOffset = el.decl.clip.childOffset
                  if ctx.externalScrollHandling:
                    scrollOffset = Vec2()
                  break
            if hasBorder(el):
              let bb = item.box
              let bc = el.decl.border
              ctx.commands.add RenderCommand(
                kind: renderBorder, box: bb,
                id: hashNumber(el.id, uint32(el.children.len)),
                userData: el.decl.userData,
                borderColor: bc.color, borderWidth: bc.width,
                borderCorner: el.decl.corner)
              if bc.width.betweenChildren > 0 and bc.color.a > 0:
                let halfGap = float32(layout.gap) / 2
                let halfWidth = float32(bc.width.betweenChildren) / 2
                var borderOffset = vec2(
                  float32(layout.padding.left) - halfGap,
                  float32(layout.padding.top) - halfGap)
                if layout.direction == leftToRight:
                  for ci in 0 ..< el.children.len:
                    let child = ctx.elements[el.children[ci]]
                    if ci > 0:
                      ctx.commands.add RenderCommand(
                        kind: renderRectangle,
                        box: Rect(x: bb.x + borderOffset.x + scrollOffset.x - halfWidth,
                                  y: bb.y + scrollOffset.y,
                                  width: float32(bc.width.betweenChildren),
                                  height: el.dims.height),
                        id: hashNumber(el.id, uint32(el.children.len + 1 + ci)),
                        fill: bc.color)
                    borderOffset.x += child.dims.width + float32(layout.gap)
                else:
                  for ci in 0 ..< el.children.len:
                    let child = ctx.elements[el.children[ci]]
                    if ci > 0:
                      ctx.commands.add RenderCommand(
                        kind: renderRectangle,
                        box: Rect(x: bb.x + scrollOffset.x,
                                  y: bb.y + borderOffset.y + scrollOffset.y - halfWidth,
                                  width: el.dims.width,
                                  height: float32(bc.width.betweenChildren)),
                        id: hashNumber(el.id, uint32(el.children.len + 1 + ci)),
                        fill: bc.color)
                    borderOffset.y += child.dims.height + float32(layout.gap)
            if el.decl.overlay.a > 0:
              ctx.commands.add RenderCommand(
                kind: renderOverlayEnd, id: el.id, zIndex: root.zIndex,
                userData: el.decl.userData)
            if closeClip:
              # NOTE: Clay seeds the scissor-end id with the *root* element's
              # child count; preserved for id parity.
              ctx.commands.add RenderCommand(
                kind: renderClipEnd,
                id: hashNumber(el.id, uint32(rootEl.children.len + 11)),
                zIndex: root.zIndex, userData: el.decl.userData)
        stack.setLen(stack.len - 1)
        visited.setLen(visited.len - 1)
      else:

        # ================= down-pass =========================================
        visited[topIdx] = true
        let node = stack[topIdx]
        var currentBox = Rect(
          x: node.position.x, y: node.position.y,
          width: el.dims.width, height: el.dims.height)
        var scrollOffset = Vec2()
        var scrollIdx = -1
        if not el.isText:
          if isFloatingEl(el):
            # Expand grows the painted box without moving children.
            let exp = el.decl.floating.expand
            currentBox.x -= exp.width
            currentBox.width += exp.width * 2
            currentBox.y -= exp.height
            currentBox.height += exp.height * 2
          if isClipEl(el):
            for i in 0 ..< ctx.scrollDatas.len:
              if ctx.scrollDatas[i].elementIndex == stack[topIdx].elementIndex and
                  ctx.scrollDatas[i].elementGen == el.gen:
                scrollIdx = i
                ctx.scrollDatas[i].box = currentBox
                scrollOffset = el.decl.clip.childOffset
                if ctx.externalScrollHandling:
                  scrollOffset = Vec2()
                break

        let off = offscreen(ctx, currentBox)

        # ---- render commands for this element
        if not off:
          if el.isText:
            let cfg = el.textCfg
            let finalLH =
              if cfg.lineHeight > 0: float32(cfg.lineHeight) else: el.preferred.height
            var yPos = (finalLH - el.preferred.height) / 2   # vertical centering
            for lineIdx in 0 ..< el.lines.len:
              let line = el.lines[lineIdx]
              if line.length == 0:
                yPos += finalLH
              else:
                # NOTE: justify defaults to right in Clay; ported via explicit
                # cases so all three behave as documented.
                var offset = currentBox.width - line.dims.width
                case cfg.justify
                of justifyLeft: offset = 0
                of justifyCenter: offset = offset / 2
                of justifyRight: discard
                ctx.commands.add RenderCommand(
                  kind: renderText,
                  box: Rect(x: currentBox.x + offset, y: currentBox.y + yPos,
                            width: line.dims.width, height: line.dims.height),
                  id: hashNumber(uint32(lineIdx), el.id),
                  zIndex: root.zIndex,
                  userData: cfg.userData,
                  elementIndex: stack[topIdx].elementIndex, lineIndex: int32(lineIdx),
                  textColor: cfg.color, fontId: cfg.fontId, fontSize: cfg.fontSize,
                  letterSpacing: cfg.letterSpacing, lineHeight: uint16(finalLH))
                yPos += finalLH
                if ctx.cullingEnabled and currentBox.y + yPos > ctx.dims.height:
                  break
          else:
            let d = el.decl
            if d.overlay.a > 0:
              ctx.commands.add RenderCommand(
                kind: renderOverlayStart, box: currentBox, id: el.id,
                zIndex: root.zIndex, userData: d.userData, overlay: d.overlay)
            if d.image.data != nil:
              ctx.commands.add RenderCommand(
                kind: renderImage, box: currentBox, id: el.id,
                zIndex: root.zIndex, userData: d.userData,
                imageCorner: d.corner, imageData: d.image.data,
                imageTint: d.background)
            if d.custom.data != nil:
              ctx.commands.add RenderCommand(
                kind: renderCustom, box: currentBox, id: el.id,
                zIndex: root.zIndex, userData: d.userData,
                customData: d.custom.data, customCorner: d.corner,
                customBackground: d.background)
            if d.clip.horizontal or d.clip.vertical:
              ctx.commands.add RenderCommand(
                kind: renderClipStart, box: currentBox, id: el.id,
                zIndex: root.zIndex, userData: d.userData,
                clipHorizontal: d.clip.horizontal, clipVertical: d.clip.vertical)
            if d.background.a > 0:
              ctx.commands.add RenderCommand(
                kind: renderRectangle, box: currentBox, id: el.id,
                zIndex: root.zIndex, userData: d.userData,
                fill: d.background, rectCorner: d.corner)

        # ---- publish the bounding box for hit tests / next-frame attach
        var item = ctx.elementMap.getOrDefault(el.id, MapItem(elementIndex: -1))
        if item.elementIndex >= 0:
          item.box = currentBox
          ctx.elementMap[el.id] = item

        if not el.isText:

          # ---- main-axis justify: added once to the running child offset
          var content = Size()
          if layout.direction == leftToRight:
            for childIndex in el.children:
              let child = ctx.elements[childIndex]
              content.width += child.dims.width
              content.height = max(content.height, child.dims.height)
            content.width += float32(max(el.children.len - 1, 0) * layout.gap)
            var extra = el.dims.width -
              float32(layout.padding.left + layout.padding.right) - content.width
            case layout.align.x
            of left: extra = 0
            of centerX: extra = extra / 2
            of right: discard
            stack[topIdx].nextChildOffset.x += max(0, extra)
          else:
            for childIndex in el.children:
              let child = ctx.elements[childIndex]
              content.height += child.dims.height
              content.width = max(content.width, child.dims.width)
            content.height += float32(max(el.children.len - 1, 0) * layout.gap)
            var extra = el.dims.height -
              float32(layout.padding.top + layout.padding.bottom) - content.height
            case layout.align.y
            of top: extra = 0
            of centerY: extra = extra / 2
            of bottom: discard
            stack[topIdx].nextChildOffset.y += max(0, extra)

          if scrollIdx >= 0:
            ctx.scrollDatas[scrollIdx].contentSize = Size(
              width: content.width + float32(layout.padding.left + layout.padding.right),
              height: content.height + float32(layout.padding.top + layout.padding.bottom))

          # ---- push children in reverse so the stack pops them in order
          let n = el.children.len
          if n > 0:
            stack.setLen(stack.len + n)
            visited.setLen(visited.len + n)
            for i in 0 ..< n:
              let child = ctx.elements[el.children[i]]
              # Cross-axis alignment, recomputed per child (offset base reset).
              # NOTE: unlike main-axis justify, negative whitespace is kept --
              # an overflowing child is pushed outward.
              if layout.direction == leftToRight:
                stack[topIdx].nextChildOffset.y = float32(layout.padding.top)
                let white = el.dims.height -
                  float32(layout.padding.top + layout.padding.bottom) - child.dims.height
                case layout.align.y
                of top: discard
                of centerY: stack[topIdx].nextChildOffset.y += white / 2
                of bottom: stack[topIdx].nextChildOffset.y += white
              else:
                stack[topIdx].nextChildOffset.x = float32(layout.padding.left)
                let white = el.dims.width -
                  float32(layout.padding.left + layout.padding.right) - child.dims.width
                case layout.align.x
                of left: discard
                of centerX: stack[topIdx].nextChildOffset.x += white / 2
                of right: stack[topIdx].nextChildOffset.x += white
              let parent = stack[topIdx]
              stack[stack.high - i] = TreeNode(
                elementIndex: el.children[i],
                position: vec2(
                  parent.position.x + parent.nextChildOffset.x + scrollOffset.x,
                  parent.position.y + parent.nextChildOffset.y + scrollOffset.y),
                nextChildOffset: vec2(
                  float32(if not child.isText: child.decl.layout.padding.left else: 0),
                  float32(if not child.isText: child.decl.layout.padding.top else: 0)))
              visited[visited.high - i] = false
              if layout.direction == leftToRight:
                stack[topIdx].nextChildOffset.x += child.dims.width + float32(layout.gap)
              else:
                stack[topIdx].nextChildOffset.y += child.dims.height + float32(layout.gap)

    # close the floating subtree's scissor
    if root.clipElementId != 0:
      let clipItem = ctx.elementMap.getOrDefault(root.clipElementId, MapItem(elementIndex: -1))
      if clipItem.elementIndex >= 0 and not offscreen(ctx, clipItem.box):
        ctx.commands.add RenderCommand(
          kind: renderClipEnd,
          id: hashNumber(rootEl.id, uint32(rootEl.children.len + 11)))

proc pruneElementMap(ctx: Context) =
  ## Drop id-map entries that were not declared this frame.
  var dead = newSeq[uint32]()
  for id, item in ctx.elementMap:
    if item.generation <= ctx.generation:
      dead.add id
  for id in dead:
    ctx.elementMap.del(id)

## --- frame orchestration -------------------------------------------------------

proc initContext*(dims: Size): Context =
  ## Create a layout context for a root of `dims`. It becomes the current
  ## context; switch between several with `setCurrentContext`.
  result = Context(
    dims: dims,
    elements: @[], openStack: @[], clipStack: @[],
    roots: @[], commands: @[],
    elementMap: initTable[uint32, MapItem](),
    textCache: initTable[TextKey, Measurement](),
    scrollDatas: @[], pointerOver: @[], errors: @[],
    cullingEnabled: true,
  )
  setCurrentContext(result)

func measureTextInstalled*(ctx: Context): bool =
  ctx.measureText != nil

proc setLayoutDimensions*(ctx: Context; dims: Size) =
  ## Update the viewport size; takes effect next `beginLayout`.
  ctx.dims = dims

func layoutDimensions*(ctx: Context): Size =
  ctx.dims

proc setMeasureText*(ctx: Context; fn: MeasureFn) =
  ## Install the text measurement callback the engine uses for every word of
  ## every text element. Required before laying out text.
  ctx.measureText = fn

proc setScrollQuery*(ctx: Context; fn: proc(id: uint32): Vec2 {.closure.}) =
  ## Experimental: query scroll offsets from an external owner instead of
  ## letting Clay track them (pairs with `externalScrollHandling`).
  ctx.queryScrollOffset = fn

proc setExternalScrollHandling*(ctx: Context; enabled: bool) =
  ctx.externalScrollHandling = enabled

proc setCulling*(ctx: Context; enabled: bool) =
  ## When disabled, off-screen elements still emit render commands.
  ctx.cullingEnabled = enabled

proc takeErrors*(ctx: Context): seq[ErrorData] =
  ## Drain the error queue accumulated during this frame's layout.
  result = move(ctx.errors)
  ctx.errors = @[]

func openElementCount*(ctx: Context): int =
  max(ctx.openStack.len - 2, 0)

proc beginLayout*(ctx: Context) =
  ## Start a frame: resets the ephemeral state, advances the generation and
  ## opens the synthetic root container sized to `layoutDimensions`. Balance
  ## it with `endLayout` (or use the `clay` DSL between the two).
  ctx.generation += 1
  ctx.elements.setLen(0)
  ctx.openStack.setLen(0)
  ctx.clipStack.setLen(0)
  ctx.roots.setLen(0)
  ctx.commands.setLen(0)
  ctx.frameText.setLen(0)
  ctx.frameAspect.setLen(0)
  evictStaleMeasurements(ctx)

  let root = elementId(rootContainerLabel)
  var decl = ElementDeclaration(
    layout: LayoutConfig(
      sizing: Sizing(width: fixedPx(ctx.dims.width), height: fixedPx(ctx.dims.height))))
  openElement(ctx, root, decl)
  # Clay's BeginLayout keeps the root frame on the open stack twice (once for
  # the element itself, once for its "open scope"): first-level children then
  # attach when their close finds stack length > 1. Mirror that invariant.
  ctx.openStack.add(0)
  # The layout tree starts at element 0 (the synthetic root container).
  ctx.roots.add TreeRoot(elementIndex: 0)

proc endLayout*(ctx: Context) =
  ## Close the root, compute final geometry and produce render commands in
  ## `ctx.commands` (iterate with the `commands` iterator).
  closeElement(ctx)
  if ctx.openStack.len > 1:
    reportError(ctx, unbalancedOpenClose,
      "elements were left open at endLayout; they are not laid out")
    ctx.openStack.setLen(1)

  # Horizontal sizing -> text wrapping -> aspect ratio -> heights ->
  # vertical sizing -> aspect ratio, in Clay's order.
  sizeContainersAlongAxis(ctx, true)
  for textIdx in ctx.frameText:
    wrapTextElement(ctx, ctx.elements[textIdx])
  for aspectIdx in ctx.frameAspect:
    var el = ctx.elements[aspectIdx]
    el.dims.height = (1 / el.decl.aspectRatio) * el.dims.width
    el.decl.layout.sizing.height.max = el.dims.height
    ctx.elements[aspectIdx] = el
  propagateHeights(ctx)
  sizeContainersAlongAxis(ctx, false)
  for aspectIdx in ctx.frameAspect:
    var el = ctx.elements[aspectIdx]
    el.dims.width = el.decl.aspectRatio * el.dims.height
    ctx.elements[aspectIdx] = el

  sortRootsStable(ctx)
  positionAndEmit(ctx)
  pruneElementMap(ctx)

proc renderCommands*(ctx: Context): seq[RenderCommand] =
  ## The render commands produced by the last `endLayout`, in paint order.
  ## A shallow seq copy (refcounted): free to hand to a renderer; the
  ## commands stay valid until the next `beginLayout`.
  ctx.commands

proc lineText*(ctx: Context; cmd: RenderCommand): string =
  ## The text payload of a `renderText` command: the wrapped line slice of
  ## the owning element. Cheap view-ish helper that copies on demand.
  assert cmd.kind == renderText
  let el = ctx.elements[cmd.elementIndex]
  if el.lines.len == 0:
    return el.text
  let line = el.lines[cmd.lineIndex]
  sliceStr(el.text, line.start.int, line.length.int)
