## CPU-binned world-space clustered forward lights. Fixed budgets bound both
## light lists and upload size; shared BVH shadows need no per-light passes.
##
## One RGBA32F texture holds everything. Light, cluster and room records are
## addressed as scalars (four per texel). Shadow tree nodes start on their own
## texture row and occupy five whole texels each, so the shader reads an
## inner node with two fetches and a leaf with at most five. The static part of
## the tree is uploaded only when it is rewritten; per-frame uploads cover the
## light/room rows and the dynamic nodes after the static tree.
import std/[algorithm, math, tables]
import ellipse/drawing/geometry
import ellipse/platform/gpu

const
  ClusterSide* = 32
  ClusterHeight* = 16
  ClusterCell* = 8'f32
  ClusterLights* = 24
  MaxPointLights* = 512
  LightStride = 8
  GridOffset = 4 + MaxPointLights * LightStride
  ClusterCount = ClusterSide * ClusterSide * ClusterHeight
  MaxEnvironmentRooms* = 512
  RoomPortals* = 8
  ClusterRooms* = 16
  RoomStride = 8 + RoomPortals * 10 + 6
  RoomOffset = GridOffset + ClusterCount * (ClusterLights + 1)
  RoomGridOffset = RoomOffset + MaxEnvironmentRooms * RoomStride
  ShadowTreeOffset = RoomGridOffset + ClusterCount * (ClusterRooms + 1)
    ## scalar index of the shadow node count
  MaxShadowNodes = 262144
  TextureWidth = 1024
  RowFloats = TextureWidth * 4 ## four floats per RGBA32F texel
  ShadowNodeStride = 20 ## five texels: lo+escape, hi+kind, center/half, rotation/profile, profile
  NearBoxes* = 16
    ## static occluders nearest each shadowing light, tested before the tree
  NearOffset = (ShadowTreeOffset + 1 + RowFloats - 1) div RowFloats * RowFloats
    ## first float of light 0's near list; NearBoxes leaf records per light
  ShadowNodeBase = NearOffset + MaxPointLights * NearBoxes * ShadowNodeStride
    ## first float of node 0; row aligned, so node rows never hold light data
  TextureHeight = (ShadowNodeBase + MaxShadowNodes * ShadowNodeStride + RowFloats - 1) div RowFloats

type
  PointLight* = object
    position*, color*: Vec3
    radius*, intensity*: float32
    shadows*: bool
  LightOccluder* = object
    low*, high*: Vec3 ## world bounds for BVH traversal
    center*, half*: Vec3 ## exact local box for rotated geometry
    rotation*: Vec2 ## cosine/sine; zero means axis aligned
    roofMode*: int ## 0 box, 2 symmetric pitched/hipped roof, 3 single slope
    roofProfile*: Vec4 ## local x slope/intercept, z slope/intercept
  LightPortal* = object
    ## Axis-aligned opening at the inner wall face; normal points indoors.
    low*, high*, inward*: Vec3
    transmission*: float32
  EnvironmentRoom* = object
    low*, high*: Vec3 ## world-space broad-phase bounds
    center*, half*: Vec3 ## oriented rectangle in the x/z plane
    rotation*: Vec2 ## cosine/sine; zero preserves legacy axis-aligned rooms
    portals*: seq[LightPortal]
  OccluderNode = object
    bounds: LightOccluder
    first, count, left, right: int
  ShadowGroup = object
    ## Static occluders sharing one pose rotation. Their tree is built in
    ## that rotated frame, where oriented walls are axis aligned and their
    ## bounds are tight; a world-space AABB of a diagonal wall is not.
    pivot: Vec3 ## frame origin (x/z used)
    rotation: Vec2 ## cosine/sine of the frame
    tree: ClusteredLights ## indexedBoxes hold frame-local boxes
    originals: seq[LightOccluder] ## world solids, parallel to tree.indexedBoxes
  ShadowGeometry* = ref object
    ## Immutable CPU spatial index, prepared before interactive rendering.
    ## Two levels: `index` holds world bounds of each group and of each
    ## axis-aligned box; groups hold frame-local trees.
    index: ClusteredLights
    items: seq[int] ## per top-level box: group index, or -1 - world box index
    groups: seq[ShadowGroup]
    worldBoxes: seq[LightOccluder]
  ClusteredLights* = ref object
    indexedBoxes: seq[LightOccluder]
    boxOrder: seq[int]
    boxNodes: seq[OccluderNode]
    staticGeometry: ShadowGeometry
    nearCache: Table[array[3, int32], seq[LightOccluder]]
      ## per static light position: its nearest static occluders
    staticShadowNodes: int
    staticDirty: bool ## static node rows changed since the last upload
    shadowRegion: Vec3
    shadowRadius: float32
    indexBuilds*: int ## diagnostic: dynamic/legacy index rebuilds
    texture*: gpu.Texture
    sampler*: Sampler
    data*: seq[float32]
    activeCount*, overflowCount*: int
    shadowNodeCount*: int
    nearUsed: int ## end of the written near-list floats
    binOrigin: Vec3 ## cluster origin the light lists were binned for
    binLights: seq[PointLight] ## light sites they were binned from
    binGeometry: ShadowGeometry
    admitted: seq[int] ## per light id: its index in `binLights`
    lightFlags: seq[float32] ## per light id: the shadow flag
    binRooms: seq[EnvironmentRoom] ## rooms the room lists were written from
    roomOrigin: Vec3
    lightsDirty, roomsDirty: bool ## rows to upload at the next present
    roomCount*, roomOverflowCount*: int

func portalExposure*(portal: LightPortal, p: Vec3): float32 =
  let delta = p - vec3(clamp(p.x, portal.low.x, portal.high.x),
    clamp(p.y, portal.low.y, portal.high.y), clamp(p.z, portal.low.z, portal.high.z))
  let size = portal.high - portal.low
  let area = size.x * size.y + size.y * size.z + size.z * size.x
  let depth = dot(delta, portal.inward)
  let d2 = dot(delta, delta)
  if depth < -0.001f or area <= 0: return 0
  let facing = max(depth, 0.02f) / sqrt(max(d2, 0.0004f))
  clamp(portal.transmission, 0'f32, 1'f32) * min(facing, 1'f32) *
    area / (area + 4 * d2)

func environmentExposure*(room: EnvironmentRoom, p: Vec3): float32 =
  ## Same inexpensive solid-angle approximation as the fragment shaders.
  if p.x < room.low.x or p.y < room.low.y or p.z < room.low.z or
      p.x > room.high.x or p.y > room.high.y or p.z > room.high.z:
    return 1
  if room.rotation.x*room.rotation.x+room.rotation.y*room.rotation.y > 0.5f:
    let d = p-room.center
    let local = vec2(room.rotation.x*d.x+room.rotation.y*d.z,
      -room.rotation.y*d.x+room.rotation.x*d.z)
    if abs(local.x) > room.half.x or abs(local.y) > room.half.z: return 1
  result = 0.04f
  for i in 0 ..< min(room.portals.len, RoomPortals):
    result = max(result, 0.04f + 0.96f * room.portals[i].portalExposure(p))

proc newClusteredLights*(device: Device): ClusteredLights =
  ClusteredLights(texture: newPictureTexture(device, TextureWidth, TextureHeight, Rgba32Float),
    sampler: newSampler(device, nearest = true),
    data: newSeq[float32](RowFloats * TextureHeight), staticDirty: true,
    lightsDirty: true, roomsDirty: true)

func distance2(a, b: Vec3): float32 =
  let d = a - b
  dot(d, d)

func boxDistance2(p: Vec3, b: LightOccluder): float32 {.inline.} =
  # Scalar form avoids constructing temporary vectors in the hot traversal.
  let x = max(max(b.low.x - p.x, 0'f32), p.x - b.high.x)
  let y = max(max(b.low.y - p.y, 0'f32), p.y - b.high.y)
  let z = max(max(b.low.z - p.z, 0'f32), p.z - b.high.z)
  x*x + y*y + z*z

func area(low, high: Vec3): float32 {.inline.} =
  let d = vec3(max(high.x-low.x, 0'f32), max(high.y-low.y, 0'f32), max(high.z-low.z, 0'f32))
  d.x*d.y + d.y*d.z + d.z*d.x

func axisOf(v: Vec3, axis: int): float32 {.inline.} =
  if axis == 0: v.x elif axis == 1: v.y else: v.z

proc buildBoxNode(grid: ClusteredLights, first, count: int): int =
  ## Binned surface-area heuristic: a shadow ray visits a node about in
  ## proportion to its surface, so splits minimise children's area x count.
  const
    Bins = 16
    LeafSize = 2 ## largest leaf; single boxes serialize without a container
    MaxLeaf = 6 ## leaves this small may stay whole when splitting costs more
  var bounds = grid.indexedBoxes[grid.boxOrder[first]]
  var centerLow = (bounds.low+bounds.high)*0.5f
  var centerHigh = centerLow
  for j in first ..< first + count:
    let box = grid.indexedBoxes[grid.boxOrder[j]]
    bounds.low = vec3(min(bounds.low.x, box.low.x), min(bounds.low.y, box.low.y), min(bounds.low.z, box.low.z))
    bounds.high = vec3(max(bounds.high.x, box.high.x), max(bounds.high.y, box.high.y), max(bounds.high.z, box.high.z))
    let c = (box.low+box.high)*0.5f
    centerLow = vec3(min(centerLow.x, c.x), min(centerLow.y, c.y), min(centerLow.z, c.z))
    centerHigh = vec3(max(centerHigh.x, c.x), max(centerHigh.y, c.y), max(centerHigh.z, c.z))
  result = grid.boxNodes.len
  grid.boxNodes.add OccluderNode(bounds: LightOccluder(low: bounds.low, high: bounds.high),
    first: first, count: count, left: -1, right: -1)
  if count <= LeafSize: return
  var bestAxis = -1
  var bestSplit = 0
  var bestCost = Inf.float32
  for axis in 0..2:
    let lo = centerLow.axisOf(axis)
    let extent = centerHigh.axisOf(axis) - lo
    if extent <= 0.00001f: continue
    var binCount: array[Bins, int]
    var binLow, binHigh: array[Bins, Vec3]
    for b in 0 ..< Bins:
      binLow[b] = vec3(Inf.float32, Inf.float32, Inf.float32)
      binHigh[b] = vec3(-Inf.float32, -Inf.float32, -Inf.float32)
    for j in first ..< first + count:
      let box = grid.indexedBoxes[grid.boxOrder[j]]
      let c = ((box.low+box.high)*0.5f).axisOf(axis)
      let b = min(Bins-1, int((c-lo)/extent*Bins.float32))
      inc binCount[b]
      binLow[b] = vec3(min(binLow[b].x, box.low.x), min(binLow[b].y, box.low.y), min(binLow[b].z, box.low.z))
      binHigh[b] = vec3(max(binHigh[b].x, box.high.x), max(binHigh[b].y, box.high.y), max(binHigh[b].z, box.high.z))
    var rightArea: array[Bins, float32]
    var rightCount: array[Bins, int]
    var low = vec3(Inf.float32, Inf.float32, Inf.float32)
    var high = vec3(-Inf.float32, -Inf.float32, -Inf.float32)
    var n = 0
    for b in countdown(Bins-1, 1):
      low = vec3(min(low.x, binLow[b].x), min(low.y, binLow[b].y), min(low.z, binLow[b].z))
      high = vec3(max(high.x, binHigh[b].x), max(high.y, binHigh[b].y), max(high.z, binHigh[b].z))
      n += binCount[b]
      rightArea[b] = area(low, high)
      rightCount[b] = n
    low = vec3(Inf.float32, Inf.float32, Inf.float32)
    high = vec3(-Inf.float32, -Inf.float32, -Inf.float32)
    n = 0
    for b in 0 ..< Bins-1:
      low = vec3(min(low.x, binLow[b].x), min(low.y, binLow[b].y), min(low.z, binLow[b].z))
      high = vec3(max(high.x, binHigh[b].x), max(high.y, binHigh[b].y), max(high.z, binHigh[b].z))
      n += binCount[b]
      if n == 0 or rightCount[b+1] == 0: continue
      let cost = area(low, high)*n.float32 + rightArea[b+1]*rightCount[b+1].float32
      if cost < bestCost:
        bestCost = cost
        bestAxis = axis
        bestSplit = b
  var half: int
  if bestAxis < 0:
    # Coincident centers: split evenly so leaves stay small.
    half = count div 2
  else:
    if count <= MaxLeaf and bestCost >= area(bounds.low, bounds.high)*count.float32:
      return
    let lo = centerLow.axisOf(bestAxis)
    let extent = centerHigh.axisOf(bestAxis) - lo
    var left = first
    var right = first + count - 1
    while left <= right:
      let box = grid.indexedBoxes[grid.boxOrder[left]]
      let c = ((box.low+box.high)*0.5f).axisOf(bestAxis)
      if min(Bins-1, int((c-lo)/extent*Bins.float32)) <= bestSplit: inc left
      else:
        swap(grid.boxOrder[left], grid.boxOrder[right])
        dec right
    half = left - first
    if half == 0 or half == count: half = count div 2
  let left = grid.buildBoxNode(first, half)
  let right = grid.buildBoxNode(first + half, count - half)
  grid.boxNodes[result].left = left
  grid.boxNodes[result].right = right

proc syncOccluders(grid: ClusteredLights, boxes: openArray[LightOccluder]) =
  # Compare values, not sequence identity: callers rebuild arrays every frame.
  var same = grid.indexedBoxes.len == boxes.len
  if same:
    for i, box in boxes:
      if grid.indexedBoxes[i] != box:
        same = false
        break
  if same: return
  inc grid.indexBuilds
  grid.indexedBoxes = @boxes
  grid.boxNodes.setLen(0)
  grid.boxOrder.setLen(boxes.len)
  for i in 0 ..< boxes.len: grid.boxOrder[i] = i
  if boxes.len > 0: discard grid.buildBoxNode(0, boxes.len)

func occluderBlocksSegment*(box: LightOccluder, start,finish: Vec3): bool =
  ## CPU reference for the shader's compact convex-solid intersection.
  var origin = start
  var ray = finish-start
  var low = box.low
  var high = box.high
  if box.rotation.x*box.rotation.x+box.rotation.y*box.rotation.y > 0.5f:
    let dx = start.x-box.center.x
    let dz = start.z-box.center.z
    origin.x = box.rotation.x*dx+box.rotation.y*dz
    origin.z = -box.rotation.y*dx+box.rotation.x*dz
    let rx = ray.x
    ray.x = box.rotation.x*rx+box.rotation.y*ray.z
    ray.z = -box.rotation.y*rx+box.rotation.x*ray.z
    low.x = -box.half.x; high.x = box.half.x
    low.z = -box.half.z; high.z = box.half.z
  var enter = 0f
  var leave = 1f
  for (p,d,lo,hi) in [(origin.x,ray.x,low.x,high.x),
      (origin.y,ray.y,low.y,high.y),(origin.z,ray.z,low.z,high.z)]:
    if abs(d) < 0.000001f:
      if p < lo or p > hi: return false
    else:
      enter = max(enter,min((lo-p)/d,(hi-p)/d))
      leave = min(leave,max((lo-p)/d,(hi-p)/d))
  proc plane(n: Vec3, bound: float32): bool =
    let distance = bound-dot(n,origin)
    let along = dot(n,ray)
    if abs(along) < 0.000001f: return distance >= 0
    if along > 0: leave = min(leave,distance/along)
    else: enter = max(enter,distance/along)
    enter < leave
  let p = box.roofProfile
  if box.roofMode == 2:
    if p.x > 0 and (not plane(vec3(p.x,1,0),low.y+p.y) or
        not plane(vec3(-p.x,1,0),low.y+p.y)): return false
    if p.z > 0 and (not plane(vec3(0,1,p.z),low.y+p.w) or
        not plane(vec3(0,1,-p.z),low.y+p.w)): return false
  elif box.roofMode == 3:
    if not plane(vec3(-p.x,1,-p.z),low.y+p.y): return false
  enter < leave and leave > 0 and enter < 1

func shadowNodeOffset*(node: int): int =
  ## First float of a serialized shadow node (CPU mirrors and tests).
  ShadowNodeBase + node * ShadowNodeStride

const
  NodeInner = 0'f32
  NodeBox = 1'f32
  NodeFrame = 4'f32 ## enters a group: x/z of later nodes are frame local

func rotated(rotation: Vec2): bool {.inline.} =
  rotation.x*rotation.x+rotation.y*rotation.y > 0.5f

func toFrame(v: Vec3, pivot: Vec3, rotation: Vec2): Vec3 {.inline.} =
  let dx = v.x-pivot.x
  let dz = v.z-pivot.z
  vec3(rotation.x*dx+rotation.y*dz, v.y, -rotation.y*dx+rotation.x*dz)

func localOccluder(box: LightOccluder, pivot: Vec3, rotation: Vec2): LightOccluder =
  ## The same solid in a group's frame. Plain walls become axis-aligned
  ## boxes; roofs keep their centered plane profile with an identity turn.
  let c = toFrame(box.center, pivot, rotation)
  result = LightOccluder(low: vec3(c.x-box.half.x, box.low.y, c.z-box.half.z),
    high: vec3(c.x+box.half.x, box.high.y, c.z+box.half.z))
  if box.roofMode > 0:
    result.center = vec3(c.x, box.center.y, c.z)
    result.half = box.half
    result.rotation = vec2(1, 0)
    result.roofMode = box.roofMode
    result.roofProfile = box.roofProfile

proc prepareShadowGeometry*(boxes: openArray[LightOccluder]): ShadowGeometry =
  ## CPU-only. The result is immutable and may be prepared on a loader thread.
  result = ShadowGeometry(index: ClusteredLights())
  var keys: Table[int64, int]
  var members: seq[seq[LightOccluder]]
  var tops: seq[LightOccluder]
  for box in boxes:
    if not box.rotation.rotated:
      result.items.add -1-result.worldBoxes.len
      result.worldBoxes.add box
      tops.add LightOccluder(low: box.low, high: box.high)
      continue
    # Parts of one pose share bit-identical rotations; a 1e-5 rad bucket
    # also merges values that differ only by float rounding.
    let key = round(arctan2(box.rotation.y, box.rotation.x).float64*1e5).int64
    var group = keys.getOrDefault(key, -1)
    if group < 0:
      group = result.groups.len
      keys[key] = group
      result.groups.add ShadowGroup(rotation: box.rotation)
      members.add @[]
    members[group].add box
  for g, list in members:
    var pivot = vec3(0, 0, 0)
    var low = list[0].low
    var high = list[0].high
    for box in list:
      pivot = pivot+box.center*(1'f32/list.len.float32)
      low = vec3(min(low.x, box.low.x), min(low.y, box.low.y), min(low.z, box.low.z))
      high = vec3(max(high.x, box.high.x), max(high.y, box.high.y), max(high.z, box.high.z))
    result.groups[g].pivot = pivot
    var local: seq[LightOccluder]
    for box in list: local.add box.localOccluder(pivot, result.groups[g].rotation)
    result.groups[g].tree = ClusteredLights()
    result.groups[g].tree.syncOccluders(local)
    result.groups[g].originals = list
    result.items.add g
    tops.add LightOccluder(low: low, high: high)
  result.index.syncOccluders(tops)

proc emitNode(grid: ClusteredLights, bounds: LightOccluder, kind: float32): int =
  if grid.shadowNodeCount >= MaxShadowNodes:
    raise newException(ValueError, "Nearby light shadow geometry exceeds texture capacity")
  result = grid.shadowNodeCount
  inc grid.shadowNodeCount
  let at = ShadowNodeBase + result * ShadowNodeStride
  grid.data[at] = bounds.low.x
  grid.data[at+1] = bounds.low.y
  grid.data[at+2] = bounds.low.z
  grid.data[at+4] = bounds.high.x
  grid.data[at+5] = bounds.high.y
  grid.data[at+6] = bounds.high.z
  grid.data[at+7] = kind
  if kind != NodeInner: # inner nodes are read through their first two texels only
    for i, value in [bounds.center.x,bounds.center.z,bounds.half.x,
                     bounds.half.z,bounds.rotation.x,bounds.rotation.y,
                     bounds.roofProfile.x,bounds.roofProfile.y,
                     bounds.roofProfile.z,bounds.roofProfile.w]:
      grid.data[at+8+i] = value

proc finishNode(grid: ClusteredLights, index: int) =
  grid.data[ShadowNodeBase+index*ShadowNodeStride+3] = grid.shadowNodeCount.float32

func leafKind(box: LightOccluder): float32 =
  if box.roofMode > 0: box.roofMode.float32 else: NodeBox

proc nearestOccluders*(geometry: ShadowGeometry, p: Vec3, limit = NearBoxes,
                       reach = Inf.float32): seq[LightOccluder] =
  ## The `limit` static solids closest to `p` (by bounding box), nearest
  ## first. Blocked shadow rays usually end on these: a sconce's own room.
  var best: seq[tuple[d: float32, box: LightOccluder]]
  var worst = reach*reach
  proc consider(d: float32, box: LightOccluder) =
    if d > worst: return
    var i = best.len
    best.add (d, box)
    while i > 0 and best[i-1].d > d:
      best[i] = best[i-1]
      dec i
    best[i] = (d, box)
    if best.len > limit: best.setLen(limit)
    if best.len == limit: worst = best[^1].d
  proc visitGroup(group: ShadowGroup, index: int, local: Vec3) =
    let node = group.tree.boxNodes[index]
    if boxDistance2(local, node.bounds) > worst: return
    if node.left >= 0:
      let a = boxDistance2(local, group.tree.boxNodes[node.left].bounds)
      let b = boxDistance2(local, group.tree.boxNodes[node.right].bounds)
      if a <= b:
        visitGroup(group, node.left, local); visitGroup(group, node.right, local)
      else:
        visitGroup(group, node.right, local); visitGroup(group, node.left, local)
    else:
      for i in node.first..<node.first+node.count:
        let k = group.tree.boxOrder[i]
        consider(boxDistance2(local, group.tree.indexedBoxes[k]), group.originals[k])
  let top = geometry.index
  proc visit(index: int) =
    let node = top.boxNodes[index]
    if boxDistance2(p, node.bounds) > worst: return
    if node.left >= 0:
      let a = boxDistance2(p, top.boxNodes[node.left].bounds)
      let b = boxDistance2(p, top.boxNodes[node.right].bounds)
      if a <= b: visit(node.left); visit(node.right)
      else: visit(node.right); visit(node.left)
    else:
      for i in node.first..<node.first+node.count:
        let item = top.boxOrder[i]
        if boxDistance2(p, top.indexedBoxes[item]) > worst: continue
        let target = geometry.items[item]
        if target < 0:
          let box = geometry.worldBoxes[-1-target]
          consider(boxDistance2(p, box), box)
        else:
          let group = geometry.groups[target]
          if group.tree.boxNodes.len > 0:
            visitGroup(group, 0, p.toFrame(group.pivot, group.rotation))
  if top.boxNodes.len > 0: visit(0)
  for entry in best: result.add entry.box

proc writeLeaf(grid: ClusteredLights, at: int, box: LightOccluder) =
  ## One world-frame leaf record (same five texels as a tree leaf).
  for i, value in [box.low.x,box.low.y,box.low.z,0'f32,
                   box.high.x,box.high.y,box.high.z,box.leafKind,
                   box.center.x,box.center.z,box.half.x,box.half.z,
                   box.rotation.x,box.rotation.y,box.roofProfile.x,box.roofProfile.y,
                   box.roofProfile.z,box.roofProfile.w,0'f32,0'f32]:
    grid.data[at+i] = value

proc writeShadowTree(grid: ClusteredLights, source: ClusteredLights,
                     focus: Vec3, radius: float32) =
  # Threaded BVH: each node stores its escape index. The GPU can traverse
  # the complete nearby scene without a stack or a per-light wall budget.
  proc visit(index: int) =
    let node = source.boxNodes[index]
    if boxDistance2(focus,node.bounds) > radius*radius: return
    let wrap = node.left >= 0 or node.count > 1 # one box needs no container
    let parent = if wrap: grid.emitNode(node.bounds,NodeInner) else: -1
    if node.left >= 0:
      visit(node.left)
      visit(node.right)
    else:
      for i in node.first..<node.first+node.count:
        let box = source.indexedBoxes[source.boxOrder[i]]
        if boxDistance2(focus,box) > radius*radius: continue
        grid.finishNode(grid.emitNode(box,box.leafKind))
    if wrap: grid.finishNode(parent)
  if source.boxNodes.len > 0: visit(0)

proc writeStaticTree(grid: ClusteredLights, geometry: ShadowGeometry,
                     focus: Vec3, radius: float32) =
  ## World-space top level; each group is a frame node followed by its
  ## frame-local subtree, which ends at the frame node's escape index.
  let top = geometry.index
  proc visitGroup(group: ShadowGroup, index: int, local: Vec3) =
    let tree = group.tree
    let node = tree.boxNodes[index]
    if boxDistance2(local,node.bounds) > radius*radius: return
    let wrap = node.left >= 0 or node.count > 1 # one box needs no container
    let parent = if wrap: grid.emitNode(node.bounds,NodeInner) else: -1
    if node.left >= 0:
      visitGroup(group,node.left,local)
      visitGroup(group,node.right,local)
    else:
      for i in node.first..<node.first+node.count:
        let box = tree.indexedBoxes[tree.boxOrder[i]]
        if boxDistance2(local,box) > radius*radius: continue
        grid.finishNode(grid.emitNode(box,box.leafKind))
    if wrap: grid.finishNode(parent)
  proc visit(index: int) =
    let node = top.boxNodes[index]
    if boxDistance2(focus,node.bounds) > radius*radius: return
    let wrap = node.left >= 0 or node.count > 1 # one box needs no container
    let parent = if wrap: grid.emitNode(node.bounds,NodeInner) else: -1
    if node.left >= 0:
      visit(node.left)
      visit(node.right)
    else:
      for i in node.first..<node.first+node.count:
        let item = top.boxOrder[i]
        if boxDistance2(focus,top.indexedBoxes[item]) > radius*radius: continue
        let target = geometry.items[item]
        if target < 0:
          let box = geometry.worldBoxes[-1-target]
          grid.finishNode(grid.emitNode(box,box.leafKind))
        else:
          let group = geometry.groups[target]
          let at = grid.emitNode(top.indexedBoxes[item],NodeFrame)
          # Frame texel 2 holds pivot x/z and the frame's cosine/sine.
          let base = ShadowNodeBase+at*ShadowNodeStride
          grid.data[base+8] = group.pivot.x
          grid.data[base+9] = group.pivot.z
          grid.data[base+10] = group.rotation.x
          grid.data[base+11] = group.rotation.y
          grid.data[base+12] = 0
          grid.data[base+13] = 0
          if group.tree.boxNodes.len > 0:
            visitGroup(group,0,focus.toFrame(group.pivot,group.rotation))
          grid.finishNode(at)
    if wrap: grid.finishNode(parent)
  if top.boxNodes.len > 0: visit(0)

func slab(lo, hi, origin, direction: Vec3; enter, leave: var float32): bool =
  for axis in 0..2:
    let o = (if axis == 0: origin.x elif axis == 1: origin.y else: origin.z)
    let d = (if axis == 0: direction.x elif axis == 1: direction.y else: direction.z)
    let l = (if axis == 0: lo.x elif axis == 1: lo.y else: lo.z)
    let h = (if axis == 0: hi.x elif axis == 1: hi.y else: hi.z)
    if abs(d) < 0.000001f:
      if o < l or o > h: return false
    else:
      enter = max(enter,min((l-o)/d,(h-o)/d))
      leave = min(leave,max((l-o)/d,(h-o)/d))
  true

func shadowBlocked*(grid: ClusteredLights, start, finish: Vec3): bool =
  ## CPU mirror of the shader's `shadowBlocked`, over the serialized nodes.
  let count = grid.data[ShadowTreeOffset].int
  let ray = finish-start
  var frameStart = start
  var frameRay = ray
  var frameEnd = -1
  var node = 0
  while node < count:
    if node == frameEnd:
      frameStart = start
      frameRay = ray
      frameEnd = -1
    let at = shadowNodeOffset(node)
    template f(i: int): float32 = grid.data[at+i]
    let lo = vec3(f(0),f(1),f(2))
    let hi = vec3(f(4),f(5),f(6))
    let kind = f(7)
    if kind == NodeFrame:
      var enter = 0'f32
      var leave = 1'f32
      if slab(lo,hi,start,ray,enter,leave) and enter < leave and leave > 0 and enter < 1:
        let pivot = vec3(f(8),0,f(9))
        let rotation = vec2(f(10),f(11))
        frameStart = start.toFrame(pivot,rotation)
        frameRay = ray.toFrame(vec3(0,0,0),rotation)
        frameEnd = f(3).int
        inc node
      else: node = f(3).int
      continue
    if kind == NodeInner:
      var enter = 0'f32
      var leave = 1'f32
      if slab(lo,hi,frameStart,frameRay,enter,leave) and enter < leave and leave > 0 and enter < 1:
        inc node
      else: node = f(3).int
      continue
    let box = LightOccluder(low: lo, high: hi, center: vec3(f(8),0,f(9)),
      half: vec3(f(10),0,f(11)), rotation: vec2(f(12),f(13)),
      roofMode: (if kind >= 2: kind.int else: 0),
      roofProfile: vec4(f(14),f(15),f(16),f(17)))
    if box.occluderBlocksSegment(frameStart,frameStart+frameRay): return true
    node = f(3).int

proc build*(grid: ClusteredLights, lights: openArray[PointLight],
            occluders: openArray[LightOccluder], focus: Vec3, distance = 112'f32,
            rooms: openArray[EnvironmentRoom] = [],
            staticGeometry: ShadowGeometry = nil) =
  ## Stable nearest-first ordering makes overflow favour the explorer. A
  ## sphere/AABB test bins each light conservatively in all three dimensions.
  if grid.data.len < RowFloats*TextureHeight:
    grid.data.setLen(RowFloats*TextureHeight)
  grid.syncOccluders(occluders)
  var maxRadius = 0'f32
  for light in lights:
    if light.shadows and light.intensity > 0 and
        distance2(light.position,focus) < distance*distance:
      maxRadius = max(maxRadius,light.radius)
  # A stationary observer reuses the serialized static tree. A padded,
  # quantized region avoids rewriting it for every small camera movement.
  let region = vec3(floor(focus.x/16)*16,floor(focus.y/16)*16,floor(focus.z/16)*16)
  let radius = distance+maxRadius+28
  if grid.staticGeometry != staticGeometry or grid.shadowRegion != region or
      grid.shadowRadius != radius:
    grid.shadowNodeCount = 0
    if not staticGeometry.isNil:
      grid.writeStaticTree(staticGeometry,region,radius)
    grid.staticShadowNodes = grid.shadowNodeCount
    grid.staticDirty = true
    if grid.staticGeometry != staticGeometry: grid.nearCache.clear()
    grid.staticGeometry = staticGeometry
    grid.shadowRegion = region
    grid.shadowRadius = radius
  grid.shadowNodeCount = grid.staticShadowNodes
  if maxRadius > 0: grid.writeShadowTree(grid,region,radius)
  grid.data[ShadowTreeOffset] = (if maxRadius > 0: grid.shadowNodeCount.float32 else: 0'f32)
  let origin = vec3(floor(focus.x / ClusterCell) * ClusterCell - 128,
    floor(focus.y / ClusterCell) * ClusterCell - 64,
    floor(focus.z / ClusterCell) * ClusterCell - 128)
  grid.data[0] = origin.x
  grid.data[1] = origin.y
  grid.data[2] = origin.z
  grid.data[3] = ClusterCell
  # Admission, ids, near lists and cluster lists depend only on the cluster
  # origin and the light sites. Within one 8 m cell only the flicker and the
  # distance fade change, so those are rewritten each frame and the rest is
  # rebuilt when the explorer crosses a cell or a light appears or moves.
  var same = origin == grid.binOrigin and staticGeometry == grid.binGeometry and
    lights.len == grid.binLights.len
  if same:
    for i, light in lights:
      let was = grid.binLights[i]
      if light.position != was.position or light.radius != was.radius or
          light.shadows != was.shadows or (light.intensity > 0) != (was.intensity > 0):
        same = false
        break
  if not same:
    grid.binLights = @lights
    grid.binOrigin = origin
    grid.binGeometry = staticGeometry
    grid.lightsDirty = true
    # The shader reads a cluster's list only up to its count, and a light
    # record only through such a list. Clearing the counts is enough.
    for cluster in 0 ..< ClusterCount:
      grid.data[GridOffset + cluster * (ClusterLights + 1)] = 0
    grid.activeCount = 0
    grid.nearUsed = NearOffset
    grid.overflowCount = 0
    grid.admitted.setLen(0)
    grid.lightFlags.setLen(0)
    # Order from the centre of the explorer's cell; admit within a cell's
    # half diagonal beyond `distance`, which the per-frame fade covers.
    let center = origin + vec3(128 + ClusterCell*0.5f, 64 + ClusterCell*0.5f,
      128 + ClusterCell*0.5f)
    let reach = distance + ClusterCell*0.87f
    var order: seq[tuple[d: float32, index: int]]
    for i, light in lights:
      if light.radius > 0 and light.intensity > 0:
        let d = distance2(light.position, center)
        if d < reach*reach: order.add (d, i)
    order.sort(proc(a, b: tuple[d: float32, index: int]): int =
      result = cmp(a.d, b.d)
      if result == 0: result = cmp(a.index, b.index))
    for entry in order:
      if grid.activeCount == MaxPointLights: break
      let light = lights[entry.index]
      let id = grid.activeCount
      inc grid.activeCount
      grid.admitted.add entry.index
      # Shadow flag: 0 none, else 1 + the number of near occluders written.
      var shadowFlag = (if light.shadows: 1'f32 else: 0'f32)
      if light.shadows and not staticGeometry.isNil:
        let key = [int32(round(light.position.x*1000)),int32(round(light.position.y*1000)),
                   int32(round(light.position.z*1000))]
        if key notin grid.nearCache:
          if grid.nearCache.len >= 16384: grid.nearCache.clear() # bound memory while travelling
          grid.nearCache[key] = staticGeometry.nearestOccluders(light.position,
            reach = light.radius)
        let near = grid.nearCache[key]
        for k, box in near:
          grid.writeLeaf(NearOffset+(id*NearBoxes+k)*ShadowNodeStride, box)
        shadowFlag = 1'f32+near.len.float32
        grid.nearUsed = max(grid.nearUsed, NearOffset+(id*NearBoxes+near.len)*ShadowNodeStride)
      grid.lightFlags.add shadowFlag
      let local = (light.position - origin) * (1 / ClusterCell)
      let r = light.radius / ClusterCell
      let r2 = light.radius * light.radius
      for z in max(0, floor(local.z-r).int)..min(31, floor(local.z+r).int):
        let dz = max(max(z.float32 - local.z, 0'f32), local.z - (z+1).float32) * ClusterCell
        for y in max(0, floor(local.y-r).int)..min(15, floor(local.y+r).int):
          let dy = max(max(y.float32 - local.y, 0'f32), local.y - (y+1).float32) * ClusterCell
          for x in max(0, floor(local.x-r).int)..min(31, floor(local.x+r).int):
            let dx = max(max(x.float32 - local.x, 0'f32), local.x - (x+1).float32) * ClusterCell
            if dx*dx + dy*dy + dz*dz > r2: continue
            let at = GridOffset + (x + ClusterSide * (y + ClusterHeight * z)) * (ClusterLights + 1)
            let count = grid.data[at].int
            if count < ClusterLights:
              grid.data[at+1+count] = id.float32
              grid.data[at] = (count+1).float32
            else: inc grid.overflowCount
  for id, index in grid.admitted:
    let light = lights[index]
    let base = 4 + id * LightStride
    let fadeT = clamp((sqrt(distance2(light.position, focus)) - distance * 0.8f) / (distance * 0.2f), 0'f32, 1'f32)
    let fade = 1 - fadeT * fadeT * (3 - 2 * fadeT)
    grid.data[base] = light.position.x
    grid.data[base+1] = light.position.y
    grid.data[base+2] = light.position.z
    grid.data[base+3] = light.radius
    grid.data[base+4] = max(0'f32, light.color.x) * light.intensity * fade
    grid.data[base+5] = max(0'f32, light.color.y) * light.intensity * fade
    grid.data[base+6] = max(0'f32, light.color.z) * light.intensity * fade
    grid.data[base+7] = grid.lightFlags[id]

  # Rooms use the existing world-space index and texture binding. Only the
  # rooms overlapping a fragment's cluster are tested, regardless of where
  # the eye stands. Nearest-first admission keeps budget overflow stable.
  # They are rewritten only when the origin or a room (a door's
  # transmission, say) changes.
  if origin == grid.roomOrigin and rooms.len == grid.binRooms.len and
      rooms == grid.binRooms.toOpenArray(0, grid.binRooms.high):
    return
  grid.binRooms = @rooms
  grid.roomOrigin = origin
  grid.roomsDirty = true
  for cluster in 0 ..< ClusterCount:
    grid.data[RoomGridOffset + cluster * (ClusterRooms + 1)] = 0
  grid.roomCount = 0
  grid.roomOverflowCount = 0
  var nearRooms: seq[tuple[d: float32, index: int]]
  let extent = vec3(ClusterSide.float32 * ClusterCell,
    ClusterHeight.float32 * ClusterCell, ClusterSide.float32 * ClusterCell)
  for i, room in rooms:
    if room.high.x < origin.x or room.low.x > origin.x + extent.x or
        room.high.y < origin.y or room.low.y > origin.y + extent.y or
        room.high.z < origin.z or room.low.z > origin.z + extent.z:
      continue
    nearRooms.add (boxDistance2(focus, LightOccluder(low: room.low, high: room.high)), i)
  nearRooms.sort(proc(a,b: tuple[d: float32, index: int]): int =
    result = cmp(a.d,b.d)
    if result == 0: result = cmp(a.index,b.index))
  for candidate in nearRooms:
    if grid.roomCount == MaxEnvironmentRooms:
      inc grid.roomOverflowCount
      continue
    let room = rooms[candidate.index]
    let id = grid.roomCount
    inc grid.roomCount
    let base = RoomOffset + id * RoomStride
    for axis, value in [room.low.x, room.low.y, room.low.z,
                         room.high.x, room.high.y, room.high.z]:
      grid.data[base + axis] = value
    for axis, value in [room.center.x,room.center.z,room.half.x,room.half.z,
                         room.rotation.x,room.rotation.y]:
      grid.data[base + 8 + RoomPortals*10 + axis] = value
    let count = min(room.portals.len, RoomPortals)
    grid.data[base + 6] = count.float32
    for i in 0 ..< count:
      let portal = room.portals[i]
      for axis, value in [portal.low.x, portal.low.y, portal.low.z,
          portal.high.x, portal.high.y, portal.high.z,
          portal.inward.x, portal.inward.y, portal.inward.z, portal.transmission]:
        grid.data[base + 8 + i * 10 + axis] = value
    let lo = (room.low - origin) * (1 / ClusterCell)
    let hi = (room.high - origin) * (1 / ClusterCell)
    for z in max(0, floor(lo.z).int) .. min(31, floor(hi.z).int):
      for y in max(0, floor(lo.y).int) .. min(15, floor(hi.y).int):
        for x in max(0, floor(lo.x).int) .. min(31, floor(hi.x).int):
          let at = RoomGridOffset + (x + ClusterSide * (y + ClusterHeight * z)) * (ClusterRooms + 1)
          let n = grid.data[at].int
          if n < ClusterRooms:
            grid.data[at + 1 + n] = id.float32
            grid.data[at] = (n + 1).float32
          else: inc grid.roomOverflowCount

proc upload*(grid: ClusteredLights, cmd: CommandBuffer) =
  ## Rows that changed since the last present: light records always; light
  ## lists and near lists after a rebin; rooms after they changed; static
  ## shadow rows after a rewrite; the shadow count and dynamic rows always.
  var spans: seq[tuple[first, last: int]] # float ranges, end exclusive
  let used = ShadowNodeBase+grid.shadowNodeCount*ShadowNodeStride
  spans.add (0, GridOffset)
  if grid.lightsDirty:
    spans.add (GridOffset, RoomOffset)
    spans.add (NearOffset, max(grid.nearUsed, NearOffset+1))
  if grid.roomsDirty:
    spans.add (RoomOffset, ShadowTreeOffset)
  spans.add (ShadowTreeOffset, ShadowTreeOffset+1)
  if grid.staticDirty:
    spans.add (ShadowNodeBase, used)
  else:
    spans.add (ShadowNodeBase+grid.staticShadowNodes*ShadowNodeStride, used)
  grid.lightsDirty = false
  grid.roomsDirty = false
  grid.staticDirty = false
  var rows: seq[tuple[first, last: int]]
  for span in spans:
    if span.last <= span.first: continue
    rows.add (span.first div RowFloats, (span.last+RowFloats-1) div RowFloats)
  rows.sort(proc(a, b: tuple[first, last: int]): int = cmp(a.first, b.first))
  var merged: seq[tuple[first, last: int]]
  for row in rows:
    if merged.len > 0 and row.first <= merged[^1].last:
      merged[^1].last = max(merged[^1].last, row.last)
    else: merged.add row
  for row in merged:
    cmd.uploadPictureArea(grid.texture,addr grid.data[0],TextureWidth,
      0,row.first.uint32,TextureWidth,row.last.uint32,pixelBytes = 16)

func lightShadowBlocked*(grid: ClusteredLights, light: int, start, finish: Vec3): bool =
  ## CPU mirror of the shader's `lightShadowBlocked`: the light's near list,
  ## then the complete tree.
  let flag = grid.data[4 + light * LightStride + 7]
  for k in 0 ..< max(0, flag.int - 1):
    let at = NearOffset + (light * NearBoxes + k) * ShadowNodeStride
    template f(i: int): float32 = grid.data[at+i]
    let box = LightOccluder(low: vec3(f(0),f(1),f(2)), high: vec3(f(4),f(5),f(6)),
      center: vec3(f(8),0,f(9)), half: vec3(f(10),0,f(11)), rotation: vec2(f(12),f(13)),
      roofMode: (if f(7) >= 2: f(7).int else: 0),
      roofProfile: vec4(f(14),f(15),f(16),f(17)))
    if box.occluderBlocksSegment(start, finish): return true
  grid.shadowBlocked(start, finish)
