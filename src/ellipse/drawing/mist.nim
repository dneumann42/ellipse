## Mist: ground fog drifting through the world as soft billboards.
##
## A field of puffs, each one a camera-facing ellipse of haze, drawn in a
## single instanced call at the end of the scene pass. The billboards never
## write depth -- they test against the world and blend through each other,
## so overlapping puffs blob into one body of fog instead of stacking as
## quads -- and the fragment stage dithers their alpha, which is what makes
## the seams between neighbours vanish. Colour rides the scene's own fog
## vectors, so a mist field takes the light of whatever haze the environment
## carries: rose at sunset, cellar-dark in a crypt.
##
## Everything is shaped in the shader from a world-locked noise field, so
## the game hands over nothing but positions and knobs: no textures, no
## atlases, and no per-puff upload beyond 32 bytes an instance.

import std/[algorithm, math]

import ../platform/gpu
import fog
import geometry

type
  MistOptions* = object
    time*: float32 ## seconds: the clock the noise drifts and puffs sway by
    opacity*: float32 ## master coverage over every puff, 0 to hide the field
    scale*: float32 ## metres of noise pattern: big rolls or small wisps
    detail*: float32 ## 0..1 how much of the body the noise carves away
    swirl*: float32 ## metres the noise field warps about itself
    softness*: float32 ## 0..1 how far the puff's edge fades before it ends
    squash*: float32 ## half-height over half-width of every puff: below 1
    ## keeps the rolls low on the ground instead of rearing across the eye
    dither*: float32 ## 0..1 grain share: how much of the blend weight
    ## rides on the dithered steps rather than the smooth wash beneath
    nearFade*: float32 ## metres from the eye across which a puff fades out,
    ## so the player never stands inside a wall of grey
    soften*: float32 ## metres over which a puff dissolves where the scene
    ##'s depth rises through it -- the soft particle, and the only thing
    ## keeping a billboard from cutting a chord across a hillside. 0
    ## leaves it off, as it must be when no depth replay is running.
    tint*: Vec3 ## mist's own colour, worn instead of the haze's when mixed
    tintMix*: float32 ## 0..1 how much of that tint to wear

  MistPuff* = object
    position*: Vec3 ## the middle of the ellipse, metres
    radius*: float32 ## its half-height; the half-width follows `stretch`
    seed*: float32 ## 0..1: fixes the puff's noise pattern and its phases
    stretch*: float32 ## width over height: mist lies flat, so around 2
    spin*: float32 ## radians the ellipse turns about the view axis
    opacity*: float32 ## the puff's own coverage, under the master

  GpuMistInstance = object
    center: Vec4
    shape: Vec4

  MistUniforms = object
    viewProj: Mat4
    right, up, params, axis: Vec4

  MistFragmentUniforms = object
    fog: FogUniforms
    dither, motion, tint, soft: Vec4

  MistPass* = ref object
    ## What the artist draws mist with: the pipeline, this frame's puffs,
    ## and the instance buffer they reach the GPU through.
    device: Device
    pipeline: Pipeline
    buffer: DynamicBuffer
    options*: MistOptions
    depthSampler: Sampler ## reads the depth replay without filtering:
    ## packed bytes interpolate to nonsense
    dummyDepth: gpu.Texture ## one far texel, bound when no replay runs
    dummyStaged: bool
    staged: seq[MistPuff]
    instances: seq[GpuMistInstance]

const
  MistAttributes*: seq[Attribute] = @[
    Attribute(location: 0, offset: 0, format: Float4),
    Attribute(location: 1, offset: 16, format: Float4),
  ]
  MistStride* = uint32 sizeof(GpuMistInstance)

  mistVertexSpv = staticRead("shaders/spv/mist.vert.spv")
  mistFragmentSpv = staticRead("shaders/spv/mist.frag.spv")

static:
  doAssert sizeof(GpuMistInstance) == 32

func newMistOptions*(time = 0.0f, opacity = 1.0f, scale = 7.0f,
                    detail = 0.75f, swirl = 1.1f, softness = 0.6f,
                    dither = 0.6f, nearFade = 2.5f, squash = 0.45f,
                    soften = 1.8f,
                    tint = vec3(0.86, 0.9, 0.94), tintMix = 0.0f): MistOptions =
  ## A quiet, readable field: continuous enough to pass for haze at a
  ## distance, grained enough to blob at close one.
  MistOptions(
    time: time,
    opacity: opacity,
    scale: scale,
    detail: max(detail, 0.0f),
    swirl: max(swirl, 0.0f),
    softness: softness,
    dither: dither,
    nearFade: max(nearFade, 0.0f),
    squash: squash,
    soften: max(soften, 0.0f),
    tint: tint,
    tintMix: tintMix,
  )

proc newMistPass*(device: Device, colorFormat: TextureFormat): MistPass =
  let
    vertex = newShader(device, mistVertexSpv.toOpenArrayByte(0, mistVertexSpv.high),
                       VertexShader, numUniformBuffers = 1)
    fragment = newShader(device, mistFragmentSpv.toOpenArrayByte(0, mistFragmentSpv.high),
                         FragmentShader, numUniformBuffers = 1, numSamplers = 1)
  MistPass(
    device: device,
    # Blended, depth-tested, and writing nothing: the mist lets the world
    # stand in front of it and never hides anything behind it -- least of
    # all its own neighbours, which is precisely how they come to blob.
    pipeline: newPipeline(device, PipelineDesc(
      vertex: vertex, fragment: fragment,
      attributes: MistAttributes, stride: MistStride, instanced: true,
      colorFormat: colorFormat, depthFormat: Depth32,
      blend: true, depthWrite: false,
    )),
    buffer: newDynamicBuffer(device, {VertexData}, 1024),
    depthSampler: newSampler(device, nearest = true),
    dummyDepth: newPictureTexture(device, 1, 1, Rgba8),
    dummyStaged: true,
    options: newMistOptions(),
  )

proc queue*(p: MistPass, puffs: openArray[MistPuff]) =
  ## Ask for these puffs this frame.
  p.staged.add puffs

func queued*(p: MistPass): int =
  ## Puffs asked for this frame.
  p.staged.len

func pending*(p: MistPass): bool =
  p.staged.len > 0

proc upload*(p: MistPass, cmd: CommandBuffer, eye: Vec3) =
  ## Pack the puffs farthest first -- blending a volume correctly wants the
  ## far skin laid down before the near one, and a puff's reach is the only
  ## key it needs -- and hand them to the GPU.
  if p.staged.len == 0:
    return
  sort(p.staged,
    proc (a, b: MistPuff): int =
      cmp(length(b.position - eye), length(a.position - eye)))
  p.instances.setLen(p.staged.len)
  for i, puff in p.staged:
    p.instances[i] = GpuMistInstance(
      center: vec4(puff.position, puff.radius),
      shape: vec4(puff.seed, puff.stretch, puff.spin, puff.opacity),
    )
  cmd.upload(p.buffer, p.instances)

func flatRight(view: Mat4): Vec3 =
  ## The camera's right, laid flat: puffs keep their ellipses level with
  ## the ground however the view pitches, and neighbours tilted the same
  ## way never cut through one another.
  let
    x = view.c[0]
    z = view.c[8]
    length = sqrt(x * x + z * z)
  if length < 1e-4f: vec3(1, 0, 0) else: vec3(x / length, 0, z / length)

func viewUp(view: Mat4): Vec3 =
  ## The camera's own up, the second billboard axis.
  normalize(vec3(view.c[1], view.c[5], view.c[9]))

proc drawColour*(p: MistPass, cmd: CommandBuffer, pass: RenderPass,
                 view, viewProj: Mat4, fog: FogUniforms, far: float32,
                 depth: gpu.Texture = nil) =
  ## Every puff queued this frame, farthest first, in one instanced draw.
  ## `depth` is the occlusion pass's packed scene depth from the previous
  ## frame, when there is one: the mist reads it to dissolve where the
  ## land would otherwise show a chord through a puff. Without it -- no
  ## replay running -- a single far texel stands in, and the soft fade
  ## simply never fires.
  let count = p.instances.len
  if count == 0:
    return
  let o = p.options
  var sceneDepth = depth
  if sceneDepth.isNil:
    sceneDepth = p.dummyDepth
    if p.dummyStaged: # one far texel: nothing ever occludes, nothing
      p.dummyStaged = false # fades, and the sampler always has something
      let farTexel = [191'u8, 254'u8, 254'u8, 254'u8] # the pass's own
      cmd.uploadPicture(sceneDepth, unsafeAddr farTexel[0], 1, 1)
  pass.bindPipeline(p.pipeline)
  pass.bindVertexBuffers([BufferBinding(buffer: p.buffer)])
  pass.bindFragmentSamplers([(texture: sceneDepth, sampler: p.depthSampler)])
  cmd.pushVertexUniforms(0, MistUniforms(
    viewProj: viewProj,
    right: vec4(flatRight(view), o.time),
    up: vec4(viewUp(view), 0.0f),
    params: vec4(o.opacity, o.squash, 0.0f, 0.0f),
    axis: vec4(view.c[2], view.c[6], view.c[10], view.c[14]),
  ))
  cmd.pushFragmentUniforms(0, MistFragmentUniforms(
    fog: fog,
    dither: vec4(o.dither, o.softness, o.detail, o.soften),
    motion: vec4(o.time, o.scale, o.nearFade, o.swirl),
    tint: vec4(o.tint, o.tintMix),
    soft: vec4(far, 0.0f, 0.0f, 0.0f),
  ))
  # Six corners an instance, no index buffer: the vertex stage is the only
  # thing that knows what a puff's quad looks like.
  pass.drawPrimitive(6, count.uint32)

proc reset*(p: MistPass) =
  p.staged.setLen(0)
  p.instances.setLen(0)
