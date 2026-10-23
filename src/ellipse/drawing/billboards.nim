## Billboards: flat sprites standing upright in the world and turned to face
## the camera -- trees, grass, the clutter of a forest floor -- drawn in the
## hundreds of thousands. Each is one 32-byte instance in a GPU buffer that is
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

import std/math

import ../platform/gpu
import geometry
import fog

const
  MaxBillboardLayers* = 16 ## sprites one billboard atlas can hold

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
    rects: array[MaxBillboardLayers, Vec4]

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
    pipeline, depthPipeline: Pipeline
    wireframePipeline: Pipeline ## the same sprites outlined, for the artist's
    ## wireframe frames
    sampler: Sampler
    pixelSampler: Sampler ## no filter at all, for the retro look
    pixelated*: bool ## sprites sampled through `pixelSampler` this frame
    wireframe*: bool ## sprites drawn as their edges instead of their picture
    texture: Texture
    staged: BillboardAtlas
    atlasStaged: bool
    rects: array[MaxBillboardLayers, Vec4]
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
  ]
  BillboardStride* = uint32 sizeof(BillboardInstance)

  billboardVertexSpv = staticRead("shaders/spv/billboard.vert.spv")
  billboardFragmentSpv = staticRead("shaders/spv/billboard.frag.spv")
  billboardDepthSpv = staticRead("shaders/spv/billboard_depth.frag.spv")
  billboardWireSpv = staticRead("shaders/spv/billboard_wire.frag.spv")

static:
  doAssert sizeof(BillboardInstance) == 36

func newBillboardOptions*(wind = 0.25f, cutoff = 0.5f): BillboardOptions =
  BillboardOptions(wind: wind, cutoff: cutoff)

# The atlas ---------------------------------------------------------------------

func newBillboardAtlas*(width, height: int): BillboardAtlas =
  ## An empty atlas of `width` by `height` pixel layers.
  BillboardAtlas(width: width, height: height)

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
  atlas.rects.add vec4(
    left.float32 / atlas.width.float32, top.float32 / atlas.height.float32,
    (left + w).float32 / atlas.width.float32, 1.0f)
  result = atlas.layers
  inc atlas.layers

# Buffers -----------------------------------------------------------------------

proc newBillboardBuffer*(p: BillboardPass,
                         instances: sink seq[BillboardInstance]): BillboardBuffer =
  ## Hand `instances` to the GPU: they upload at the next present, and the
  ## buffer can be drawn from as soon as it is made.
  result = BillboardBuffer(
    buffer: newDynamicBuffer(p.device, {VertexData},
                             max(1, instances.len).uint32 * BillboardStride),
    count: instances.len,
  )
  result.staged = instances
  if result.count > 0:
    p.uploads.add result

proc restage*(p: BillboardPass, buffer: BillboardBuffer,
              instances: sink seq[BillboardInstance]) =
  ## Rewrite a standing set's instances: uploaded at the next present, for
  ## billboards that move -- a wandering crowd, say.
  buffer.count = instances.len
  buffer.staged = instances
  if instances.len > 0:
    p.uploads.add buffer

# The pass ----------------------------------------------------------------------

proc newBillboardPass*(device: Device, colorFormat: TextureFormat): BillboardPass =
  let
    vertex = newShader(device, billboardVertexSpv.toOpenArrayByte(0, billboardVertexSpv.high),
                       VertexShader, numUniformBuffers = 1)
    fragment = newShader(device, billboardFragmentSpv.toOpenArrayByte(0, billboardFragmentSpv.high),
                         FragmentShader, numUniformBuffers = 1, numSamplers = 1)
    depth = newShader(device, billboardDepthSpv.toOpenArrayByte(0, billboardDepthSpv.high),
                      FragmentShader, numUniformBuffers = 1, numSamplers = 1)
    wire = newShader(device, billboardWireSpv.toOpenArrayByte(0, billboardWireSpv.high),
                     FragmentShader, numUniformBuffers = 1)
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
  BillboardPass(
    device: device,
    pipeline: newPipeline(device, spriteDesc),
    wireframePipeline: newPipeline(device, outlineDesc),
    depthPipeline: newPipeline(device, PipelineDesc(
      vertex: vertex, fragment: depth,
      attributes: BillboardAttributes, stride: BillboardStride, instanced: true,
      colorFormat: Rgba8, depthFormat: Depth32,
    )),
    sampler: newSampler(device, mipmaps = true, nearest = true),
    pixelSampler: newSampler(device, mipmaps = true, pixelated = true),
    options: newBillboardOptions(),
  )

proc setAtlas*(p: BillboardPass, atlas: BillboardAtlas) =
  ## Stage the sprites billboards are drawn with; uploaded and mipmapped at
  ## the next present.
  if atlas.layers <= 0 or atlas.pixels.len < atlas.width * atlas.height * 4 * atlas.layers:
    return
  p.staged = atlas
  p.atlasStaged = true
  for i in 0 ..< MaxBillboardLayers:
    p.rects[i] = if i < atlas.rects.len: atlas.rects[i] else: vec4(0, 0, 1, 1)

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

proc upload*(p: BillboardPass, cmd: CommandBuffer) =
  ## Copy what was staged since the last present onto the GPU: before any
  ## render pass opens, as copies must be.
  if p.atlasStaged:
    if not p.texture.isNil:
      p.device.retire(p.texture)
    var levels = 1'u32
    while (max(p.staged.width, p.staged.height).uint32 shr levels) > 0:
      inc levels
    p.texture = newLayeredTexture(p.device, p.staged.width.uint32,
      p.staged.height.uint32, p.staged.layers.uint32, levels, R8G8B8A8)
    cmd.uploadLayers(p.texture, addr p.staged.pixels[0], p.staged.width.uint32,
      p.staged.height.uint32, p.staged.layers.uint32)
    cmd.generateMipmaps(p.texture)
    p.staged = BillboardAtlas()
    p.atlasStaged = false
  for buffer in p.uploads:
    if buffer.staged.len > 0:
      cmd.upload(buffer.buffer, buffer.staged)
      buffer.staged = @[]
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
    rects: p.rects,
  )

proc drawRuns(p: BillboardPass, cmd: CommandBuffer, pass: RenderPass,
              pipeline: Pipeline, base: BillboardUniforms, pushFragment: proc (),
              textured: bool = true) =
  pass.bindPipeline(pipeline)
  if textured:
    # Only the pipelines that sample the atlas bind it: SDL counts the
    # bindings against the samplers the pipeline declares.
    let sampler = if p.pixelated: p.pixelSampler else: p.sampler
    pass.bindFragmentSamplers([(texture: p.texture, sampler: sampler)])
  pushFragment()
  var
    uniforms = base
    pushed = -1.0f
  for draw in p.draws:
    if draw.grow != pushed:
      uniforms.params.y = draw.grow
      cmd.pushVertexUniforms(0, uniforms)
      pushed = draw.grow
    # each run is bound at its own first instance, so its draw counts from 0
    pass.bindVertexBuffers([BufferBinding(buffer: draw.buffer.buffer,
      offset: draw.first.uint32 * BillboardStride)])
    pass.drawPrimitive(6, draw.count.uint32)

proc drawColour*(p: BillboardPass, cmd: CommandBuffer, pass: RenderPass,
                 view, viewProj: Mat4, eye, toLight: Vec3,
                 intensity, ambient: float32, fog: FogUniforms) =
  ## Every run queued this frame, in colour, sunk into `fog`. Wireframe frames
  ## take the outlining pipeline: the sprite's quad, drawn without its picture.
  if not p.pending:
    return
  let fragment = BillboardFragmentUniforms(cut: vec4(p.options.cutoff, 0, 0, 0), fog: fog)
  p.drawRuns(cmd, pass,
    if p.wireframe: p.wireframePipeline else: p.pipeline,
    p.uniformsFor(view, viewProj, eye, toLight, intensity, ambient, 1),
    proc () = cmd.pushFragmentUniforms(0, fragment))

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
    proc () = cmd.pushFragmentUniforms(0, depth))

proc reset*(p: BillboardPass) =
  p.draws.setLen(0)
