## Pointer state, hover detection and scroll containers.
##
## Port of Clay's `Clay_SetPointerState` (including the inline hover-detection
## DFS), the pointer state machine, `Clay_UpdateScrollContainers` (wheel /
## drag / momentum scrolling) and the id-keyed query surface
## (`elementData`, `pointerOver`, `scrollContainerData`).
## These queries read the *previous* frame's published geometry: call them
## between `endLayout` and the next `beginLayout`, like Clay's examples do.
## This fragment is included by clay.nim; it must not import anything.

func pointInRect(p: Vec2; r: Rect): bool {.inline.} =
  p.x >= r.x and p.x <= r.x + r.width and p.y >= r.y and p.y <= r.y + r.height

proc setPointerState*(ctx: Context; position: Vec2; pointerDown: bool) =
  ## Store the pointer, rebuild the hover list against last frame's boxes,
  ## fire `onHover` callbacks, then advance the press/release state machine.
  ctx.pointer.position = position
  ctx.pointerOver.setLen(0)

  var stack: seq[tuple[idx: int32, visited: bool]] = @[]
  # Test topmost trees first: roots are processed in reverse declaration
  # order, so `pointerOver` fills outermost-of-topmost-first.
  for rootIndex in countdown(ctx.roots.high, 0):
    let root = ctx.roots[rootIndex]
    stack.setLen(0)
    stack.add((root.elementIndex, false))
    var found = false
    while stack.len > 0:
      let top = stack.high
      if stack[top].visited:
        stack.setLen(stack.len - 1)
      else:
        stack[top].visited = true
        let el = ctx.elements[stack[top].idx]
        let item = ctx.elementMap.getOrDefault(el.id, MapItem(elementIndex: -1))
        if item.elementIndex < 0 or item.generation <= ctx.generation:
          # Not declared this frame: prune the whole subtree.
          stack.setLen(stack.len - 1)
        else:
          var box = item.box
          var hit = pointInRect(position, box)
          if hit and el.clipId != 0:
            # Elements clipped away from the visible region don't receive the
            # pointer. With external scroll handling the engine doesn't know
            # the true visible region, so the host decides and we skip this.
            if not ctx.externalScrollHandling:
              let clipItem = ctx.elementMap.getOrDefault(el.clipId, MapItem(elementIndex: -1))
              hit = clipItem.elementIndex < 0 or pointInRect(position, clipItem.box)
          if hit:
            if item.hover != nil:
              item.hover(item.eid, ctx.pointer)
            ctx.pointerOver.add(item.eid)
            found = true
          # Clay keeps descending even past a miss: every descendant whose
          # own (clip-tested) box contains the point is registered.
          for i in countdown(el.children.high, 0):
            stack.add((el.children[i], false))
    let rootEl = ctx.elements[root.elementIndex]
    if found and isFloatingEl(rootEl) and
        rootEl.decl.floating.capture == capturePointer:
      # A captured floating root swallows pointer-over for every tree below.
      break

  # Press/release state machine (mirrors Clay's edge detection exactly).
  if pointerDown:
    if ctx.pointer.state == pressedThisFrame:
      ctx.pointer.state = pressed
    elif ctx.pointer.state != pressed:
      ctx.pointer.state = pressedThisFrame
  else:
    if ctx.pointer.state == releasedThisFrame:
      ctx.pointer.state = released
    elif ctx.pointer.state != released:
      ctx.pointer.state = releasedThisFrame

func pointerData*(ctx: Context): PointerData =
  ctx.pointer

func elementIdFromId*(id: uint32): ElementId =
  ## Rebuild a minimal id for callbacks (offset/base/label unavailable from
  ## the map; hover callbacks mostly compare `.id`).
  ElementId(id: id, offset: 0, baseId: id, label: "")

proc hovered*(ctx: Context): bool =
  ## Is the pointer inside the currently open element's last-frame box?
  ## Usable *inside* element declaration for hover-reactive colours.
  let el = ctx.elements[ctx.openStack[^1]]
  for over in ctx.pointerOver:
    if over.id == el.id:
      return true
  return false

proc pointerOver*(ctx: Context; id: ElementId): bool =
  for over in ctx.pointerOver:
    if over.id == id.id:
      return true
  return false

proc onHover*(ctx: Context; cb: HoverCallback) =
  ## Bind a callback fired every frame (from `setPointerState`) while the
  ## pointer is over the currently open element. Rebind it every frame --
  ## rebinding happens when the id map entry is refreshed.
  let openId = ctx.elements[ctx.openStack[^1]].id
  var item = ctx.elementMap.getOrDefault(openId, MapItem(elementIndex: -1))
  if item.elementIndex >= 0:
    item.hover = cb
    ctx.elementMap[openId] = item

func pointerOverIds*(ctx: Context): seq[ElementId] =
  ctx.pointerOver

## --- scroll containers -------------------------------------------------------------

proc currentScrollOffset*(ctx: Context): Vec2 =
  ## The scroll position of the enclosing scroll container, read *during*
  ## declaration to feed `withClip(..., childOffset = currentScrollOffset())`.
  ## Clay does this with `Clay_GetScrollOffset()` inside `CLAY(...)`.
  if ctx.openStack.len == 0:
    return Vec2()
  let openEl = ctx.elements[ctx.openStack[^1]]
  for sd in ctx.scrollDatas:
    if sd.elementId == openEl.id:
      return sd.position
  return Vec2()

proc updateScrollContainers*(ctx: Context; dragScrolling: bool;
                             scrollDelta: Vec2; deltaTime: float32) =
  ## Advance every scroll container: wheel deltas, pointer drag, momentum and
  ## clamping. Call once per frame with the accumulated wheel/touch delta.
  let pointerActive = dragScrolling and
    (ctx.pointer.state == pressed or ctx.pointer.state == pressedThisFrame)

  var bestIdx = -1
  var bestPriority = -1

  var i = 0
  while i < ctx.scrollDatas.len:
    var sd = ctx.scrollDatas[i]
    let alive = sd.elementIndex.int < ctx.elements.len and
      ctx.elements[sd.elementIndex].gen == sd.elementGen
    if not sd.openThisFrame or not alive:
      # Container not declared this frame: its state is dead -- cull.
      # (The swapped-in entry is examined on the next iteration.)
      let last = ctx.scrollDatas[^1]
      ctx.scrollDatas[i] = last
      ctx.scrollDatas.setLen(ctx.scrollDatas.len - 1)
    else:
      sd.openThisFrame = false
      let el = ctx.elements[sd.elementIndex]
      let content = sd.contentSize

      # Drag released: convert the recent drag gesture into momentum. NOTE:
      # Clay divides by `momentumTime * 25` unguarded (0 -> inf); a
      # stationary release simply produces no momentum here.
      if not pointerActive and sd.pointerScrollActive:
        let dx = sd.position.x - sd.scrollOrigin.x
        let dy = sd.position.y - sd.scrollOrigin.y
        if (dx < -10 or dx > 10) and sd.momentumTime > 0:
          sd.momentum.x = dx / (sd.momentumTime * 25)
        if (dy < -10 or dy > 10) and sd.momentumTime > 0:
          sd.momentum.y = dy / (sd.momentumTime * 25)
        sd.pointerScrollActive = false
        sd.pointerOrigin = Vec2()
        sd.scrollOrigin = Vec2()
        sd.momentumTime = 0

      let scrolled = scrollDelta.x != 0 or scrollDelta.y != 0

      sd.position.x += sd.momentum.x
      sd.momentum.x *= 0.95'f32
      if (sd.momentum.x > -0.1'f32 and sd.momentum.x < 0.1'f32) or scrolled:
        sd.momentum.x = 0
      sd.position.x = min(max(sd.position.x,
        -max(content.width - el.dims.width, 0)), 0)

      sd.position.y += sd.momentum.y
      sd.momentum.y *= 0.95'f32
      if (sd.momentum.y > -0.1'f32 and sd.momentum.y < 0.1'f32) or scrolled:
        sd.momentum.y = 0
      sd.position.y = min(max(sd.position.y,
        -max(content.height - el.dims.height, 0)), 0)

      # Deepest hovered container wins the scroll input (pointerOver ids
      # are ordered ancestor-first).
      for j, over in ctx.pointerOver:
        if sd.elementId == over.id:
          if j > bestPriority:
            bestPriority = j
            bestIdx = i

      ctx.scrollDatas[i] = sd
      inc i

  if bestIdx < 0:
    return
  var sd = ctx.scrollDatas[bestIdx]
  let el = ctx.elements[sd.elementIndex]
  let clip = el.decl.clip
  let canX = clip.horizontal and sd.contentSize.width > el.dims.width
  let canY = clip.vertical and sd.contentSize.height > el.dims.height

  # Wheel / trackpad: Clay scales raw deltas by 10.
  if canY:
    sd.position.y = sd.position.y + scrollDelta.y * 10
  if canX:
    sd.position.x = sd.position.x + scrollDelta.x * 10

  if pointerActive:
    sd.momentum = Vec2()
    if not sd.pointerScrollActive:
      sd.pointerOrigin = ctx.pointer.position
      sd.scrollOrigin = sd.position
      sd.pointerScrollActive = true
    else:
      var deltaX: float32 = 0
      var deltaY: float32 = 0
      if canX:
        let old = sd.position.x
        sd.position.x = sd.scrollOrigin.x +
          (ctx.pointer.position.x - sd.pointerOrigin.x)
        sd.position.x = max(min(sd.position.x, 0),
          -(sd.contentSize.width - sd.box.width))
        deltaX = sd.position.x - old
      if canY:
        let old = sd.position.y
        sd.position.y = sd.scrollOrigin.y +
          (ctx.pointer.position.y - sd.pointerOrigin.y)
        sd.position.y = max(min(sd.position.y, 0),
          -(sd.contentSize.height - sd.box.height))
        deltaY = sd.position.y - old
      # A held-still pointer restarts the gesture baseline so momentum after
      # release reflects the flick, not the pause.
      if deltaX > -0.1'f32 and deltaX < 0.1'f32 and deltaY > -0.1'f32 and deltaY < 0.1'f32 and
          sd.momentumTime > 0.15'f32:
        sd.momentumTime = 0
        sd.pointerOrigin = ctx.pointer.position
        sd.scrollOrigin = sd.position
      else:
        sd.momentumTime += deltaTime

  if canY:
    sd.position.y = max(min(sd.position.y, 0),
      -(sd.contentSize.height - el.dims.height))
  if canX:
    sd.position.x = max(min(sd.position.x, 0),
      -(sd.contentSize.width - el.dims.width))

  ctx.scrollDatas[bestIdx] = sd

proc scrollContainerData*(ctx: Context; id: ElementId): ScrollContainerData =
  ## Query a scroll container by id. `position` mirrors the engine's state;
  ## mutate through `setScrollPosition`.
  for sd in ctx.scrollDatas:
    if sd.elementId == id.id:
      if sd.elementIndex.int >= ctx.elements.len or
          ctx.elements[sd.elementIndex].gen != sd.elementGen:
        return ScrollContainerData(found: false)
      let el = ctx.elements[sd.elementIndex]
      return ScrollContainerData(
        position: sd.position,
        containerDimensions: size(sd.box.width, sd.box.height),
        contentDimensions: sd.contentSize,
        childOffset: el.decl.clip.childOffset,
        horizontal: el.decl.clip.horizontal,
        vertical: el.decl.clip.vertical,
        found: true)
  return ScrollContainerData(found: false)

proc setScrollPosition*(ctx: Context; id: ElementId; position: Vec2) =
  ## Externally drive a scroll container's position (scrollbars, auto-scroll
  ## to a focused item). Clamped against last frame's content size.
  for i in 0 ..< ctx.scrollDatas.len:
    let sd = ctx.scrollDatas[i]
    if sd.elementId == id.id:
      let el = ctx.elements[sd.elementIndex]
      var p = position
      if el.decl.clip.vertical:
        p.y = max(min(p.y, 0), -(sd.contentSize.height - el.dims.height))
      else:
        p.y = 0
      if el.decl.clip.horizontal:
        p.x = max(min(p.x, 0), -(sd.contentSize.width - el.dims.width))
      else:
        p.x = 0
      ctx.scrollDatas[i].position = p
      ctx.scrollDatas[i].momentum = Vec2()
      break

## --- element queries ---------------------------------------------------------------

proc elementData*(ctx: Context; id: ElementId): ElementData =
  ## The bounding box published during the last completed layout pass.
  ## NOTE: Clay returns whatever the map holds even if the element vanished
  ## a frame ago; we keep the same lenient behaviour but report `found` only
  ## for entries that are alive this frame.
  let item = ctx.elementMap.getOrDefault(id.id, MapItem(elementIndex: -1))
  if item.elementIndex < 0:
    return ElementData(found: false)
  ElementData(box: item.box, found: true)

func openElementId*(ctx: Context): uint32 =
  ## The id of the innermost open element -- the seed for `localId`.
  ctx.elements[ctx.openStack[^1]].id

func localId*(label: string; seed: uint32): ElementId =
  ## Hash `label` relative to `seed` -- typically `openElementId(ctx)` -- so
  ## repeated subtrees get collision-free ids without string building. This
  ## is Clay's `CLAY_SID_LOCAL` / `CLAY_ID_LOCAL`.
  let h = hashString(label, seed)
  ElementId(id: h, offset: 0, baseId: h, label: label)

func localIdWithIndex*(label: string; index: uint32; seed: uint32): ElementId =
  ## Clay's `CLAY_SIDI_LOCAL` / `CLAY_IDI_LOCAL`.
  ElementId(
    id: hashStringWithOffset(label, index, seed),
    offset: index,
    baseId: hashString(label, seed),
    label: label)
