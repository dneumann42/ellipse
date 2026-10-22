## Sprite planes: textured quads standing where the caller lays them -- a
## held weapon in a first-person view, a painted sign, a framed portrait.
## Unlike billboards they never turn to meet the eye: the caller hands over
## four world corners and the picture rides the plane they define, tilting
## and squashing in perspective like any other geometry. A texel under the
## cut is discarded and the rest blend, so transparency is the sprite's own,
## respected rather than approximated. One texture serves every plane staged
## since the last; the geometry is small -- hands of quads, not forests --
## and uploads fresh each frame.

import ../platform/gpu
import fog
import geometry

type
  PlaneVertex = object
    position: Vec3
    uv: Vec2
    color: Vec4

  PlaneUniforms = object
    viewProj: Mat4
    params: Vec4 # x: the cut; three unused

  PlaneFragmentUniforms = object
    fog: FogUniforms
    cut: Vec4

  PlaneDepthUniforms = object
    nearFar, fogFade, cut: Vec4

  PlanePass* = ref object
    ## What the artist draws planes with: the pipelines, the sprite on the
    ## GPU, and the quads asked for this frame.
    device: Device
    pipeline, depthPipeline: Pipeline
    sampler: Sampler
    pixelSampler: Sampler ## no filter at all, for the retro look
    pixelated*: bool ## the sprite sampled texel by texel this frame
    cutoff*: float32 ## opacity under which a texel is cut away
    texture: gpu.Texture
    stagedBytes: seq[uint8]
    stagedWidth, stagedHeight: int
    staged: bool
    vertices: seq[PlaneVertex]
    indices: seq[uint32]
    vertexBuffer, indexBuffer: DynamicBuffer

const
  PlaneAttributes*: seq[Attribute] = @[
    Attribute(location: 0, offset: 0, format: Float3),
    Attribute(location: 1, offset: 12, format: Float2),
    Attribute(location: 2, offset: 20, format: Float4),
  ]
  PlaneStride* = uint32 sizeof(PlaneVertex)

  planeVertexSpv = staticRead("shaders/spv/plane.vert.spv")
  planeFragmentSpv = staticRead("shaders/spv/plane.frag.spv")
  planeDepthSpv = staticRead("shaders/spv/plane_depth.frag.spv")

static:
  doAssert sizeof(PlaneVertex) == 36

proc newPlanePass*(device: Device, colorFormat: TextureFormat): PlanePass =
  let
    vertex = newShader(device, planeVertexSpv.toOpenArrayByte(0, planeVertexSpv.high),
                       VertexShader, numUniformBuffers = 1)
    fragment = newShader(device, planeFragmentSpv.toOpenArrayByte(0, planeFragmentSpv.high),
                         FragmentShader, numUniformBuffers = 1, numSamplers = 1)
    depth = newShader(device, planeDepthSpv.toOpenArrayByte(0, planeDepthSpv.high),
                      FragmentShader, numUniformBuffers = 1, numSamplers = 1)
  PlanePass(
    device: device,
    pipeline: newPipeline(device, PipelineDesc(
      vertex: vertex, fragment: fragment,
      attributes: PlaneAttributes, stride: PlaneStride,
      colorFormat: colorFormat, depthFormat: Depth32, blend: true,
    )),
    depthPipeline: newPipeline(device, PipelineDesc(
      vertex: vertex, fragment: depth,
      attributes: PlaneAttributes, stride: PlaneStride,
      colorFormat: Rgba8, depthFormat: Depth32,
    )),
    sampler: newSampler(device),
    pixelSampler: newSampler(device, pixelated = true),
    cutoff: 0.5f,
    vertexBuffer: newDynamicBuffer(device, {VertexData}, 1024),
    indexBuffer: newDynamicBuffer(device, {IndexData}, 1024),
  )

proc setTexture*(p: PlanePass, width, height: int, pixels: openArray[uint8]) =
  ## Stage the RGBA8 sheet every plane samples, uploaded at the next present.
  if width <= 0 or height <= 0 or pixels.len < width * height * 4:
    return
  p.stagedBytes.setLen(width * height * 4)
  copyMem(addr p.stagedBytes[0], unsafeAddr pixels[0], p.stagedBytes.len)
  p.stagedWidth = width
  p.stagedHeight = height
  p.staged = true

proc queueQuad*(p: PlanePass, corners: array[4, Vec3], uv: array[4, Vec2],
                color: Vec4) =
  ## Ask for a plane this frame: corners in winding order, the picture's
  ## uv at each, and the colour every texel is tinted by.
  if p.texture.isNil:
    return
  let first = p.vertices.len.uint32
  for k in 0 ..< 4:
    p.vertices.add PlaneVertex(position: corners[k], uv: uv[k], color: color)
  p.indices.add [first, first + 1, first + 2, first, first + 2, first + 3]

func queued*(p: PlanePass): int =
  ## Vertices asked for this frame.
  p.vertices.len

func pending*(p: PlanePass): bool =
  p.indices.len > 0 and not p.texture.isNil

proc upload*(p: PlanePass, cmd: CommandBuffer) =
  ## Copy what was staged since the last present onto the GPU: before any
  ## render pass opens, as copies must be.
  if p.staged:
    if not p.texture.isNil:
      p.device.retire(p.texture)
    p.texture = newPictureTexture(p.device, p.stagedWidth.uint32,
      p.stagedHeight.uint32, R8G8B8A8)
    cmd.uploadPicture(p.texture, addr p.stagedBytes[0], p.stagedWidth.uint32,
      p.stagedHeight.uint32)
    p.stagedBytes = @[]
    p.staged = false
  if p.vertices.len > 0:
    cmd.upload(p.vertexBuffer, p.vertices)
    cmd.upload(p.indexBuffer, p.indices)

proc drawColour*(p: PlanePass, cmd: CommandBuffer, pass: RenderPass,
                 viewProj: Mat4, fog: FogUniforms) =
  ## Every plane asked for this frame, in one indexed draw.
  if not p.pending:
    return
  let sampler = if p.pixelated: p.pixelSampler else: p.sampler
  pass.bindPipeline(p.pipeline)
  pass.bindVertexBuffers([BufferBinding(buffer: p.vertexBuffer)])
  pass.bindIndexBuffer(p.indexBuffer)
  pass.bindFragmentSamplers([(texture: p.texture, sampler: sampler)])
  cmd.pushVertexUniforms(0, PlaneUniforms(
    viewProj: viewProj, params: vec4(p.cutoff, 0, 0, 0)))
  cmd.pushFragmentUniforms(0, PlaneFragmentUniforms(
    fog: fog, cut: vec4(p.cutoff, 0, 0, 0)))
  pass.drawIndexed(p.indices.len.uint32)

proc drawDepth*(p: PlanePass, cmd: CommandBuffer, pass: RenderPass,
                viewProj: Mat4, near, far, fogFade: float32) =
  ## The same quads again into the occlusion pass's packed depth, cut out
  ## the same way.
  if not p.pending:
    return
  pass.bindPipeline(p.depthPipeline)
  pass.bindVertexBuffers([BufferBinding(buffer: p.vertexBuffer)])
  pass.bindIndexBuffer(p.indexBuffer)
  pass.bindFragmentSamplers([(texture: p.texture, sampler: p.sampler)])
  cmd.pushVertexUniforms(0, PlaneUniforms(
    viewProj: viewProj, params: vec4(p.cutoff, 0, 0, 0)))
  cmd.pushFragmentUniforms(0, PlaneDepthUniforms(
    nearFar: vec4(near, far, 0, 0), fogFade: vec4(fogFade, 0, 0, 0),
    cut: vec4(p.cutoff, 0, 0, 0)))
  pass.drawIndexed(p.indices.len.uint32)

proc reset*(p: PlanePass) =
  p.vertices.setLen(0)
  p.indices.setLen(0)
