## Screen-space ambient occlusion post chain:
## packed linear depth -> occlusion -> composite, over offscreen targets.

import ../platform/gpu
import geometry

type
  SsaoOptions* = object
    enabled*: bool
    radius*, strength*, bias*: float32

  SsaoUniforms = object
    resolutionRadius, projection, strengthBias: array[4, float32]

  DepthUniforms = object
    nearFar: array[4, float32]

  SsaoPass* = ref object
    device: Device
    sceneFormat: TextureFormat
    sampler: Sampler
    depthPipeline*: Pipeline
    occlusionPipeline, compositePipeline: Pipeline
    sceneColor, depthData, occlusion: Texture
    width, height: uint32

const
  fullscreenVertSpv = staticRead("shaders/spv/fullscreen.vert.spv")
  depthFragSpv = staticRead("shaders/spv/depth.frag.spv")
  ssaoFragSpv = staticRead("shaders/spv/ssao.frag.spv")
  compositeFragSpv = staticRead("shaders/spv/composite.frag.spv")

  # Packed depth just below the far plane: background never occludes.
  farClear: ClearColor = (0.75, 0.996, 0.996, 0.996)

func newSsaoOptions*(radius = 1.2'f32, strength = 0.8'f32, bias = 0.02'f32): SsaoOptions =
  ## `radius` is how far through the world a surface may reach to shade a
  ## neighbour: metres, so a corner reads as a corner whether the eye is a
  ## hand's width from it or a hill away. `strength` is how deep that shade
  ## goes, and `bias` the height a sample must clear the surface's plane
  ## before it counts -- enough to let flat ground pass for open sky.
  SsaoOptions(enabled: true, radius: radius, strength: strength, bias: bias)

proc newSsaoPass*(
  device: Device,
  meshVertex: Shader,
  sceneFormat: TextureFormat,
): SsaoPass =
  let
    fullscreenVertex = newShader(device, fullscreenVertSpv.toOpenArrayByte(0, fullscreenVertSpv.high), VertexShader)
    depthFragment = newShader(device, depthFragSpv.toOpenArrayByte(0, depthFragSpv.high), FragmentShader, numUniformBuffers = 1)
    occlusionFragment = newShader(device, ssaoFragSpv.toOpenArrayByte(0, ssaoFragSpv.high), FragmentShader, numUniformBuffers = 1, numSamplers = 1)
    compositeFragment = newShader(device, compositeFragSpv.toOpenArrayByte(0, compositeFragSpv.high), FragmentShader, numSamplers = 2)
  result = SsaoPass(
    device: device,
    sceneFormat: sceneFormat,
    sampler: newSampler(device),
    depthPipeline: newPipeline(device, PipelineDesc(
      vertex: meshVertex,
      fragment: depthFragment,
      attributes: VertexAttributes,
      stride: VertexStride,
      colorFormat: Rgba8,
      depthFormat: Depth32,
    )),
    occlusionPipeline: newPipeline(device, PipelineDesc(
      vertex: fullscreenVertex,
      fragment: occlusionFragment,
      colorFormat: Rgba8,
      hasDepth: false,
    )),
    compositePipeline: newPipeline(device, PipelineDesc(
      vertex: fullscreenVertex,
      fragment: compositeFragment,
      colorFormat: sceneFormat,
      hasDepth: false,
    )),
  )

proc ensureSize*(p: SsaoPass, width, height: uint32) =
  if width == 0 or height == 0 or (width == p.width and height == p.height):
    return
  for texture in [p.sceneColor, p.depthData, p.occlusion]:
    if not texture.isNil:
      p.device.retire(texture)
  p.width = width
  p.height = height
  p.sceneColor = newColorTexture(p.device, width, height, p.sceneFormat)
  p.depthData = newColorTexture(p.device, width, height, Rgba8)
  p.occlusion = newColorTexture(p.device, width, height, Rgba8)

proc beginScene*(p: SsaoPass, cmd: CommandBuffer, clearColor: ClearColor, depth: Texture): RenderPass =
  ## The scene pass renders into the offscreen colour target; artist code
  ## draws its batches, then ends the pass.
  cmd.beginRender(p.sceneColor, clearColor, depth)

proc beginDepth*(p: SsaoPass, cmd: CommandBuffer, depth: Texture): RenderPass =
  ## Geometry is replayed with the depth pipeline, packing linear view depth.
  let pass = cmd.beginRender(p.depthData, farClear, depth)
  pass.bindPipeline(p.depthPipeline)
  pass

func newDepthUniformPusher*(p: SsaoPass, cmd: CommandBuffer, near, far: float32): proc () =
  let uniforms = DepthUniforms(nearFar: [near, far, 0.0f, 0.0f])
  proc () = cmd.pushFragmentUniforms(0, uniforms)

proc runOcclusion*(p: SsaoPass, cmd: CommandBuffer, options: SsaoOptions,
    near, far, tanHalfFovY: float32) =
  ## `tanHalfFovY` is the tangent of the perspective frustum's half-angle:
  ## the one number the pass needs to turn a reach in metres into the stride
  ## in screen space it walks at this depth.
  let pass = cmd.beginRender(p.occlusion, (1.0f, 1.0f, 1.0f, 1.0f))
  pass.bindPipeline(p.occlusionPipeline)
  pass.bindFragmentSamplers([(texture: p.depthData, sampler: p.sampler)])
  cmd.pushFragmentUniforms(0, SsaoUniforms(
    resolutionRadius: [p.width.float32, p.height.float32, options.radius, 0.0f],
    projection: [near, far, tanHalfFovY, 0.0f],
    strengthBias: [options.strength, options.bias, 0.0f, 0.0f],
  ))
  pass.drawPrimitive(3)
  pass.endRender()

proc runComposite*(p: SsaoPass, cmd: CommandBuffer, target: Texture) =
  let pass = cmd.beginRender(target, (0.0f, 0.0f, 0.0f, 1.0f))
  pass.bindPipeline(p.compositePipeline)
  pass.bindFragmentSamplers([
    (texture: p.sceneColor, sampler: p.sampler),
    (texture: p.occlusion, sampler: p.sampler),
  ])
  pass.drawPrimitive(3)
  pass.endRender()
