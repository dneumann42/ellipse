## Preprocess layered sprites on cache misses; warm rendering uses one texture.
import std/[math, tables]
import geometry

type
  BillboardLayers* = array[4, int] ## back to front, -1 disables a layer
  CompositionKey* = array[5, int]
  CompositionEntry* = ref object
    key*: CompositionKey
    slot*: int
    rect*: Vec4
    versions*: array[5, uint64]
    used*: uint64
    resident*: bool
  CompositionCache* = object
    entries*: Table[CompositionKey, CompositionEntry]
    slots*: seq[CompositionEntry]
    maximum*: int
    generation*: uint64
    builds*, evictions*: int

func noBillboardLayers*(): BillboardLayers = [-1, -1, -1, -1]

func compositionKey*(base: int, overlays: BillboardLayers): CompositionKey =
  [base, overlays[0], overlays[1], overlays[2], overlays[3]]

func hasClothing*(key: CompositionKey): bool =
  for i in 1 .. 4:
    if key[i] >= 0: return true

proc initCompositionCache*(capacity: int, maximum = 2048): CompositionCache =
  result.slots = newSeq[CompositionEntry](capacity)
  result.maximum = max(capacity, maximum)

proc protectSources*(cache: var CompositionCache,
                     protected: openArray[bool]): seq[int] =
  ## Restore originals when a previously cached output slot is drawn directly.
  for slot in 0 ..< min(protected.len, cache.slots.len):
    if not protected[slot] or cache.slots[slot].isNil: continue
    cache.entries.del(cache.slots[slot].key)
    cache.slots[slot] = nil
    inc cache.generation
    inc cache.evictions
    result.add slot

proc pin*(cache: var CompositionCache, key: CompositionKey, frame: uint64) =
  if cache.entries.hasKey(key): cache.entries[key].used = frame

proc resolve*(cache: var CompositionCache, key: CompositionKey,
              protected: openArray[bool], frame: uint64): CompositionEntry =
  if cache.entries.hasKey(key):
    result = cache.entries[key]
    result.used = frame
    return
  var slot = -1
  var oldest = uint64.high
  for i, entry in cache.slots:
    if i < protected.len and protected[i]: continue
    if entry.isNil:
      slot = i
      break
    if entry.used < frame and entry.used < oldest:
      slot = i
      oldest = entry.used
  if slot < 0:
    if cache.slots.len >= cache.maximum:
      raise newException(ValueError, "too many simultaneously visible character outfits")
    slot = cache.slots.len
    cache.slots.setLen(min(cache.maximum, max(slot+1, slot*2)))
  if not cache.slots[slot].isNil:
    cache.entries.del(cache.slots[slot].key)
    inc cache.evictions
  result = CompositionEntry(key: key, slot: slot, used: frame)
  cache.slots[slot] = result
  cache.entries[key] = result
  inc cache.generation

proc versionsMatch*(entry: CompositionEntry, versions: openArray[uint64]): bool =
  if not entry.resident: return false
  for i, layer in entry.key:
    if layer >= 0 and entry.versions[i] != versions[layer]: return false
  true

proc rememberVersions*(entry: CompositionEntry, versions: openArray[uint64]) =
  for i, layer in entry.key:
    if layer >= 0: entry.versions[i] = versions[layer]
  entry.resident = true

proc composeBillboard*(source: openArray[uint8], width, height: int,
                       rects: openArray[Vec4], key: CompositionKey): seq[uint8] =
  ## Compose original source pixels before mipmapping; all layers retain their
  ## authored order. The body's rectangle defines the shared logical canvas.
  let bytes = width*height*4
  result = newSeq[uint8](bytes)
  let baseRect = rects[key[0]]
  let left = int(round(baseRect.x*width.float32))
  let top = int(round(baseRect.y*height.float32))
  let w = int(round(baseRect.z*width.float32))-left
  let h = int(round(baseRect.w*height.float32))-top
  if w <= 0 or h <= 0: return
  for layer in key:
    if layer < 0: continue
    let rect = rects[layer]
    let sx = int(round(rect.x*width.float32))
    let sy = int(round(rect.y*height.float32))
    let sw = int(round(rect.z*width.float32))-sx
    let sh = int(round(rect.w*height.float32))-sy
    if sw <= 0 or sh <= 0: continue
    for y in 0 ..< h:
      let yy = sy + min(sh-1, (2*y+1)*sh div (2*h))
      for x in 0 ..< w:
        let xx = sx + min(sw-1, (2*x+1)*sw div (2*w))
        let src = layer*bytes+(yy*width+xx)*4
        let dst = ((top+y)*width+left+x)*4
        let sa = source[src+3].int
        if sa == 0: continue
        if sa == 255:
          copyMem(addr result[dst], unsafeAddr source[src], 4)
          continue
        let da = result[dst+3].int
        let alpha = sa*255+da*(255-sa)
        for c in 0 ..< 3:
          result[dst+c] = uint8((source[src+c].int*sa*255+
            result[dst+c].int*da*(255-sa)+alpha div 2) div alpha)
        result[dst+3] = uint8((alpha+127) div 255)
