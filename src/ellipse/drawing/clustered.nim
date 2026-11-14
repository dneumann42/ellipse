## CPU-binned world-space clustered forward lights. Fixed budgets bound both
## light lists and upload size; shared BVH shadows need no per-light passes.
import std/[algorithm, math]
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
  MaxShadowNodes = 262144
  ShadowNodeStride = 14
  TextureWidth = 1024
  TextureHeight = (ShadowTreeOffset + 1 + MaxShadowNodes * ShadowNodeStride + TextureWidth - 1) div TextureWidth

type
  PointLight* = object
    position*, color*: Vec3
    radius*, intensity*: float32
    shadows*: bool
  LightOccluder* = object
    low*, high*: Vec3 ## world bounds for BVH traversal
    center*, half*: Vec3 ## exact local box for rotated geometry
    rotation*: Vec2 ## cosine/sine; zero means axis aligned
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
  ShadowGeometry* = ref object
    ## Immutable CPU spatial index, prepared before interactive rendering.
    index: ClusteredLights
  ClusteredLights* = ref object
    indexedBoxes: seq[LightOccluder]
    boxOrder: seq[int]
    boxNodes: seq[OccluderNode]
    staticGeometry: ShadowGeometry
    staticShadowNodes: int
    shadowRegion: Vec3
    shadowRadius: float32
    indexBuilds*: int ## diagnostic: dynamic/legacy index rebuilds
    texture*: gpu.Texture
    sampler*: Sampler
    data*: seq[float32]
    activeCount*, overflowCount*: int
    shadowNodeCount*: int
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
  ClusteredLights(texture: newPictureTexture(device, TextureWidth, TextureHeight, R32Float),
    sampler: newSampler(device, nearest = true),
    data: newSeq[float32](TextureWidth * TextureHeight))

func distance2(a, b: Vec3): float32 =
  let d = a - b
  dot(d, d)

func boxDistance2(p: Vec3, b: LightOccluder): float32 {.inline.} =
  # Scalar form avoids constructing temporary vectors in the hot traversal.
  let x = max(max(b.low.x - p.x, 0'f32), p.x - b.high.x)
  let y = max(max(b.low.y - p.y, 0'f32), p.y - b.high.y)
  let z = max(max(b.low.z - p.z, 0'f32), p.z - b.high.z)
  x*x + y*y + z*z

proc buildBoxNode(grid: ClusteredLights, first, count: int): int =
  var bounds = grid.indexedBoxes[grid.boxOrder[first]]
  for j in first + 1 ..< first + count:
    let box = grid.indexedBoxes[grid.boxOrder[j]]
    bounds.low = vec3(min(bounds.low.x, box.low.x), min(bounds.low.y, box.low.y), min(bounds.low.z, box.low.z))
    bounds.high = vec3(max(bounds.high.x, box.high.x), max(bounds.high.y, box.high.y), max(bounds.high.z, box.high.z))
  result = grid.boxNodes.len
  grid.boxNodes.add OccluderNode(bounds: bounds, first: first, count: count, left: -1, right: -1)
  if count <= 8: return
  let size = bounds.high - bounds.low
  let axis = if size.x >= size.y and size.x >= size.z: 0 elif size.y >= size.z: 1 else: 2
  grid.boxOrder.toOpenArray(first, first + count - 1).sort(proc(a, b: int): int =
    let aa = grid.indexedBoxes[a]
    let bb = grid.indexedBoxes[b]
    let ca = if axis == 0: aa.low.x + aa.high.x elif axis == 1: aa.low.y + aa.high.y else: aa.low.z + aa.high.z
    let cb = if axis == 0: bb.low.x + bb.high.x elif axis == 1: bb.low.y + bb.high.y else: bb.low.z + bb.high.z
    result = cmp(ca, cb)
    if result == 0: result = cmp(a, b))
  let half = count div 2
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

proc prepareShadowGeometry*(boxes: openArray[LightOccluder]): ShadowGeometry =
  ## CPU-only. The result is immutable and may be prepared on a loader thread.
  result = ShadowGeometry(index: ClusteredLights())
  result.index.syncOccluders(boxes)

proc writeShadowTree(grid: ClusteredLights, source: ClusteredLights,
                     focus: Vec3, radius: float32) =
  # Threaded BVH: each node stores its escape index. The GPU can traverse
  # the complete nearby scene without a stack or a per-light wall budget.
  proc emit(bounds: LightOccluder, leaf: bool): int =
    if grid.shadowNodeCount >= MaxShadowNodes:
      raise newException(ValueError, "Nearby light shadow geometry exceeds texture capacity")
    result = grid.shadowNodeCount
    inc grid.shadowNodeCount
    let at = ShadowTreeOffset + 1 + result * ShadowNodeStride
    for i, value in [bounds.low.x,bounds.low.y,bounds.low.z,
                     bounds.high.x,bounds.high.y,bounds.high.z]:
      grid.data[at+i] = value
    grid.data[at+7] = (if leaf: 1'f32 else: 0'f32)
    for i, value in [bounds.center.x,bounds.center.z,bounds.half.x,
                     bounds.half.z,bounds.rotation.x,bounds.rotation.y]:
      grid.data[at+8+i] = value
  proc finish(index: int) =
    grid.data[ShadowTreeOffset+1+index*ShadowNodeStride+6] = grid.shadowNodeCount.float32
  proc visit(index: int) =
    let node = source.boxNodes[index]
    if boxDistance2(focus,node.bounds) > radius*radius: return
    let parent = emit(node.bounds,false)
    if node.left >= 0:
      visit(node.left)
      visit(node.right)
    else:
      for i in node.first..<node.first+node.count:
        let box = source.indexedBoxes[source.boxOrder[i]]
        if boxDistance2(focus,box) > radius*radius: continue
        let leaf = emit(box,true)
        finish(leaf)
    finish(parent)
  if source.boxNodes.len > 0: visit(0)

proc build*(grid: ClusteredLights, lights: openArray[PointLight],
            occluders: openArray[LightOccluder], focus: Vec3, distance = 112'f32,
            rooms: openArray[EnvironmentRoom] = [],
            staticGeometry: ShadowGeometry = nil) =
  ## Stable nearest-first ordering makes overflow favour the explorer. A
  ## sphere/AABB test bins each light conservatively in all three dimensions.
  if grid.data.len < TextureWidth*TextureHeight:
    grid.data.setLen(TextureWidth*TextureHeight)
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
      grid.writeShadowTree(staticGeometry.index,region,radius)
    grid.staticShadowNodes = grid.shadowNodeCount
    grid.staticGeometry = staticGeometry
    grid.shadowRegion = region
    grid.shadowRadius = radius
  grid.shadowNodeCount = grid.staticShadowNodes
  if maxRadius > 0: grid.writeShadowTree(grid,region,radius)
  grid.data[ShadowTreeOffset] = (if maxRadius > 0: grid.shadowNodeCount.float32 else: 0'f32)
  # The shader reads a cluster's list only up to its count, and a light or
  # room record only through such a list. Clearing the counts is enough;
  # zeroing the whole ~3 MB texture each frame is not needed.
  for cluster in 0 ..< ClusterCount:
    grid.data[GridOffset + cluster * (ClusterLights + 1)] = 0
    grid.data[RoomGridOffset + cluster * (ClusterRooms + 1)] = 0
  grid.activeCount = 0
  grid.overflowCount = 0
  grid.roomCount = 0
  grid.roomOverflowCount = 0
  let origin = vec3(floor(focus.x / ClusterCell) * ClusterCell - 128,
    floor(focus.y / ClusterCell) * ClusterCell - 64,
    floor(focus.z / ClusterCell) * ClusterCell - 128)
  grid.data[0] = origin.x
  grid.data[1] = origin.y
  grid.data[2] = origin.z
  grid.data[3] = ClusterCell
  var sorted: seq[PointLight]
  for light in lights:
    if light.radius > 0 and light.intensity > 0 and
        distance2(light.position, focus) < distance * distance:
      sorted.add light
  sorted.sort(proc(a, b: PointLight): int = cmp(distance2(a.position, focus), distance2(b.position, focus)))
  for light in sorted:
    if grid.activeCount == MaxPointLights: break
    let id = grid.activeCount
    inc grid.activeCount
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
    grid.data[base+7] = (if light.shadows: 1'f32 else: 0'f32)
    let local = (light.position - origin) * (1 / ClusterCell)
    let r = light.radius / ClusterCell
    for z in max(0, floor(local.z-r).int)..min(31, floor(local.z+r).int):
      for y in max(0, floor(local.y-r).int)..min(15, floor(local.y+r).int):
        for x in max(0, floor(local.x-r).int)..min(31, floor(local.x+r).int):
          let low = origin + vec3(x.float32, y.float32, z.float32) * ClusterCell
          if boxDistance2(light.position, LightOccluder(low: low,
              high: low + vec3(ClusterCell, ClusterCell, ClusterCell))) > light.radius * light.radius:
            continue
          let at = GridOffset + (x + ClusterSide * (y + ClusterHeight * z)) * (ClusterLights + 1)
          let count = grid.data[at].int
          if count < ClusterLights:
            grid.data[at+1+count] = id.float32
            grid.data[at] = (count+1).float32
          else: inc grid.overflowCount

  # Rooms use the existing world-space index and texture binding. Only the
  # rooms overlapping a fragment's cluster are tested, regardless of where
  # the eye stands. Nearest-first admission keeps budget overflow stable.
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
  let used = ShadowTreeOffset+1+grid.shadowNodeCount*ShadowNodeStride
  let rows = (used+TextureWidth-1) div TextureWidth
  cmd.uploadPicture(grid.texture,addr grid.data[0],TextureWidth,rows.uint32)
