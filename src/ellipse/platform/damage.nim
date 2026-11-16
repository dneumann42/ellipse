## Damage tracking: which pixels changed between two frames' render commands.
##
## Immediate mode rebuilds the command list every frame, but most frames
## change a handful of commands -- the clock's text, one hovered row. The
## renderer keeps last frame's picture in a texture and repaints only the
## damaged rectangles; a frame whose commands are identical paints nothing
## and does not present at all.
##
## Each command is reduced to a `CmdSig`: a key (owning element id, command
## kind, occurrence of that pair) and a hash of everything that reaches the
## pixels (box, colours, corners, border widths, text, z). Diffing matches
## keys; changed, added and removed commands damage their old and new boxes.
## The cases a box-local repaint cannot express -- clip regions appearing,
## vanishing or moving, or commands swapping paint order -- fall back to a
## full repaint.
##
## A scrolled clip region is the exception that matters most: every command
## inside it moved, which would damage all of it. When the diff may `shift`
## (the renderer can move its own pixels) and the commands of one clip
## region moved together by a whole number of rows, the damage carries a
## `Scroll` instead: the renderer shifts the region's pixels and repaints
## only the rows it uncovered, plus whatever changed besides the move.

import std/tables

import clay

type
  CmdSig* = object
    key*: uint64
    hash*: uint64
    shape*: uint64    ## `hash` without the box's position: equal when moved
    box*: Rect
    isClip*: bool     ## clip / overlay bracket: structure, not paint
    kind*: RenderKind
    reach*: float32   ## how far in from its box edges it is not uniform

  DamageKind* = enum
    dmgNone, dmgRects, dmgFull

  Damage* = object
    kind*: DamageKind
    rects*: seq[Rect]   ## dmgRects: disjoint-ish areas to repaint
    scroll*: Scroll     ## dmgRects: when `scroll.dy` is not 0, first shift

  Scroll* = object
    ## Pixels that only moved: shift the rows of `area` by `dy` (down when
    ## positive), dropping what leaves it, before painting the damage.
    area*: Rect
    dy*: float32

const
  MaxRects = 12         ## more separate areas than this merge into one
  MergeSlack = 1.25     ## touching areas merge while their box costs this
  Bleed = 2.0'f32       ## antialias feathering past a command's box
  FullFraction = 0.6    ## damage covering more than this: repaint it all

proc fnv(h: var uint64; v: uint64) {.inline.} =
  var x = v
  var i = 0
  while i < 8:
    h = (h xor (x and 0xFF'u64)) * 0x100000001B3'u64
    x = x shr 8
    inc i

proc mixF(h: var uint64; f: float32) {.inline.} =
  fnv(h, uint64(cast[uint32](f)))

proc mixColor(h: var uint64; c: Color) =
  mixF(h, c.r)
  mixF(h, c.g)
  mixF(h, c.b)
  mixF(h, c.a)

proc mixCorner(h: var uint64; c: CornerRadius) =
  mixF(h, c.topLeft)
  mixF(h, c.topRight)
  mixF(h, c.bottomLeft)
  mixF(h, c.bottomRight)

proc mixStr(h: var uint64; s: string) =
  fnv(h, uint64(s.len))
  for ch in s:
    h = (h xor uint64(ord(ch))) * 0x100000001B3'u64

proc shapeSignature(cmd: RenderCommand; text: string): uint64 =
  ## Hash of everything in `cmd` that reaches the pixels but where its box
  ## stands; `text` is the command's line for `renderText` (ignored
  ## otherwise).
  result = 0xCBF29CE484222325'u64
  fnv(result, uint64(ord(cmd.kind)))
  mixF(result, cmd.box.width)
  mixF(result, cmd.box.height)
  fnv(result, uint64(cast[uint16](cmd.zIndex)))
  case cmd.kind
  of renderRectangle:
    mixColor(result, cmd.fill)
    mixCorner(result, cmd.rectCorner)
  of renderBorder:
    mixColor(result, cmd.borderColor)
    mixCorner(result, cmd.borderCorner)
    fnv(result, uint64(cmd.borderWidth.left))
    fnv(result, uint64(cmd.borderWidth.right))
    fnv(result, uint64(cmd.borderWidth.top))
    fnv(result, uint64(cmd.borderWidth.bottom))
  of renderText:
    mixColor(result, cmd.textColor)
    fnv(result, uint64(cmd.fontId))
    fnv(result, uint64(cmd.fontSize))
    fnv(result, uint64(cmd.letterSpacing))
    fnv(result, uint64(cmd.lineHeight))
    mixStr(result, text)
  of renderImage:
    mixCorner(result, cmd.imageCorner)
    mixColor(result, cmd.imageTint)
    fnv(result, cast[uint64](cmd.imageData))
  of renderCustom:
    mixCorner(result, cmd.customCorner)
    mixColor(result, cmd.customBackground)
    fnv(result, cast[uint64](cmd.customData))
    fnv(result, cmd.customVersion)
  of renderClipStart:
    fnv(result, uint64(ord(cmd.clipHorizontal)))
    fnv(result, uint64(ord(cmd.clipVertical)))
  of renderOverlayStart:
    mixColor(result, cmd.overlay)
  of renderClipEnd, renderOverlayEnd:
    discard

proc placed(shape: uint64; box: Rect): uint64 =
  ## `shape` with the box's position mixed in: the full signature.
  result = shape
  mixF(result, box.x)
  mixF(result, box.y)

proc signature*(cmd: RenderCommand; text: string): uint64 =
  ## Hash of everything in `cmd` that reaches the pixels; `text` is the
  ## command's line for `renderText` (ignored otherwise).
  placed(shapeSignature(cmd, text), cmd.box)

proc reachOf(cmd: RenderCommand): float32 =
  ## How far in from its box a fill or border stops being one flat colour
  ## along its edges: the corner radii and the border widths.
  case cmd.kind
  of renderRectangle:
    let c = cmd.rectCorner
    max(max(c.topLeft, c.topRight), max(c.bottomLeft, c.bottomRight))
  of renderBorder:
    let c = cmd.borderCorner
    let w = cmd.borderWidth
    max(max(max(c.topLeft, c.topRight), max(c.bottomLeft, c.bottomRight)),
        float32(max(max(w.left, w.right), max(w.top, w.bottom))))
  else:
    max(cmd.box.width, cmd.box.height)

proc isBracket(k: RenderKind): bool =
  k == renderClipStart or k == renderClipEnd or
    k == renderOverlayStart or k == renderOverlayEnd

type
  SigBuilder* = object
    ## Assigns occurrence numbers so several commands of one element (fill,
    ## border, its text lines) get distinct, stable keys.
    seen: Table[uint64, uint32]
    sigs*: seq[CmdSig]

proc add*(b: var SigBuilder; cmd: RenderCommand; text: string) =
  let base = (uint64(cmd.id) shl 32) or (uint64(ord(cmd.kind)) shl 24)
  let occ = b.seen.getOrDefault(base, 0'u32)
  b.seen[base] = occ + 1
  let shape = shapeSignature(cmd, text)
  b.sigs.add CmdSig(key: base or uint64(occ and 0xFFFFFF'u32),
                    hash: placed(shape, cmd.box), shape: shape, box: cmd.box,
                    isClip: isBracket(cmd.kind), kind: cmd.kind,
                    reach: reachOf(cmd))

## --- rect helpers -------------------------------------------------------------

proc empty(r: Rect): bool {.inline.} =
  r.width <= 0.0 or r.height <= 0.0

proc union*(a, b: Rect): Rect =
  if empty(a): return b
  if empty(b): return a
  let x0 = min(a.x, b.x)
  let y0 = min(a.y, b.y)
  let x1 = max(a.x + a.width, b.x + b.width)
  let y1 = max(a.y + a.height, b.y + b.height)
  rect(x0, y0, x1 - x0, y1 - y0)

proc intersect*(a, b: Rect): Rect =
  let x0 = max(a.x, b.x)
  let y0 = max(a.y, b.y)
  let x1 = min(a.x + a.width, b.x + b.width)
  let y1 = min(a.y + a.height, b.y + b.height)
  if x1 <= x0 or y1 <= y0:
    return rect(0, 0, 0, 0)
  rect(x0, y0, x1 - x0, y1 - y0)

proc overlaps*(a, b: Rect): bool =
  not empty(intersect(a, b))

proc pixelAlign(r: Rect; bleed: float32): Rect =
  ## Grow by `bleed` and snap outward to whole pixels.
  let x0 = float32(int(r.x - bleed - 0.999'f32))
  let y0 = float32(int(r.y - bleed - 0.999'f32))
  let x1 = float32(int(r.x + r.width + bleed + 0.999'f32))
  let y1 = float32(int(r.y + r.height + bleed + 0.999'f32))
  rect(max(x0, 0.0'f32), max(y0, 0.0'f32), x1 - max(x0, 0.0'f32),
       y1 - max(y0, 0.0'f32))

proc area(r: Rect): float64 = float64(r.width) * float64(r.height)

proc addArea(rects: var seq[Rect]; r: Rect) =
  ## Add a damaged area, merging it into any area it touches when their
  ## bounding box costs little more than the two -- a thin column crossing
  ## two wide bands stays apart from them. Areas may overlap: each is
  ## cleared and painted whole, so painting a pixel twice is harmless.
  if empty(r):
    return
  var cur = r
  var merged = true
  while merged:
    merged = false
    var i = 0
    while i < rects.len:
      let both = union(rects[i], cur)
      if overlaps(rects[i], cur) and
          area(both) <= (area(rects[i]) + area(cur)) * MergeSlack:
        cur = both
        rects[i] = rects[^1]
        rects.setLen(rects.len - 1)
        merged = true
      else:
        inc i
  rects.add cur

proc finish(raw: seq[Rect]; viewport: Rect; scroll = Scroll()): Damage =
  ## The raw damaged boxes, bled, snapped to pixels, merged and capped.
  var rects: seq[Rect] = @[]
  var total = 0.0'f64
  for r in raw:
    if not empty(r): # bled, an empty box would grow a speck at the origin
      addArea(rects, intersect(pixelAlign(r, Bleed), viewport))
  if rects.len == 0:
    if scroll.dy != 0.0:
      return Damage(kind: dmgRects, scroll: scroll)
    return Damage(kind: dmgNone)
  while rects.len > MaxRects:
    # Too many areas to paint one by one: merge the pair whose box adds
    # the least, until few enough remain.
    var bi = 0
    var bj = 1
    var cost = Inf
    for i in 0 ..< rects.len:
      for j in i + 1 ..< rects.len:
        let c = area(union(rects[i], rects[j])) - area(rects[i]) -
          area(rects[j])
        if c < cost:
          cost = c
          bi = i
          bj = j
    rects[bi] = union(rects[bi], rects[bj])
    rects.del(bj)
  for r in rects:
    total += area(r)
  if total >= area(viewport) * FullFraction:
    return Damage(kind: dmgFull)
  Damage(kind: dmgRects, rects: rects, scroll: scroll)

proc clipped(r: Rect): Rect =
  ## A clip box as the renderer sets it: each number truncated to whole
  ## pixels, the way `SDL_Rect` takes them.
  rect(float32(int32(r.x)), float32(int32(r.y)), float32(int32(r.width)),
       float32(int32(r.height)))

proc contains(outer, inner: Rect): bool =
  outer.x <= inner.x and outer.y <= inner.y and
    outer.x + outer.width >= inner.x + inner.width and
    outer.y + outer.height >= inner.y + inner.height

proc grown(r: Rect; d: float32): Rect =
  rect(r.x - d, r.y - d, r.width + 2.0'f32 * d, r.height + 2.0'f32 * d)

proc scrolled(prev, next: seq[CmdSig]; viewport: Rect): Damage =
  ## The damage of a frame whose commands in one clip region all moved by
  ## the same whole number of rows: a `Scroll` of the region, the rows it
  ## uncovers, what came into or left it, and whatever else changed or
  ## stood still over it. `dmgNone` when no region scrolled or the frame
  ## changed in a way only the plain diff can tell.
  var index = initTable[uint64, int]()
  var i = 0
  while i < prev.len:
    index[prev[i].key] = i
    inc i
  var match = newSeq[int](next.len)  # next -> prev, -1 for new commands
  var matched = newSeq[bool](prev.len)
  var lastOld = -1
  i = 0
  while i < next.len:
    let j = index.getOrDefault(next[i].key, -1)
    if j >= 0 and j > lastOld:
      match[i] = j
      lastOld = j
      matched[j] = true
    else:
      # New, or out of order -- elements sharing an id renumber when one
      # of them leaves: painted anew where it is, cleared where it was.
      match[i] = -1
    inc i

  # The region whose contents moved the most commands by one delta.
  var
    best = -1
    bestEnd = -1
    bestDy = 0'i32
    bestCount = 0
    bestArea = Rect()
    stack: seq[int] = @[]
    counts = initTable[int32, int]()
  i = 0
  while i < next.len:
    if next[i].kind == renderClipStart:
      stack.add i
    elif next[i].kind == renderClipEnd and stack.len > 0:
      let s = stack.pop()
      if match[s] >= 0 and prev[match[s]].hash == next[s].hash:
        # The region stands still: count how its contents moved.
        counts.clear()
        var k = s + 1
        while k < i:
          let j = match[k]
          if j >= 0 and prev[j].shape == next[k].shape and
              prev[j].hash != next[k].hash and prev[j].box.x == next[k].box.x:
            let d = next[k].box.y - prev[j].box.y
            if d == float32(int32(d)):
              counts.mgetOrPut(int32(d), 0) += 1
          inc k
        for d, n in counts:
          if d != 0 and n > bestCount:
            best = s
            bestEnd = i
            bestDy = d
            bestCount = n
            # The pixels the region shows: its box inside every enclosing
            # clip, as the renderer narrows them.
            var shown = Rect()
            var first = true
            for outer in stack:
              shown = if first: clipped(next[outer].box)
                      else: clipped(intersect(next[outer].box, shown))
              first = false
            bestArea = if first: clipped(next[s].box)
                       else: clipped(intersect(next[s].box, shown))
    inc i
  if best < 0 or match[bestEnd] < 0:
    return Damage(kind: dmgNone)
  let area = intersect(bestArea, viewport)
  let dy = float32(bestDy)
  if empty(area) or abs(dy) >= area.height:
    return Damage(kind: dmgNone)
  let prevStart = match[best]
  let prevEnd = match[bestEnd]

  proc shifted(r: Rect): Rect = rect(r.x, r.y + dy, r.width, r.height)

  var raw: seq[Rect] = @[]
  # The rows the shift uncovers.
  if dy < 0.0:
    raw.add rect(area.x, area.y + area.height + dy, area.width, -dy)
  else:
    raw.add rect(area.x, area.y, area.width, dy)
  i = 0
  while i < next.len:
    let inside = i > best and i < bestEnd
    let j = match[i]
    if j < 0:
      # New this frame -- scrolled into view, say.
      if next[i].isClip and not inside:
        return Damage(kind: dmgNone)  # structure moved: the plain diff decides
      raw.add next[i].box
    elif inside and prev[j].shape == next[i].shape and
        prev[j].box.x == next[i].box.x and next[i].box.y - prev[j].box.y == dy:
      discard # moved with the region: the shift put it in place
    elif prev[j].hash == next[i].hash:
      # Standing still over the region -- its own fill and frame among
      # them -- the shift moved its pixels off it.
      if not next[i].isClip and overlaps(grown(next[i].box, Bleed), area):
        if (next[i].kind == renderRectangle or next[i].kind == renderBorder) and
            contains(next[i].box, area):
          # A flat backdrop or frame around the region: it only differs
          # along its top and bottom -- its corners, its edges -- so only
          # those bands of the shifted rows need painting again.
          let band = next[i].reach + Bleed + abs(dy)
          raw.add rect(area.x, area.y, area.width, band)
          raw.add rect(area.x, area.y + area.height - band, area.width, band)
        else:
          raw.add intersect(grown(next[i].box, Bleed), area)
          raw.add intersect(shifted(grown(prev[j].box, Bleed)), area)
    elif next[i].isClip:
      if not inside:
        return Damage(kind: dmgNone)
      raw.add area # a clip inside changed besides the move
    elif inside:
      # Its old pixels moved with the shift; its new ones are elsewhere.
      raw.add intersect(shifted(grown(prev[j].box, Bleed)), area)
      raw.add next[i].box
    else:
      raw.add prev[j].box
      raw.add next[i].box
      raw.add intersect(shifted(grown(prev[j].box, Bleed)), area)
    inc i
  # Gone this frame -- scrolled out of view, say: inside the region its
  # pixels moved with the shift; elsewhere they also stay where they were.
  i = 0
  while i < prev.len:
    if not matched[i]:
      let inside = i > prevStart and i < prevEnd
      if prev[i].isClip and not inside:
        return Damage(kind: dmgNone)
      if not inside:
        raw.add prev[i].box
      raw.add intersect(shifted(grown(prev[i].box, Bleed)), area)
    inc i
  finish(raw, viewport, Scroll(area: area, dy: dy))

proc diffDamage*(prev, next: seq[CmdSig]; viewport: Rect;
                 shift = false): Damage =
  ## What must be repainted to turn `prev`'s picture into `next`'s. With
  ## `shift` the renderer can move its own pixels, and a scrolled clip
  ## region comes back as a `Scroll` (see the module header).
  var raw: seq[Rect] = @[]
  var structural = false

  if prev.len == next.len:
    # The common case: same commands, same order -- compare pairwise.
    var i = 0
    while i < next.len and not structural:
      if prev[i].key != next[i].key:
        structural = true
      elif prev[i].hash != next[i].hash:
        if next[i].isClip:
          structural = true
        else:
          raw.add prev[i].box
          raw.add next[i].box
      inc i
    if not structural and raw.len == 0:
      return Damage(kind: dmgNone)

  if shift:
    # A scroll moves every command in its region, clips among them, and
    # brings some in and takes others out: try reading it as one first.
    let moved = scrolled(prev, next, viewport)
    if moved.kind != dmgNone:
      return moved

  if structural or prev.len != next.len:
    raw.setLen(0)
    var index = initTable[uint64, int]()
    var i = 0
    while i < prev.len:
      index[prev[i].key] = i
      inc i
    var matched = newSeq[bool](prev.len)
    var lastOld = -1
    i = 0
    while i < next.len:
      let j = index.getOrDefault(next[i].key, -1)
      if j < 0:
        if next[i].isClip:
          return Damage(kind: dmgFull)
        raw.add next[i].box
      else:
        matched[j] = true
        if j < lastOld:
          return Damage(kind: dmgFull)   # paint order changed
        lastOld = j
        if prev[j].hash != next[i].hash:
          if next[i].isClip:
            return Damage(kind: dmgFull)
          raw.add prev[j].box
          raw.add next[i].box
      inc i
    i = 0
    while i < prev.len:
      if not matched[i]:
        if prev[i].isClip:
          return Damage(kind: dmgFull)
        raw.add prev[i].box
      inc i

  finish(raw, viewport)
