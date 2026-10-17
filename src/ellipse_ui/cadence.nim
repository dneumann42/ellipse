## Widget cadences: how often each part of the UI refreshes. See
## `documentation/nim-tutorial.md` §11 (Cadence, animation and the frame
## loop).

import std/[tables, math]

import clay
import ellipse/platform/pacing
import ./events

export pacing.Cadence, pacing.everyFrame, pacing.every, pacing.onInput,
  pacing.onHover, pacing.whileHovered, pacing.requestFrame,
  pacing.requestFrameAt, pacing.requestFrameIn, pacing.trackPointer,
  pacing.wake, pacing.frameDelta, pacing.frameNow, pacing.frameWall,
  pacing.resizing, pacing.resizeStarted, pacing.resizeFinished

proc mix(a, b: uint64): uint64 =
  var z = (a xor b) + 0x9E3779B97F4A7C15'u64
  z = (z xor (z shr 30)) * 0xBF58476D1CE4E5B9'u64
  z = (z xor (z shr 27)) * 0x94D049BB133111EB'u64
  z xor (z shr 31)

proc labelHash(label: string): uint64 =
  result = 0xCBF29CE484222325'u64
  for ch in label:
    result = (result xor uint64(ord(ch))) * 0x100000001B3'u64

type
  GuardCount = object
    gen: uint32
    n: uint64

var guardCounts: Table[uint64, GuardCount]

proc nextGuardKey(owner: uint64): uint64 =
  ## The n-th unlabelled guard of `owner` this frame.
  let gen = currentContext().generation
  var c = guardCounts.getOrDefault(owner)
  if c.gen != gen:
    c = GuardCount(gen: gen, n: 0)
  inc c.n
  guardCounts[owner] = c
  mix(owner, c.n)

proc currentOwner(): uint64 = uint64(currentWidgetKey())

proc refreshDue*(c: Cadence): bool =
  ## The `refresh` guard, hovering on the open element.
  let owner = currentOwner()
  refreshDue(nextGuardKey(owner), owner, c, c.hoverSet and hovered())

proc refreshDue*(c: Cadence; hoverId: ElementId): bool =
  ## The `refresh` guard, hovering on `hoverId`.
  let owner = currentOwner()
  refreshDue(nextGuardKey(owner), owner, c, c.hoverSet and pointerOver(hoverId))

proc refreshDue*(label: string; c: Cadence): bool =
  ## A labelled guard: stable however many guards precede it, and reachable
  ## from outside the UI with `invalidate(label)`.
  let owner = currentOwner()
  let tag = labelHash(label)
  refreshDue(mix(owner, tag), owner, c, c.hoverSet and hovered(), tag)

template refresh*(c: Cadence; body: untyped) =
  ## Run `body` when cadence `c` is due (see the module header).
  if refreshDue(c):
    body

template refresh*(c: Cadence; hoverId: ElementId; body: untyped) =
  if refreshDue(c, hoverId):
    body

template refresh*(label: string; c: Cadence; body: untyped) =
  if refreshDue(label, c):
    body

proc invalidate*(label: string) =
  ## Make every guard labelled `label` due in the next frame -- and run that
  ## frame. Data that changed outside the UI (a WM event, a socket) lands
  ## here instead of being polled every frame:
  ##
  ##   widget Title():
  ##     refresh "title", onInput():
  ##       titleText = wm.focusedTitle()
  ##     text(titleText)
  ##
  ##   proc onWmFocusChanged() = invalidate("title")
  invalidateTag(labelHash(label))

proc invalidate*(key: WidgetKey) =
  ## Make every guard of widget `key` due in the next frame.
  invalidateOwner(uint64(key))

proc invalidate*() =
  ## `invalidate` for the widget whose body is running.
  invalidateOwner(currentOwner())

## --- animation ---------------------------------------------------------------

type
  Anim = object
    value: float32
    seen: int64

var
  anims: Table[uint64, Anim]
  animSweep = 0'i64

proc sweepAnims() =
  if frameIndex() - animSweep < 600:
    return
  animSweep = frameIndex()
  var dead: seq[uint64] = @[]
  for k, a in anims:
    if frameIndex() - a.seen > 600:
      dead.add k
  for k in dead:
    anims.del k

proc approachKey(key: uint64; target: float32; rate: float32): float32 =
  sweepAnims()
  var a = anims.getOrDefault(key, Anim(value: target, seen: -1))
  if a.seen < 0:
    a.value = target          # first sight: start at rest, no fade-in
  elif a.value != target:
    a.value += (target - a.value) * (1.0'f32 - exp(-rate * frameDelta()))
    if abs(target - a.value) < 0.002'f32:
      a.value = target
    else:
      requestFrame()
  a.seen = frameIndex()
  anims[key] = a
  a.value

proc approach*(id: ElementId; target: float32; rate = 14.0'f32;
               slot = 0'u32): float32 =
  ## Ease toward `target` (exponentially, `rate` per second) and return the
  ## current value, asking for frames until it arrives. One value per
  ## (`id`, `slot`); first sight starts at the target.
  ##
  ##   let t = approach(id, if over: 1.0 else: 0.0)
  ##   .bg(lerp(idle, hover, t))
  approachKey(mix(uint64(id.id), uint64(slot) + 1), target, rate)

proc approach*(id: ElementId; target: Color; rate = 14.0'f32;
               slot = 0'u32): Color =
  ## `approach` per channel.
  let base = slot * 4'u32 + 1000'u32
  Color(r: approach(id, target.r, rate, base),
        g: approach(id, target.g, rate, base + 1),
        b: approach(id, target.b, rate, base + 2),
        a: approach(id, target.a, rate, base + 3))
