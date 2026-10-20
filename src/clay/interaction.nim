## Pointer state, hover detection and scroll containers.
##
## Port of Clay's `Clay_SetPointerState` (including the inline hover-detection
## DFS), the pointer state machine, `Clay_UpdateScrollContainers` (wheel /
## drag / momentum scrolling with a spring-damped position follower and
## rubber-banded bounds) and the id-keyed query surface
## (`elementData`, `pointerOver`, `scrollContainerData`).
## These queries read the *previous* frame's published geometry: call them
## between `endLayout` and the next `beginLayout`, like Clay's examples do.
## This fragment is included by clay.nim; it must not import anything.

func pointInRect(p: Vec2; r: Rect): bool {.inline.} =
  p.x >= r.x and p.x <= r.x + r.width and p.y >= r.y and p.y <= r.y + r.height

proc hitTest*(ctx: Context; position: Vec2; fire = false): seq[ElementId] =
  ## The elements under `position` in last frame's published geometry, in
  ## `pointerOver` order (outermost-of-topmost first). `fire` runs their
  ## `onHover` callbacks on the way -- `setPointerState` does; the frame
  ## pacer's motion filter asks without side effects.
  result = @[]
  var stack: seq[tuple[idx: int32, visited: bool]] = @[]
  # Test topmost trees first: roots are processed in reverse declaration
  # order, so the result fills outermost-of-topmost-first.
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
            if fire and item.hover != nil:
              item.hover(item.eid, ctx.pointer)
            result.add(item.eid)
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

proc hoverChangesAt*(ctx: Context; position: Vec2): bool =
  ## Would moving the pointer to `position` change what it is over?
  let ids = hitTest(ctx, position)
  if ids.len != ctx.pointerOver.len:
    return true
  for i in 0 ..< ids.len:
    if ids[i].id != ctx.pointerOver[i].id:
      return true
  return false

proc setPointerState*(ctx: Context; position: Vec2; pointerDown: bool) =
  ## Store the pointer, rebuild the hover list against last frame's boxes,
  ## fire `onHover` callbacks, then advance the press/release state machine.
  ctx.pointer.position = position
  ctx.pointerOver = hitTest(ctx, position, fire = true)

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

const
  springK* = 420.0'f32   ## spring stiffness of the position->target follower
  springC* = 34.0'f32    ## damping: slightly underdamped -> springy landings
  SettleDist = 0.05'f32  ## px: the spring is home ...
  SettleVel = 0.5'f32    ## px/s: ... and at rest
  rubberResist* = 0.35'f32  ## how much of a drag past an edge reaches the target

func springStep(pos, vel, target, dt: float32): (float32, float32) =
  ## One explicit-Euler step of a damped spring pulling `pos` toward `target`.
  ## Snaps to rest when the residual motion is sub-pixel.
  let d = target - pos
  if d > -0.05'f32 and d < 0.05'f32 and vel > -0.5'f32 and vel < 0.5'f32:
    return (target, 0.0)
  let acc = d * springK - vel * springC
  let v = vel + acc * dt
  (pos + v * dt, v)

func rubber(v, lo, hi: float32): float32 =
  ## Soft-clamp: motion past an edge is resisted, so a held drag inflates the
  ## target a little; releasing lets the spring snap it back -- the bounce.
  if v > hi: hi + (v - hi) * rubberResist
  elif v < lo: lo + (v - lo) * rubberResist
  else: v

proc currentScrollOffset*(ctx: Context): Vec2 =
  ## The scroll position of the enclosing scroll container, read *during*
  ## declaration to feed `clip(..., childOffset = currentScrollOffset())`.
  ## Clay does this with `Clay_GetScrollOffset()` inside `CLAY(...)`. The
  ## offset comes in whole pixels: the glide keeps its fraction, but the
  ## contents land on the pixel grid, so a scroll moves them by whole rows
  ## a renderer can shift instead of painting anew.
  if ctx.openStack.len == 0:
    return Vec2()
  let openEl = ctx.elements[ctx.openStack[^1]]
  for sd in ctx.scrollDatas:
    if sd.elementId == openEl.id:
      return Vec2(x: round(sd.position.x), y: round(sd.position.y))
  return Vec2()

proc updateScrollContainers*(ctx: Context; dragScrolling: bool;
                             scrollDelta: Vec2; deltaTime: float32) =
  ## Advance every scroll container: wheel deltas, pointer drag, momentum and
  ## springy bounds. Call once per frame with the accumulated wheel/touch
  ## delta. `target` takes the raw input (drag inflates past the edges with
  ## rubber resistance); `position` -- what `currentScrollOffset` publishes
  ## to layout -- trails it on a damped spring, which supplies the glide,
  ## the deceleration and the small overshoot-and-settle at the edges.
  let pointerActive = dragScrolling and
    (ctx.pointer.state == pressed or ctx.pointer.state == pressedThisFrame)

  # --- pass 1: cull dead containers, retire released drags into momentum,
  # and find the container that owns this frame's scroll input.
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

      # Drag released: convert the recent drag gesture into momentum. NOTE:
      # Clay divides by `momentumTime * 25` unguarded (0 -> inf); a
      # stationary release simply produces no momentum here.
      if not pointerActive and sd.pointerScrollActive:
        let dx = sd.target.x - sd.scrollOrigin.x
        let dy = sd.target.y - sd.scrollOrigin.y
        if (dx < -10 or dx > 10) and sd.momentumTime > 0:
          sd.momentum.x = dx / (sd.momentumTime * 25)
        if (dy < -10 or dy > 10) and sd.momentumTime > 0:
          sd.momentum.y = dy / (sd.momentumTime * 25)
        sd.pointerScrollActive = false
        sd.pointerOrigin = Vec2()
        sd.scrollOrigin = Vec2()
        sd.momentumTime = 0

      # Deepest hovered container wins the scroll input (pointerOver ids
      # are ordered ancestor-first).
      for j, over in ctx.pointerOver:
        if sd.elementId == over.id:
          if j > bestPriority:
            bestPriority = j
            bestIdx = i

      ctx.scrollDatas[i] = sd
      inc i

  # --- pass 2: apply input to the focused container, then integrate.
  let scrolled = scrollDelta.x != 0 or scrollDelta.y != 0
  for k in 0 ..< ctx.scrollDatas.len:
    var sd = ctx.scrollDatas[k]
    let el = ctx.elements[sd.elementIndex]
    let content = sd.contentSize
    let canX = el.decl.clip.horizontal and content.width > el.dims.width
    let canY = el.decl.clip.vertical and content.height > el.dims.height
    let loX = -max(content.width - el.dims.width, 0)
    let loY = -max(content.height - el.dims.height, 0)

    if k == bestIdx:
      # Wheel / trackpad: Clay scales raw deltas by 10.
      if canY and scrolled:
        sd.target.y += scrollDelta.y * 10
        sd.momentum.y = 0
      if canX and scrolled:
        sd.target.x += scrollDelta.x * 10
        sd.momentum.x = 0

      if pointerActive:
        if not sd.pointerScrollActive:
          sd.pointerOrigin = ctx.pointer.position
          sd.scrollOrigin = sd.target
          sd.pointerScrollActive = true
        else:
          var dx: float32 = 0
          var dy: float32 = 0
          if canX:
            let old = sd.target.x
            sd.target.x = rubber(sd.scrollOrigin.x +
              (ctx.pointer.position.x - sd.pointerOrigin.x), loX, 0)
            dx = sd.target.x - old
          if canY:
            let old = sd.target.y
            sd.target.y = rubber(sd.scrollOrigin.y +
              (ctx.pointer.position.y - sd.pointerOrigin.y), loY, 0)
            dy = sd.target.y - old
          # A held-still pointer restarts the gesture baseline so momentum
          # after release reflects the flick, not the pause.
          if dx > -0.1'f32 and dx < 0.1'f32 and dy > -0.1'f32 and dy < 0.1'f32 and
              sd.momentumTime > 0.15'f32:
            sd.momentumTime = 0
            sd.pointerOrigin = ctx.pointer.position
            sd.scrollOrigin = sd.target
          else:
            sd.momentumTime += deltaTime

    # Flick momentum keeps driving the target until it comes to rest. Clay's
    # constants are per 60 Hz frame; `steps` rescales them to `deltaTime`
    # so a flick travels as far at 144 Hz (or 20 Hz) as at 60.
    let steps = deltaTime * 60.0'f32
    let decay = pow(0.95'f32, steps)
    sd.target.x += sd.momentum.x * steps
    sd.momentum.x *= decay
    if sd.momentum.x > -0.1'f32 and sd.momentum.x < 0.1'f32:
      sd.momentum.x = 0
    sd.target.y += sd.momentum.y * steps
    sd.momentum.y *= decay
    if sd.momentum.y > -0.1'f32 and sd.momentum.y < 0.1'f32:
      sd.momentum.y = 0

    # The target itself only leaves the track during a live rubber drag;
    # every other path snaps it back to the hard edge, and the spring makes
    # the visible position bounce on the way home.
    let rubberHeld = k == bestIdx and pointerActive and sd.pointerScrollActive
    if canY:
      if not rubberHeld:
        sd.target.y = min(max(sd.target.y, loY), 0)
    else:
      sd.target.y = 0
    if canX:
      if not rubberHeld:
        sd.target.x = min(max(sd.target.x, loX), 0)
    else:
      sd.target.x = 0

    # Position rides the spring toward the target: this is the deceleration
    # of a flick and the overshoot-and-settle at the ends.
    # Explicit Euler is only stable for small steps: integrate long frames
    # (a 30 Hz display, a hitch) in sub-steps of at most 1/120 s.
    var sub = 1
    while deltaTime / float32(sub) > 1.0'f32 / 120.0'f32 and sub < 8:
      inc sub
    let h = deltaTime / float32(sub)
    var n = 0
    while n < sub:
      let (ny, vys) = springStep(sd.position.y, sd.springVel.y, sd.target.y, h)
      sd.position.y = ny
      sd.springVel.y = vys
      let (nx, vxs) = springStep(sd.position.x, sd.springVel.x, sd.target.x, h)
      sd.position.x = nx
      sd.springVel.x = vxs
      inc n
    # Close enough and slow enough: land exactly, so the container reports
    # rest and the frame pacer can stop asking for frames.
    if abs(sd.position.y - sd.target.y) < SettleDist and
        abs(sd.springVel.y) < SettleVel:
      sd.position.y = sd.target.y
      sd.springVel.y = 0
    if abs(sd.position.x - sd.target.x) < SettleDist and
        abs(sd.springVel.x) < SettleVel:
      sd.position.x = sd.target.x
      sd.springVel.x = 0

    ctx.scrollDatas[k] = sd

proc scrollAnimating*(ctx: Context): bool =
  ## Some scroll container is still moving on its own (flick momentum, the
  ## spring settling, a held rubber drag): it needs more frames.
  for sd in ctx.scrollDatas:
    if sd.momentum.x != 0 or sd.momentum.y != 0 or
        sd.position.x != sd.target.x or sd.position.y != sd.target.y or
        sd.springVel.x != 0 or sd.springVel.y != 0:
      return true
  return false

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
  ## to a focused item). Direct: both the spring target and the visible
  ## position snap, so a held scrollbar drag tracks the pointer 1:1.
  ## Clamped against last frame's content size and viewport box -- not the
  ## element's live dims, which are still unsized when a widget calls this
  ## mid-declaration.
  for i in 0 ..< ctx.scrollDatas.len:
    let sd = ctx.scrollDatas[i]
    if sd.elementId == id.id:
      let el = ctx.elements[sd.elementIndex]
      var p = position
      if el.decl.clip.vertical:
        p.y = max(min(p.y, 0), -max(sd.contentSize.height - sd.box.height, 0))
      else:
        p.y = 0
      if el.decl.clip.horizontal:
        p.x = max(min(p.x, 0), -max(sd.contentSize.width - sd.box.width, 0))
      else:
        p.x = 0
      ctx.scrollDatas[i].position = p
      ctx.scrollDatas[i].target = p
      ctx.scrollDatas[i].springVel = Vec2()
      ctx.scrollDatas[i].momentum = Vec2()
      ctx.scrollDatas[i].pointerScrollActive = false
      ctx.scrollDatas[i].momentumTime = 0
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

func enclosingZIndex*(ctx: Context): int16 =
  ## The `zIndex` of the innermost open floating element, 0 outside any --
  ## so a floating child can stack relative to the layer it is declared
  ## in (a scrollbar inside a modal panel, say) instead of a fixed number.
  result = 0
  for i in countdown(ctx.openStack.high, 0):
    let el = ctx.elements[ctx.openStack[i]]
    if isFloatingEl(el):
      return el.decl.floating.zIndex

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
