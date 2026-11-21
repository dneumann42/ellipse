## Editable heightfield and tiled splat rendering.

import std/math
import ../drawing/artist3d
import ./[brushes, heightfields]

export brushes.SplatWeights, artist3d

const TileCells = 32

type
  TerrainLayer* = range[0 .. SplatLayers - 1]
  TerrainData* = object
    ## Heights and material weights in X-major order, with Z contiguous.
    size*: int
    spacing*: float32
    origin*: Vec2 ## world X and Z of sample (0, 0)
    heights*: seq[float32]
    weights*: seq[SplatWeights] ## each sample sums to 255
  Terrain* = ref object
    heights: Field
    origin: Vec2
    weights: seq[SplatWeights]
    tilesPerSide: int
    meshes: seq[StaticSplatMesh]
    artist: Artist3D

func finite(x: float32): bool = abs(x) < Inf

proc newTerrain*(size: int, spacing = 1f, origin = vec2(0, 0),
                 height = 0f, layer: TerrainLayer = 0): Terrain =
  ## Create a square grid of samples. There are size - 1 cells per side.
  if size < 2 or size > high(int) div size or spacing <= 0 or
      not spacing.finite or not origin.x.finite or not origin.y.finite or
      not (origin.x + (size - 1).float32 * spacing).finite or
      not (origin.y + (size - 1).float32 * spacing).finite or not height.finite or
      origin.x + spacing <= origin.x or origin.y + spacing <= origin.y:
    raise newException(ValueError, "invalid terrain dimensions, origin, or height")
  let tiles = (size - 2) div TileCells + 1
  result = Terrain(heights: newField(size, spacing), origin: origin,
    weights: newSeq[SplatWeights](size * size), tilesPerSide: tiles,
    meshes: newSeq[StaticSplatMesh](tiles * tiles))
  for i in 0 ..< result.weights.len:
    result.heights.data[i] = height
    result.weights[i][layer] = 255

proc newTerrain*(data: TerrainData): Terrain =
  ## Restore terrain from an application-owned snapshot.
  if data.size < 2 or data.size > high(int) div data.size or
      data.heights.len != data.size * data.size or data.weights.len != data.heights.len:
    raise newException(ValueError, "invalid terrain sample counts")
  for i, height in data.heights:
    var sum = 0
    for weight in data.weights[i]:
      sum += weight.int
    if not height.finite or sum != 255:
      raise newException(ValueError, "invalid height or material weights")
  result = newTerrain(data.size, data.spacing, data.origin)
  result.heights.data = data.heights
  result.weights = data.weights

func terrainData*(terrain: Terrain): TerrainData =
  ## A value snapshot for persistence or undo. GPU caches are derived.
  TerrainData(size: terrain.heights.size, spacing: terrain.heights.step,
    origin: terrain.origin, heights: terrain.heights.data, weights: terrain.weights)

func sampleCount*(terrain: Terrain): int = terrain.heights.size
func sampleSpacing*(terrain: Terrain): float32 = terrain.heights.step
func terrainOrigin*(terrain: Terrain): Vec2 = terrain.origin

func sampleIndex(terrain: Terrain, x, z: int): int =
  let size = terrain.sampleCount
  if x < 0 or z < 0 or x >= size or z >= size:
    raise newException(IndexDefect, "terrain sample outside grid")
  x * size + z

func heightAt*(terrain: Terrain, x, z: int): float32 =
  terrain.heights.data[terrain.sampleIndex(x, z)]

func weightsAt*(terrain: Terrain, x, z: int): SplatWeights =
  terrain.weights[terrain.sampleIndex(x, z)]

func pointAt*(terrain: Terrain, x, z: int): Vec3 =
  vec3(terrain.origin.x + x.float32 * terrain.sampleSpacing, terrain.heightAt(x, z),
       terrain.origin.y + z.float32 * terrain.sampleSpacing)

proc invalidate(terrain: Terrain, x, z, margin: int) =
  # Adjacent tiles share their boundary vertices. Height edits also affect
  # the normals of samples one step away.
  let
    firstX = max(0, x - margin - 1) div TileCells
    firstZ = max(0, z - margin - 1) div TileCells
    lastX = min(terrain.tilesPerSide - 1, (x + margin) div TileCells)
    lastZ = min(terrain.tilesPerSide - 1, (z + margin) div TileCells)
  for tx in firstX .. lastX:
    for tz in firstZ .. lastZ:
      terrain.meshes[tx * terrain.tilesPerSide + tz] = nil

proc setHeight*(terrain: Terrain, x, z: int, height: float32) =
  if not height.finite:
    raise newException(ValueError, "terrain height must be finite")
  let index = terrain.sampleIndex(x, z)
  if terrain.heights.data[index] != height:
    terrain.heights.data[index] = height
    terrain.invalidate(x, z, 1)

iterator stroke(terrain: Terrain, center: Vec3, radius: float32): auto =
  for sample in brushSamples(terrain.sampleCount, terrain.sampleSpacing,
                              vec3(terrain.origin.x, 0, terrain.origin.y), center, radius):
    yield sample

proc sculpt*(terrain: Terrain, center: Vec3, radius, delta: float32) =
  ## Raise or lower the surface by delta world units at the brush center.
  if not delta.finite:
    raise newException(ValueError, "sculpt delta must be finite")
  if delta == 0: return
  # Check the whole stroke before changing samples if the requested height
  # would exceed the range of the stored heightfield.
  const maxHeight = 3.4028234663852886e38
  for x, z, weight in terrain.stroke(center, radius):
    if abs(terrain.heightAt(x, z).float64 + delta.float64 * weight) > maxHeight:
      raise newException(ValueError, "sculpt stroke exceeds terrain height range")
  for x, z, weight in terrain.stroke(center, radius):
    terrain.setHeight(x, z, (terrain.heightAt(x, z).float64 + delta.float64 * weight).float32)

proc flatten*(terrain: Terrain, center: Vec3, radius, height: float32,
              strength = 1f) =
  ## Blend the surface toward a world-space elevation.
  if not height.finite or not strength.finite:
    raise newException(ValueError, "flatten height and strength must be finite")
  for x, z, weight in terrain.stroke(center, radius):
    let t = clamp(strength, 0f, 1f).float64 * weight
    terrain.setHeight(x, z, (terrain.heightAt(x, z).float64 * (1 - t) + height.float64 * t).float32)

proc smooth*(terrain: Terrain, center: Vec3, radius: float32, strength = 1f) =
  ## Soften slopes using the original heights from before the stroke.
  if not strength.finite:
    raise newException(ValueError, "smooth strength must be finite")
  let amount = clamp(strength, 0f, 1f).float64
  if amount == 0: return
  let field = terrain.heights
  var changed: seq[tuple[x, z: int, height: float32]]
  for x, z, weight in terrain.stroke(center, radius):
    var total = 0.0
    for i in x - 1 .. x + 1:
      for j in z - 1 .. z + 1:
        total += field[i, j].float64
    let t = amount * weight
    changed.add (x, z, (field[x, z].float64 * (1 - t) + total / 9 * t).float32)
  for sample in changed:
    terrain.setHeight(sample.x, sample.z, sample.height)

proc paint*(terrain: Terrain, center: Vec3, radius: float32, layer: TerrainLayer,
            strength = 1f) =
  ## Blend existing texture weights toward a layer at the brush center.
  if not strength.finite:
    raise newException(ValueError, "paint strength must be finite")
  let amount = clamp(strength, 0f, 1f)
  if amount == 0: return
  for x, z, weight in terrain.stroke(center, radius):
    let index = terrain.sampleIndex(x, z)
    var weights = terrain.weights[index]
    blendSplat(weights, layer, amount * weight)
    if weights != terrain.weights[index]:
      terrain.weights[index] = weights
      terrain.invalidate(x, z, 0)

func cellHeight(field: Field, x, z: int, u, v: float64): float64 =
  let
    a = field[x, z].float64
    c = field[x + 1, z + 1].float64
  if u >= v:
    a * (1 - u) + field[x + 1, z].float64 * (u - v) + c * v
  else:
    a * (1 - v) + field[x, z + 1].float64 * (v - u) + c * u

func surfaceAt*(terrain: Terrain, x, z: float32): float32 =
  ## Interpolate the triangles used to draw the terrain. Clamp at its edges.
  let
    last = terrain.sampleCount - 1
    u = clamp((x.float64 - terrain.origin.x) / terrain.sampleSpacing, 0.0, last.float64)
    v = clamp((z.float64 - terrain.origin.y) / terrain.sampleSpacing, 0.0, last.float64)
    i = min(u.int, last - 1)
    j = min(v.int, last - 1)
  terrain.heights.cellHeight(i, j, u - i.float64, v - j.float64).float32

proc groundHit*(terrain: Terrain, origin, direction: Vec3,
                reach = 3000f): tuple[hit: bool, point: Vec3] =
  ## First intersection with a terrain triangle within reach world units.
  let length = direction.length
  result.point = origin
  if length <= 0 or not length.finite or reach < 0 or not reach.finite or
      not origin.x.finite or not origin.y.finite or not origin.z.finite:
    return
  let
    ray = direction * (1f / length)
    last = terrain.sampleCount - 1
    starts = [(origin.x.float64 - terrain.origin.x) / terrain.sampleSpacing,
              (origin.z.float64 - terrain.origin.y) / terrain.sampleSpacing]
    speeds = [ray.x.float64 / terrain.sampleSpacing, ray.z.float64 / terrain.sampleSpacing]
  var entry = 0.0
  var exit = reach.float64
  for axis in 0 .. 1:
    let start = starts[axis]
    let speed = speeds[axis]
    if speed == 0:
      if start < 0 or start > last.float64:
        return
    else:
      let a = -start / speed
      let b = (last.float64 - start) / speed
      entry = max(entry, min(a, b))
      exit = min(exit, max(a, b))
  if entry > exit:
    return

  var cell, stride: array[2, int]
  var next: array[2, float64]
  template advanceTime(axis: int): float64 =
    if stride[axis] == 0: Inf
    else:
      let boundary = cell[axis] + max(0, stride[axis])
      (boundary.float64 - starts[axis]) / speeds[axis]
  for axis in 0 .. 1:
    let at = clamp(starts[axis] + speeds[axis] * entry, 0.0, last.float64)
    stride[axis] = cmp(speeds[axis], 0.0)
    cell[axis] = clamp((if stride[axis] < 0: ceil(at).int - 1 else: at.int), 0, last - 1)
    next[axis] = advanceTime(axis)

  while true:
    let
      stop = max(entry, min(exit, min(next[0], next[1])))
      u0 = starts[0] - cell[0].float64
      v0 = starts[1] - cell[1].float64
      slope = speeds[0] - speeds[1]
      diagonal = if slope == 0: stop else: clamp((v0 - u0) / slope, entry, stop)
    template above(t: float64): float64 =
      origin.y.float64 + ray.y.float64 * t -
        terrain.heights.cellHeight(cell[0], cell[1], u0 + speeds[0] * t,
                                    v0 + speeds[1] * t)
    var t = entry
    var a = above(t)
    for finish in [diagonal, stop]:
      let b = above(finish)
      if a == 0 or b == 0 or (a < 0) != (b < 0):
        let hit = if a == 0: t elif b == 0: finish else: t + (finish - t) * (a / (a - b))
        return (true, origin + ray * hit.float32)
      t = finish
      a = b
    if stop >= exit:
      break
    for axis in 0 .. 1:
      if next[axis] <= stop:
        cell[axis] += stride[axis]
        if cell[axis] < 0 or cell[axis] >= last:
          return
        next[axis] = advanceTime(axis)
    entry = stop

proc renderTerrain*(artist: Artist3D, terrain: Terrain) =
  ## Submit cached terrain tiles. Set the artist's splat atlas before drawing.
  if terrain.artist != artist:
    terrain.artist = artist
    for mesh in terrain.meshes.mitems:
      mesh = nil
  let size = terrain.sampleCount
  for tile, mesh in terrain.meshes.mpairs:
    if mesh.isNil:
      let
        x0 = tile div terrain.tilesPerSide * TileCells
        z0 = tile mod terrain.tilesPerSide * TileCells
        x1 = min(size - 1, x0 + TileCells)
        z1 = min(size - 1, z0 + TileCells)
      var vertices = newSeqOfCap[SplatVertex]((x1 - x0 + 1) * (z1 - z0 + 1))
      for x in x0 .. x1:
        for z in z0 .. z1:
          let
            field = terrain.heights
            w = terrain.weightsAt(x, z)
            n = normalize(vec3(field[x - 1, z] - field[x + 1, z],
                               2 * field.step, field[x, z - 1] - field[x, z + 1]))
          vertices.add SplatVertex(position: terrain.pointAt(x, z), normal: n,
            low: vec4(w[0].float32 / 255, w[1].float32 / 255, w[2].float32 / 255, w[3].float32 / 255),
            high: vec4(w[4].float32 / 255, w[5].float32 / 255, w[6].float32 / 255, w[7].float32 / 255),
            extra: w[8].float32 / 255f)
      artist.pushMatrix()
      artist.loadMatrix(identity())
      artist.beginSplatRecording()
      artist.splatGrid(vertices, z1 - z0 + 1)
      mesh = artist.endSplatRecording()
      artist.popMatrix()
    artist.drawStaticSplat(mesh)
