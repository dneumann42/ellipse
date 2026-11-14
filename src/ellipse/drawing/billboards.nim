import clustered
## Billboards: flat sprites standing upright in the world and turned to face
## the camera -- trees, grass, the clutter of a forest floor -- drawn in the
## hundreds of thousands. Each is one 52-byte instance in a GPU buffer that is
## uploaded once and drawn from every frame after, so a frame costs nothing on
## the CPU per sprite: the vertex stage builds the four corners of every
## instance itself, one draw call for each run of instances the caller asks
## for. A caller keeps its instances in runs it can cull together -- a chunk
## of ground each -- and asks only for the runs in view, and of a far run
## only for its first share (stored shuffled, any first share is an even
## thinning), each standing a little larger to fill the gaps.
##
## The sprites are cut out, not blended: a texel under half opacity is
## discarded and the rest are solid and write depth, so billboards need no
## sorting and stand in the occlusion pass like any other geometry. They
## live one to a layer of an array texture, standing on the bottom middle of
## their layer, so mipmapping never bleeds one sprite into the next. Up close
## texels magnify square, as pixel art should.

import std/[math, tables]

import ../platform/gpu
import geometry
import billboardcomposition
export BillboardLayers, noBillboardLayers
import fog

const
  MaxBillboardLayers* = 512 ## sprites one billboard atlas can hold

type
  BillboardInstance* = object
    ## One sprite in the world.
    position*: Vec3 ## the middle of its foot, world metres
    size*: Vec2 ## metres across and tall
    layer*: float32 ## which sprite of the atlas
    shade*: float32 ## brightness, 1 as painted: variety between neighbours
    phase*: float32 ## 0 .. 1, where in its sway it starts; 0 sways not at all
    ## when the sprite should stand still (a stone)
    blink*: float32 ## damage-flash intensity 0..1, applied as a red tint

  GpuBillboardInstance = object
    ## Extra render data stays out of the public/saveable sprite record.
    sprite: BillboardInstance
    uvRect: Vec4

  GpuLayeredBillboardInstance = object
    sprite: GpuBillboardInstance
    layers: Vec4
    rects: array[4, Vec4]

  BillboardAtlas* = object
    ## Sprites one to a layer, each standing on its layer's bottom middle,
    ## and where each one sits in its layer in texture coordinates.
    width*, height*: int ## one layer, in pixels
    layers*: int
    pixels*: seq[uint8] ## RGBA8, layer after layer, rows from the top
    rects*: seq[Vec4] ## per layer: u0, v0 (its top left), u1, v1

  BillboardBuffer* = ref object
    ## Instances resident on the GPU, uploaded at the present after they were
    ## handed over and drawn from every frame after.
    buffer: DynamicBuffer
    staged: seq[BillboardInstance]
    stagedOverlays: seq[BillboardLayers]
    sources: seq[BillboardInstance]
    overlays: seq[BillboardLayers]
    sourceMask: array[8, uint64]
    preparedFrame: uint64
    composedGeneration: uint64
    dirty: bool
    direct: bool
    count*: int

  BillboardOptions* = object
    time*: float32 ## seconds: the wind's clock
    wind*: float32 ## metres the top of a ten metre sprite sways
    cutoff*: float32 ## opacity under which a texel is cut away

  BillboardUniforms = object
    viewProj: Mat4
    eye: Vec4 # the eye, then the wind's clock
    right: Vec4 # the camera's right, flattened onto the ground; then wind
    light: Vec4 # toward the sun, intensity
    params: Vec4 # ambient, grow, cutoff, unused

  BillboardFragmentUniforms = object
    cut: Vec4 # cutoff, three unused
    fog: FogUniforms

  BillboardDepthUniforms = object
    nearFar, fogFade: Vec4 # the occlusion pass's block, then the cutoff
    cut: Vec4

  Draw = object
    buffer: BillboardBuffer
    first, count: int
    grow: float32

  BillboardPass* = ref object
    ## What the artist draws billboards with: the pipelines, the atlas on the
    ## GPU, and the runs asked for this frame.
    device: Device
    directLayers*: bool
    preparedDirectLayers: bool
    layeredPipeline, layeredDepthPipeline, layeredWirePipeline: Pipeline
    clusters: ClusteredLights
    emptyClustersStaged: bool
    pipeline, depthPipeline: Pipeline
    wireframePipeline: Pipeline ## the same sprites outlined, for the artist's
    ## wireframe frames
    sampler: Sampler
    pixelSampler: Sampler ## square texels, levels blended, for the retro look
    pixelated*: bool ## sprites sampled through `pixelSampler` this frame
    wireframe*: bool ## sprites drawn as their edges instead of their picture
    texture: Texture
    staged: BillboardAtlas
    atlasStaged: bool
    residentPixels: seq[uint8] # independent snapshot; callers may edit their atlas in place
    residentWidth, residentHeight, residentLayers, textureLayers: int
    atlasUploadCount*, mipmapLayerBuildCount*: int
    rects: array[MaxBillboardLayers, Vec4]
    compositions: CompositionCache
    sourceVersions: array[MaxBillboardLayers, uint64]
    uploadFrame: uint64
    uploads: seq[BillboardBuffer]
    draws: seq[Draw]
    options*: BillboardOptions

const
  BillboardAttributes*: seq[Attribute] = @[
    Attribute(location: 0, offset: 0, format: Float3),
    Attribute(location: 1, offset: 12, format: Float2),
    Attribute(location: 2, offset: 20, format: Float32),
    Attribute(location: 3, offset: 24, format: Float32),
    Attribute(location: 4, offset: 28, format: Float32),
    Attribute(location: 5, offset: 32, format: Float32),
    Attribute(location: 6, offset: 36, format: Float4),
  ]
  BillboardStride* = uint32 sizeof(GpuBillboardInstance)

  LayeredBillboardStride = uint32 sizeof(GpuLayeredBillboardInstance)
  LayeredBillboardAttributes = BillboardAttributes & @[
    Attribute(location: 7, offset: 52, format: Float4),
    Attribute(location: 8, offset: 68, format: Float4),
    Attribute(location: 9, offset: 84, format: Float4),
    Attribute(location: 10, offset: 100, format: Float4),
    Attribute(location: 11, offset: 116, format: Float4)]
  layeredVertexSpv = staticRead("shaders/spv/billboard_live.vert.spv")
  layeredFragmentSpv = staticRead("shaders/spv/billboard_live.frag.spv")
  layeredDepthSpv = staticRead("shaders/spv/billboard_live_depth.frag.spv")

  billboardVertexSpv = staticRead("shaders/spv/billboard.vert.spv")
  billboardFragmentSpv = staticRead("shaders/spv/billboard.frag.spv")
  billboardDepthSpv = staticRead("shaders/spv/billboard_depth.frag.spv")
  billboardWireSpv = staticRead("shaders/spv/billboard_wire.frag.spv")

static:
  doAssert sizeof(GpuLayeredBillboardInstance) == 132
  doAssert sizeof(BillboardInstance) == 36
  doAssert sizeof(GpuBillboardInstance) == 52

func newBillboardOptions*(wind = 0.25f, cutoff = 0.5f): BillboardOptions =
  BillboardOptions(wind: wind, cutoff: cutoff)

# The atlas ---------------------------------------------------------------------

func newBillboardAtlas*(width, height: int): BillboardAtlas =
  ## An empty atlas of `width` by `height` pixel layers.
  BillboardAtlas(width: width, height: height)

proc bleedColour(pixels: var seq[uint8], base, width, height: int) =
  ## Give every clear texel of one layer the colour of its nearest opaque
  ## texel, its opacity left at zero. The mip levels average colour and
  ## opacity alike, so without this a sprite's edges and every level below
  ## the first darken toward the black of the clear texels around it.
  var
    filled = newSeq[bool](width * height)
    queue = newSeqOfCap[int](width * height)
  for i in 0 ..< width * height:
    if pixels[base + i * 4 + 3] > 0:
      filled[i] = true
      queue.add i
  var head = 0
  while head < queue.len:
    let
      i = queue[head]
      x = i mod width
      y = i div width
    inc head
    for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)]:
      let (nx, ny) = (x + dx, y + dy)
      if nx < 0 or ny < 0 or nx >= width or ny >= height:
        continue
      let n = ny * width + nx
      if filled[n]:
        continue
      filled[n] = true
      copyMem(addr pixels[base + n * 4], addr pixels[base + i * 4], 3)
      queue.add n

func halved(pixels: seq[uint8], width, height, layers: int): seq[uint8] =
  ## The next mip level down, layer by layer: each texel the four above it,
  ## their colour weighted by their opacity so a clear texel adds none of
  ## its own. Four clear texels keep the colour bled into them.
  let
    w = max(width div 2, 1)
    h = max(height div 2, 1)
  result = newSeq[uint8](w * h * 4 * layers)
  for layer in 0 ..< layers:
    let
      source = layer * width * height * 4
      target = layer * w * h * 4
    for y in 0 ..< h:
      for x in 0 ..< w:
        var
          weighted: array[3, int]
          plain: array[3, int]
          alpha = 0
        for (dx, dy) in [(0, 0), (1, 0), (0, 1), (1, 1)]:
          let
            sx = min(x * 2 + dx, width - 1)
            sy = min(y * 2 + dy, height - 1)
            i = source + (sy * width + sx) * 4
            a = pixels[i + 3].int
          for c in 0 .. 2:
            weighted[c] += pixels[i + c].int * a
            plain[c] += pixels[i + c].int
          alpha += a
        let o = target + (y * w + x) * 4
        for c in 0 .. 2:
          result[o + c] = uint8(
            if alpha > 0: (weighted[c] + alpha div 2) div alpha
            else: (plain[c] + 2) div 4)
        result[o + 3] = uint8((alpha + 2) div 4)

proc addSprite*(atlas: var BillboardAtlas, width, height: int,
                pixels: openArray[uint8]): int =
  ## Stand a `width` by `height` RGBA8 sprite on the bottom middle of a new
  ## layer and return the layer. A sprite larger than a layer is cropped to
  ## its bottom middle; past `MaxBillboardLayers` it is refused with -1.
  if atlas.layers >= MaxBillboardLayers or width <= 0 or height <= 0 or
      pixels.len < width * height * 4:
    return -1
  let
    w = min(width, atlas.width)
    h = min(height, atlas.height)
    left = (atlas.width - w) div 2
    top = atlas.height - h
    srcLeft = (width - w) div 2
    srcTop = height - h
    layerBytes = atlas.width * atlas.height * 4
    base = atlas.layers * layerBytes
  atlas.pixels.setLen(base + layerBytes)
  for y in 0 ..< h:
    copyMem(addr atlas.pixels[base + ((top + y) * atlas.width + left) * 4],
            unsafeAddr pixels[((srcTop + y) * width + srcLeft) * 4], w * 4)
  atlas.pixels.bleedColour(base, atlas.width, atlas.height)
  atlas.rects.add vec4(
    left.float32 / atlas.width.float32, top.float32 / atlas.height.float32,
    (left + w).float32 / atlas.width.float32, 1.0f)
  result = atlas.layers
  inc atlas.layers

# Buffers -----------------------------------------------------------------------

proc validateLayers(count: int, overlays: seq[BillboardLayers]) =
  if overlays.len == 0: return
  if count != overlays.len:
    raise newException(ValueError, "each layered billboard needs one overlay set")
  for layers in overlays:
    for layer in layers:
      if layer < -1 or layer >= MaxBillboardLayers:
        raise newException(ValueError, "billboard overlay layer is outside the atlas")

proc stageInstances(buffer: BillboardBuffer, instances: sink seq[BillboardInstance],
                    overlays: sink seq[BillboardLayers]) =
  validateLayers(instances.len, overlays)
  buffer.count = instances.len
  buffer.staged = instances
  buffer.stagedOverlays = overlays
  buffer.sourceMask = default(array[8, uint64])
  for instance in buffer.staged:
    let layer = clamp(int(instance.layer + 0.5f), 0, MaxBillboardLayers-1)
    buffer.sourceMask[layer div 64] = buffer.sourceMask[layer div 64] or
      (1'u64 shl (layer mod 64))

proc newBillboardBuffer*(p: BillboardPass,
                         instances: sink seq[BillboardInstance],
                         overlays: sink seq[BillboardLayers] = @[]): BillboardBuffer =
  ## Hand `instances` to the GPU: they upload at the next present, and the
  ## buffer can be drawn from as soon as it is made.
  result = BillboardBuffer(
    buffer: newDynamicBuffer(p.device, {VertexData},
                             max(1, instances.len).uint32 * BillboardStride),
    count: instances.len,
  )
  result.stageInstances(instances, overlays)
  if result.count > 0:
    p.uploads.add result

proc restage*(p: BillboardPass, buffer: BillboardBuffer,
              instances: sink seq[BillboardInstance],
              overlays: sink seq[BillboardLayers] = @[]) =
  ## Rewrite a standing set's instances: uploaded at the next present, for
  ## billboards that move -- a wandering crowd, say.
  buffer.stageInstances(instances, overlays)
  if buffer.count > 0:
    p.uploads.add buffer

# The pass ----------------------------------------------------------------------

proc newBillboardPass*(device: Device, colorFormat: TextureFormat,
                       clusters: ClusteredLights = nil): BillboardPass =
  let
    vertex = newShader(device, billboardVertexSpv.toOpenArrayByte(0, billboardVertexSpv.high),
                       VertexShader, numUniformBuffers = 1)
    fragment = newShader(device, billboardFragmentSpv.toOpenArrayByte(0, billboardFragmentSpv.high),
                         FragmentShader, numUniformBuffers = 1, numSamplers = 2)
    depth = newShader(device, billboardDepthSpv.toOpenArrayByte(0, billboardDepthSpv.high),
                      FragmentShader, numUniformBuffers = 1, numSamplers = 1)
    wire = newShader(device, billboardWireSpv.toOpenArrayByte(0, billboardWireSpv.high),
                     FragmentShader, numUniformBuffers = 1)
  let
    layeredVertex = newShader(device, layeredVertexSpv.toOpenArrayByte(0,layeredVertexSpv.high),
      VertexShader, numUniformBuffers = 1)
    layeredFragment = newShader(device, layeredFragmentSpv.toOpenArrayByte(0,layeredFragmentSpv.high),
      FragmentShader, numUniformBuffers = 1, numSamplers = 2)
    layeredDepth = newShader(device, layeredDepthSpv.toOpenArrayByte(0,layeredDepthSpv.high),
      FragmentShader, numUniformBuffers = 1, numSamplers = 1)
  # Blending only shows at the fog's limit, where the sprites fade into the
  # sky: everywhere else a texel is either cut away or fully opaque.
  let spriteDesc = PipelineDesc(
    vertex: vertex, fragment: fragment,
    attributes: BillboardAttributes, stride: BillboardStride, instanced: true,
    colorFormat: colorFormat, depthFormat: Depth32, blend: true,
  )
  # The outlining sprite draws no picture, so it binds no sampler: an edge
  # through a cut-out sprite is mostly the transparent margin around it.
  var outlineDesc = spriteDesc.asWireframe()
  outlineDesc.fragment = wire
  let layeredDesc = PipelineDesc(vertex: layeredVertex, fragment: layeredFragment,
    attributes: LayeredBillboardAttributes, stride: LayeredBillboardStride, instanced: true,
    colorFormat: colorFormat, depthFormat: Depth32, blend: true)
  var layeredWireDesc = layeredDesc.asWireframe()
  layeredWireDesc.fragment = wire
  BillboardPass(
    device: device,
    layeredPipeline: newPipeline(device,layeredDesc),
    layeredWirePipeline: newPipeline(device,layeredWireDesc),
    layeredDepthPipeline: newPipeline(device,PipelineDesc(vertex:layeredVertex,fragment:layeredDepth,
      attributes:LayeredBillboardAttributes,stride:LayeredBillboardStride,instanced:true,
      colorFormat:Rgba8,depthFormat:Depth32)),
    compositions: initCompositionCache(MaxBillboardLayers),
    clusters: (if clusters.isNil: newClusteredLights(device) else: clusters),
    emptyClustersStaged: clusters.isNil,
    pipeline: newPipeline(device, spriteDesc),
    wireframePipeline: newPipeline(device, outlineDesc),
    depthPipeline: newPipeline(device, PipelineDesc(
      vertex: vertex, fragment: depth,
      attributes: BillboardAttributes, stride: BillboardStride, instanced: true,
      colorFormat: Rgba8, depthFormat: Depth32,
    )),
    sampler: newSampler(device, mipmaps = true, nearest = true),
    pixelSampler: newSampler(device, mipmaps = true, pixelated = true,
                             levelsBlended = true),
    options: newBillboardOptions(),
  )

proc changedAtlasRuns(p: BillboardPass, atlas: BillboardAtlas): seq[tuple[first, count: int]] =
  let layerBytes = atlas.width * atlas.height * 4
  let sameSize = p.residentWidth == atlas.width and p.residentHeight == atlas.height
  var first = -1
  for layer in 0 ..< atlas.layers:
    let changed = not sameSize or layer >= p.residentLayers or
      not equalMem(unsafeAddr atlas.pixels[layer * layerBytes],
        unsafeAddr p.residentPixels[layer * layerBytes], layerBytes)
    if changed and first < 0: first = layer
    if not changed and first >= 0:
      result.add (first, layer - first)
      first = -1
  if first >= 0: result.add (first, atlas.layers - first)

proc setAtlas*(p: BillboardPass, atlas: BillboardAtlas) =
  ## Identical pixels never regenerate mipmaps. Keep an independent resident
  ## snapshot to detect edits even when callers reuse the same sequence.
  if atlas.width <= 0 or atlas.height <= 0 or atlas.layers <= 0 or
      atlas.layers > MaxBillboardLayers or atlas.pixels.len < atlas.width * atlas.height * 4 * atlas.layers:
    return
  for i in 0 ..< MaxBillboardLayers:
    p.rects[i] = if i < atlas.rects.len: atlas.rects[i] else: vec4(0, 0, 1, 1)
  p.atlasStaged = p.changedAtlasRuns(atlas).len > 0
  p.staged = if p.atlasStaged: atlas else: BillboardAtlas()

proc queue*(p: BillboardPass, buffer: BillboardBuffer, first, count: int,
            grow = 1.0f) =
  ## Draw `count` instances of `buffer` from `first` this frame, each
  ## `grow` times its size.
  if buffer.isNil or count <= 0 or first < 0 or first >= buffer.count:
    return
  p.draws.add Draw(buffer: buffer, first: first,
                   count: min(count, buffer.count - first), grow: grow)

func queued*(p: BillboardPass): int =
  ## Instances asked for this frame.
  for draw in p.draws:
    result += draw.count

func pending*(p: BillboardPass): bool =
  p.draws.len > 0 and not p.texture.isNil

proc uploadPixels(p: BillboardPass, cmd: CommandBuffer, pixels: sink seq[uint8],
                  first, count: int) =
  var width = p.residentWidth
  var height = p.residentHeight
  var level = 0'u32
  while true:
    cmd.uploadLayers(p.texture, addr pixels[0], width.uint32, height.uint32,
      count.uint32, level, first.uint32)
    if width == 1 and height == 1: break
    pixels = halved(pixels, width, height, count)
    width = max(width div 2, 1)
    height = max(height div 2, 1)
    inc level
  p.mipmapLayerBuildCount += count

func textureCapacityFor(current, needed, maximum: int): int =
  # Ordinary atlas growth retains the original 512-layer ceiling. Extra
  # capacity is reserved only when simultaneously visible cached outfits
  # actually need it, never just because a 400-layer source atlas gains a frame.
  let limit = if needed <= MaxBillboardLayers: MaxBillboardLayers else: maximum
  min(limit, max(needed,max(64,current*2)))

proc upload*(p: BillboardPass, cmd: CommandBuffer) =
  ## Precompose on source/outfit changes. Every warm draw uses the ordinary
  ## 52-byte instance, single-texture shader, and the same color/depth cutoff.
  if p.emptyClustersStaged:
    p.clusters.upload(cmd)
    p.emptyClustersStaged = false
  inc p.uploadFrame
  let frame = p.uploadFrame
  var runs: seq[tuple[first, count: int]]
  var sizeChanged = false
  if p.atlasStaged:
    let atlas = p.staged
    runs = p.changedAtlasRuns(atlas)
    sizeChanged = p.residentWidth != atlas.width or p.residentHeight != atlas.height
    if sizeChanged:
      p.compositions = initCompositionCache(MaxBillboardLayers)
      for version in p.sourceVersions.mitems: inc version
    else:
      for run in runs:
        for layer in run.first ..< run.first+run.count: inc p.sourceVersions[layer]
    let bytes = atlas.width * atlas.height * 4 * atlas.layers
    p.residentPixels.setLen(bytes)
    for run in runs:
      let first = run.first * atlas.width * atlas.height * 4
      let count = run.count * atlas.width * atlas.height * 4
      copyMem(addr p.residentPixels[first], unsafeAddr atlas.pixels[first], count)
    p.residentWidth = atlas.width
    p.residentHeight = atlas.height
    p.residentLayers = atlas.layers
    p.staged = BillboardAtlas()
    p.atlasStaged = false
  if p.residentLayers <= 0: return
  let modeChanged = p.preparedDirectLayers != p.directLayers
  if modeChanged:
    # Cached output slots may have overwritten original layers. Restore them
    # before switching to direct sampling, and invalidate instance layouts.
    p.compositions = initCompositionCache(MaxBillboardLayers)
    runs = @[(first:0,count:p.residentLayers)]
    p.preparedDirectLayers = p.directLayers

  # Static scenery stores a layer bitset when staged. Protecting source slots
  # scans eight words per buffer, never every tree/grass instance each frame.
  var active: seq[BillboardBuffer]
  var normalMask: array[8, uint64]
  for draw in p.draws:
    let buffer = draw.buffer
    if buffer.preparedFrame == frame: continue
    buffer.preparedFrame = frame
    active.add buffer
  for buffer in p.uploads:
    if buffer.preparedFrame == frame: continue
    buffer.preparedFrame = frame
    active.add buffer
  for buffer in active:
    if buffer.staged.len > 0:
      buffer.sources = move buffer.staged
      buffer.overlays = move buffer.stagedOverlays
      buffer.dirty = true
    if buffer.overlays.len == 0:
      for i in 0 ..< normalMask.len: normalMask[i] = normalMask[i] or buffer.sourceMask[i]
    else:
      for i, source in buffer.sources:
        let base = clamp(int(source.layer+0.5f),0,MaxBillboardLayers-1)
        let key = compositionKey(base,buffer.overlays[i])
        if not key.hasClothing:
          normalMask[base div 64] = normalMask[base div 64] or (1'u64 shl (base mod 64))
  var protected: array[MaxBillboardLayers, bool]
  for layer in 0 ..< MaxBillboardLayers:
    protected[layer] = (normalMask[layer div 64] and (1'u64 shl (layer mod 64))) != 0
  for slot in p.compositions.protectSources(protected):
    if slot < p.residentLayers: runs.add (slot,1)

  # Pin the entire visible working set before allocating/evicting any output.
  for buffer in active:
    if p.directLayers or buffer.overlays.len == 0: continue
    for i, source in buffer.sources:
      let key = compositionKey(clamp(int(source.layer+0.5f),0,MaxBillboardLayers-1),buffer.overlays[i])
      if key.hasClothing: p.compositions.pin(key,frame)
  var neededLayers = p.residentLayers
  for buffer in active:
    if p.directLayers or buffer.overlays.len == 0: continue
    for i, source in buffer.sources:
      let key = compositionKey(clamp(int(source.layer+0.5f),0,MaxBillboardLayers-1),buffer.overlays[i])
      if key.hasClothing:
        let entry = p.compositions.resolve(key,protected,frame)
        neededLayers = max(neededLayers,entry.slot+1)

  if p.texture.isNil or sizeChanged or neededLayers > p.textureLayers:
    let previous = p.texture
    let previousLayers = p.textureLayers
    p.textureLayers = textureCapacityFor(p.textureLayers,neededLayers,p.compositions.maximum)
    var levels = 1'u32
    while (max(p.residentWidth,p.residentHeight).uint32 shr levels) > 0: inc levels
    p.texture = newLayeredTexture(p.device,p.residentWidth.uint32,
      p.residentHeight.uint32,p.textureLayers.uint32,levels,R8G8B8A8)
    if not previous.isNil and not sizeChanged:
      cmd.copyLayeredTexture(previous,p.texture,p.residentWidth.uint32,
        p.residentHeight.uint32,previousLayers.uint32,levels)
    else:
      runs = @[(first:0,count:p.residentLayers)]
      for entry in p.compositions.slots:
        if not entry.isNil: entry.resident = false
    if not previous.isNil: p.device.retire(previous)
  var filteredRuns: seq[tuple[first,count:int]]
  for run in runs:
    var first = -1
    for slot in run.first ..< run.first+run.count:
      let cached = slot < p.compositions.slots.len and not p.compositions.slots[slot].isNil
      let retain = cached and p.compositions.slots[slot].resident
      if not retain and first < 0: first = slot
      if retain and first >= 0:
        filteredRuns.add (first,slot-first)
        first = -1
    if first >= 0: filteredRuns.add (first,run.first+run.count-first)
  runs = move filteredRuns
  let bytes = p.residentWidth*p.residentHeight*4
  for run in runs:
    p.uploadPixels(cmd,p.residentPixels[run.first*bytes ..< (run.first+run.count)*bytes],run.first,run.count)
    for slot in run.first ..< min(run.first+run.count,p.compositions.slots.len):
      if not p.compositions.slots[slot].isNil: p.compositions.slots[slot].resident = false
  var uploaded = runs.len > 0
  for entry in p.compositions.slots:
    if entry.isNil or entry.used != frame: continue
    if entry.versionsMatch(p.sourceVersions): continue
    var pixels = composeBillboard(p.residentPixels,p.residentWidth,p.residentHeight,p.rects,entry.key)
    pixels.bleedColour(0,p.residentWidth,p.residentHeight)
    p.uploadPixels(cmd,move pixels,entry.slot,1)
    entry.rect = p.rects[entry.key[0]]
    entry.rememberVersions(p.sourceVersions)
    inc p.compositions.builds
    uploaded = true
  if uploaded: inc p.atlasUploadCount

  for buffer in active:
    var dirty = buffer.dirty
    if buffer.overlays.len > 0 and buffer.composedGeneration != p.compositions.generation: dirty = true
    if sizeChanged or modeChanged: dirty = true
    if not dirty or buffer.sources.len == 0: continue
    buffer.direct = p.directLayers and buffer.overlays.len > 0
    if buffer.direct:
      var instances = newSeq[GpuLayeredBillboardInstance](buffer.sources.len)
      for i, source in buffer.sources:
        let base = clamp(int(source.layer+0.5f),0,MaxBillboardLayers-1)
        instances[i].sprite = GpuBillboardInstance(sprite:source,uvRect:p.rects[base])
        let layers = buffer.overlays[i]
        instances[i].layers = vec4(layers[0].float32,layers[1].float32,
          layers[2].float32,layers[3].float32)
        for j, layer in layers:
          if layer >= 0: instances[i].rects[j] = p.rects[layer]
      cmd.upload(buffer.buffer,instances)
      buffer.dirty = false
      continue
    var instances = newSeq[GpuBillboardInstance](buffer.sources.len)
    for i, source in buffer.sources:
      let base = clamp(int(source.layer+0.5f),0,MaxBillboardLayers-1)
      var sprite = source
      var rect = p.rects[base]
      if buffer.overlays.len > 0:
        let key = compositionKey(base,buffer.overlays[i])
        if key.hasClothing:
          let entry = p.compositions.entries[key]
          sprite.layer = entry.slot.float32
          rect = entry.rect
      instances[i] = GpuBillboardInstance(sprite:sprite,uvRect:rect)
    cmd.upload(buffer.buffer,instances)
    buffer.composedGeneration = p.compositions.generation
    buffer.dirty = false
    if buffer.overlays.len == 0: buffer.sources.setLen(0)
  p.uploads.setLen(0)

func flatRight(view: Mat4): Vec3 =
  ## The camera's right, laid flat: billboards stand upright whatever the
  ## camera's pitch, all turned the same way so neighbours never cut through
  ## each other.
  let
    x = view.c[0]
    z = view.c[8]
    length = sqrt(x * x + z * z)
  if length < 1e-4f: vec3(1, 0, 0) else: vec3(x / length, 0, z / length)

proc uniformsFor(p: BillboardPass, view, viewProj: Mat4, eye, toLight: Vec3,
                 intensity, ambient, grow: float32): BillboardUniforms =
  let o = p.options
  BillboardUniforms(
    viewProj: viewProj,
    eye: vec4(eye, o.time),
    right: vec4(flatRight(view), o.wind),
    light: vec4(toLight, intensity),
    params: vec4(ambient, grow, o.cutoff, 0),
  )

proc drawRuns(p: BillboardPass, cmd: CommandBuffer, pass: RenderPass,
              pipeline: Pipeline, base: BillboardUniforms, pushFragment: proc () {.closure, gcsafe.},
              layeredPipeline: Pipeline = nil,
              textured: bool = true, clusters: ClusteredLights = nil) =
  pass.bindPipeline(pipeline)
  if textured:
    # Only the pipelines that sample the atlas bind it: SDL counts the
    # bindings against the samplers the pipeline declares.
    let sampler = if p.pixelated: p.pixelSampler else: p.sampler
    if not clusters.isNil and not p.wireframe:
      pass.bindFragmentSamplers([(texture: p.texture, sampler: sampler),
        (texture: clusters.texture, sampler: clusters.sampler)])
    else:
      pass.bindFragmentSamplers([(texture: p.texture, sampler: sampler)])
  pushFragment()
  var
    uniforms = base
    pushed = -1.0f
    direct = false
  for draw in p.draws:
    if direct != draw.buffer.direct:
      direct = draw.buffer.direct
      pass.bindPipeline(if direct: layeredPipeline else: pipeline)
      pushed = -1.0f
    if draw.grow != pushed:
      uniforms.params.y = draw.grow
      cmd.pushVertexUniforms(0, uniforms)
      pushed = draw.grow
    # each run is bound at its own first instance, so its draw counts from 0
    pass.bindVertexBuffers([BufferBinding(buffer: draw.buffer.buffer,
      offset: draw.first.uint32 * (if direct: LayeredBillboardStride else: BillboardStride))])
    pass.drawPrimitive(6, draw.count.uint32)

proc drawColour*(p: BillboardPass, cmd: CommandBuffer, pass: RenderPass,
                 view, viewProj: Mat4, eye, toLight: Vec3,
                 intensity, ambient: float32, fog: FogUniforms, clusters: ClusteredLights = nil) =
  ## Every run queued this frame, in colour, sunk into `fog`. Wireframe frames
  ## take the outlining pipeline: the sprite's quad, drawn without its picture.
  if not p.pending:
    return
  let fragment = BillboardFragmentUniforms(cut: vec4(p.options.cutoff, 0, 0, 0), fog: fog)
  p.drawRuns(cmd, pass,
    if p.wireframe: p.wireframePipeline else: p.pipeline,
    p.uniformsFor(view, viewProj, eye, toLight, intensity, ambient, 1),
    proc () = cmd.pushFragmentUniforms(0, fragment),
    layeredPipeline = (if p.wireframe: p.layeredWirePipeline else: p.layeredPipeline),
    textured = not p.wireframe,
    clusters = (if clusters.isNil: p.clusters else: clusters))

proc drawDepth*(p: BillboardPass, cmd: CommandBuffer, pass: RenderPass,
                view, viewProj: Mat4, eye: Vec3, near, far, fogFade: float32) =
  ## The same runs again into the occlusion pass's packed depth, cut out the
  ## same way, so trees shade the ground about them and are shaded in turn.
  if not p.pending:
    return
  let depth = BillboardDepthUniforms(
    nearFar: vec4(near, far, 0, 0), fogFade: vec4(fogFade, 0, 0, 0),
    cut: vec4(p.options.cutoff, 0, 0, 0))
  p.drawRuns(cmd, pass, p.depthPipeline,
    p.uniformsFor(view, viewProj, eye, vec3(0, 1, 0), 0, 0, 1),
    proc () = cmd.pushFragmentUniforms(0, depth), layeredPipeline = p.layeredDepthPipeline)

proc reset*(p: BillboardPass) =
  p.draws.setLen(0)
