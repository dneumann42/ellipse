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

import std/tables

import clay

type
  CmdSig* = object
    key*: uint64
    hash*: uint64
    box*: Rect
    isClip*: bool     ## clip / overlay bracket: structure, not paint

  DamageKind* = enum
    dmgNone, dmgRects, dmgFull

  Damage* = object
    kind*: DamageKind
    rects*: seq[Rect]   ## dmgRects: disjoint-ish areas to repaint

const
  MaxRects = 6          ## more separate areas than this merge into one
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

proc signature*(cmd: RenderCommand; text: string): uint64 =
  ## Hash of everything in `cmd` that reaches the pixels; `text` is the
  ## command's line for `renderText` (ignored otherwise).
  result = 0xCBF29CE484222325'u64
  fnv(result, uint64(ord(cmd.kind)))
  mixF(result, cmd.box.x)
  mixF(result, cmd.box.y)
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
  of renderClipStart:
    fnv(result, uint64(ord(cmd.clipHorizontal)))
    fnv(result, uint64(ord(cmd.clipVertical)))
  of renderOverlayStart:
    mixColor(result, cmd.overlay)
  of renderClipEnd, renderOverlayEnd:
    discard

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
  b.sigs.add CmdSig(key: base or uint64(occ and 0xFFFFFF'u32),
                    hash: signature(cmd, text), box: cmd.box,
                    isClip: isBracket(cmd.kind))

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

proc addArea(rects: var seq[Rect]; r: Rect) =
  ## Add a damaged area, merging it into any area it touches.
  if empty(r):
    return
  var cur = r
  var merged = true
  while merged:
    merged = false
    var i = 0
    while i < rects.len:
      if overlaps(rects[i], cur):
        cur = union(rects[i], cur)
        rects[i] = rects[^1]
        rects.setLen(rects.len - 1)
        merged = true
      else:
        inc i
  rects.add cur

proc area(r: Rect): float64 = float64(r.width) * float64(r.height)

proc diffDamage*(prev, next: seq[CmdSig]; viewport: Rect): Damage =
  ## What must be repainted to turn `prev`'s picture into `next`'s.
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

  var rects: seq[Rect] = @[]
  var total = 0.0'f64
  for r in raw:
    let clipped = intersect(pixelAlign(r, Bleed), viewport)
    addArea(rects, clipped)
  if rects.len == 0:
    return Damage(kind: dmgNone)
  if rects.len > MaxRects:
    var all = rects[0]
    for r in rects:
      all = union(all, r)
    rects = @[all]
  for r in rects:
    total += area(r)
  if total >= area(viewport) * FullFraction:
    return Damage(kind: dmgFull)
  Damage(kind: dmgRects, rects: rects)
