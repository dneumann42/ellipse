import std/[math]

import ../platform/[gpu, sdl]
import billboards
import fog
import geometry
import planes
import retro
import shapes
import sky
import snapshot
import splatting
import ssao
import water

export billboards
export fog
export geometry
export planes
export retro
export shapes
export sky
export snapshot
export splatting
export ssao
export water

type
  Uniforms = object
    model, viewProj: Mat4
    color, light, params: Vec4

  Batch = object
    firstIndex, indexCount: uint32
    uniforms: Uniforms

  SplatUniforms = object
    splat: Vec4 # metres per repeat, blend depth, height contrast, unused
    fog: FogUniforms

  ShapeUniforms = object
    viewport: Vec4 # width, height in pixels, two unused

  StagedPicture = object
    ## A window-sized picture blended over the frame, and the texture it
    ## rides up in. Uploaded only on the presents after it was staged anew.
    texture: gpu.Texture
    width, height: uint32
    textureWidth, textureHeight: uint32
    bytes: seq[uint8]
    valid: bool ## a picture is staged; `bytes` holds it
    dirty: bool ## `bytes` changed since the texture last took them
    dirtyX0, dirtyY0, dirtyX1, dirtyY1: uint32 ## ... and where

  WaterUniforms = object
    shallow: Vec4 # rgb, clarity
    deep: Vec4 # rgb, metres across a ripple
    sky: Vec4 # rgb, ripple strength
    eye: Vec4 # the eye, seconds
    sun: Vec4 # toward the sun, intensity
    ambient: Vec4 # flat fill, then three unused
    fogNear, fogFar, fogLimit: Vec4 # the haze's colours, and where it ends
    surf: Vec4 # wave height, seconds between waves, depth they rise from, unused

  Artist3D* = ref object
    device: Device
    pipeline: Pipeline
    wireframePipeline: Pipeline ## the mesh batches' edges, for wireframe frames
    vertexBuffer: DynamicBuffer
    indexBuffer: DynamicBuffer
    vertices: seq[Vertex]
    indices: seq[uint32]
    batches: seq[Batch]
    pending: Batch
    view: Mat4
    eye: Vec3 ## where `setView` last put the eye: water reflects toward it
    projection: Mat4
    fovY, near, far: float32
    fovTan: float32 ## tan(fovY / 2) of the projection last built: the
    ## occlusion pass scales its metre-wide reach by it, so it walks the
    ## same frustum the frame was drawn through -- the letterboxed one.
    perspective: bool
    referenceAspect: float32
    model: Mat4
    stack: seq[Mat4]
    material: Vec4
    lightDir: Vec3
    lightIntensity: float32
    ambient: float32
    shininess: float32
    specular: float32
    building: bool
    mode: DrawMode
    current: Vertex
    face: seq[Vertex]
    post: SsaoPass
    ssao: SsaoOptions
    wireframe: bool ## the scene's triangles drawn as their edges: `setWireframe`
    colorFormat: TextureFormat
    snapshotPath: string
    snapshotTarget: gpu.Texture
    snapshotWidth, snapshotHeight: uint32
    snapshotDownload: TextureDownload
    overlayPipeline: Pipeline
    overlaySampler: Sampler
    overlay: StagedPicture ## over everything: the offscreen UI
    backdrop: StagedPicture ## over the scene, under the shapes: a map
    shapePipeline: Pipeline
    shapeBuffer: DynamicBuffer
    shapes2d: Shapes
    splatPipeline, splatDepthPipeline, splatWireframePipeline: Pipeline
    splatVertexBuffer, splatIndexBuffer: DynamicBuffer
    splatVertices: seq[SplatVertex]
    splatIndices: seq[uint32]
    splatBatches: seq[Batch]
    splatting: bool ## the batch being built is splatted ground
    splatOptions: SplatOptions
    splatTexture: gpu.Texture ## one array layer per atlas cell
    splatSampler: Sampler
    splatPixelSampler: Sampler ## ... and unfiltered, for the retro look
    splatBytes: seq[uint8] ## an atlas staged for the next present, cell
    splatCell, splatCount: uint32 ## after cell, and its cells' size and number
    splatStaged: bool
    meshTexture: gpu.Texture ## the array the mesh pipeline samples when a
    ## batch asks for a texture; a white pixel while none has been staged
    meshSampler: Sampler
    meshPixelSampler: Sampler
    meshBytes: seq[uint8] ## an atlas staged for the next present
    meshCell, meshCount: uint32
    meshStaged: bool
    meshCellIndex: int ## the layer the batches from here sample, -1: none
    waterPipeline, waterDepthPipeline, waterWireframePipeline: Pipeline
    waterVertexBuffer, waterIndexBuffer: DynamicBuffer
    waterVertices: seq[WaterVertex]
    waterIndices: seq[uint32]
    waterBatches: seq[Batch]
    watering: bool ## the batch being built is water
    waterOptions: WaterOptions
    skyPipeline: Pipeline
    skySampler: Sampler
    skyPixelSampler: Sampler
    sky: SkyOptions
    skybox: SkyboxState ## the cube texture the sky samples, and what made it
    fog: FogOptions
    sprites: BillboardPass ## upright sprites by the hundred thousand
    planes: PlanePass ## sprite planes: a held weapon, a painted sign
    aspect: float32 ## width over height of the frame last presented: the
    ## sky spreads its rays by it, so the dome matches the frustum
    retro: RetroOptions
    retroColor, retroDepth: gpu.Texture ## the small picture the scene is
    ## drawn into while the retro look is on, and its depth
    retroWidth, retroHeight: uint32
    blowUpSampler: Sampler ## reads the small picture back pixel by pixel

func uniformState(a: Artist3D, model, viewProj: Mat4): Uniforms =
  Uniforms(
    model: model,
    viewProj: viewProj,
    color: a.material,
    light: vec4(-a.lightDir.x, -a.lightDir.y, -a.lightDir.z, a.lightIntensity),
    params: vec4(a.ambient, a.shininess, a.specular,
      (a.meshCellIndex + 1).float32), # ... 0: the mesh draws untextured
  )

func nearFar(a: Artist3D): tuple[near, far: float32] =
  if a.near > 0 and a.far > a.near:
    (a.near, a.far)
  else:
    (0.1f, 100f)

const
  vertexSpv = staticRead("shaders/spv/mesh.vert.spv")
  fragmentSpv = staticRead("shaders/spv/mesh.frag.spv")
  fullscreenVertSpv = staticRead("shaders/spv/fullscreen.vert.spv")
  overlayFragSpv = staticRead("shaders/spv/overlay.frag.spv")
  shapeVertexSpv = staticRead("shaders/spv/shape.vert.spv")
  shapeFragmentSpv = staticRead("shaders/spv/shape.frag.spv")
  splatVertexSpv = staticRead("shaders/spv/splat.vert.spv")
  splatFragmentSpv = staticRead("shaders/spv/splat.frag.spv")
  waterVertexSpv = staticRead("shaders/spv/water.vert.spv")
  waterFragmentSpv = staticRead("shaders/spv/water.frag.spv")
  skyVertexSpv = staticRead("shaders/spv/sky.vert.spv")
  skyFragmentSpv = staticRead("shaders/spv/sky.frag.spv")

proc newArtist*(app: App): Artist3D =
  let device = app.gpuDevice
  let
    vertexShader = newShader(device, vertexSpv.toOpenArrayByte(0, vertexSpv.high), VertexShader, numUniformBuffers = 1)
    fragmentShader = newShader(device, fragmentSpv.toOpenArrayByte(0, fragmentSpv.high), FragmentShader, numUniformBuffers = 1, numSamplers = 1)
    fullscreenVertex = newShader(device, fullscreenVertSpv.toOpenArrayByte(0, fullscreenVertSpv.high), VertexShader)
    overlayFragment = newShader(device, overlayFragSpv.toOpenArrayByte(0, overlayFragSpv.high), FragmentShader, numSamplers = 1)
    shapeVertex = newShader(device, shapeVertexSpv.toOpenArrayByte(0, shapeVertexSpv.high), VertexShader, numUniformBuffers = 1)
    shapeFragment = newShader(device, shapeFragmentSpv.toOpenArrayByte(0, shapeFragmentSpv.high), FragmentShader)
    splatVertex = newShader(device, splatVertexSpv.toOpenArrayByte(0, splatVertexSpv.high), VertexShader, numUniformBuffers = 1)
    splatFragment = newShader(device, splatFragmentSpv.toOpenArrayByte(0, splatFragmentSpv.high), FragmentShader, numUniformBuffers = 1, numSamplers = 1)
    waterVertex = newShader(device, waterVertexSpv.toOpenArrayByte(0, waterVertexSpv.high), VertexShader, numUniformBuffers = 1)
    waterFragment = newShader(device, waterFragmentSpv.toOpenArrayByte(0, waterFragmentSpv.high), FragmentShader, numUniformBuffers = 1)
    skyVertex = newShader(device, skyVertexSpv.toOpenArrayByte(0, skyVertexSpv.high), VertexShader, numUniformBuffers = 1)
    skyFragment = newShader(device, skyFragmentSpv.toOpenArrayByte(0, skyFragmentSpv.high), FragmentShader, numUniformBuffers = 1, numSamplers = 1)
    post = newSsaoPass(device, vertexShader, app.gpuSwapchainFormat())
    # Each scene pipeline is described once and built twice: filled as the
    # world is meant to look, and as its own edges for the wireframe frames.
    meshDesc = PipelineDesc(
      vertex: vertexShader,
      fragment: fragmentShader,
      attributes: VertexAttributes,
      stride: VertexStride,
      colorFormat: app.gpuSwapchainFormat(),
      depthFormat: Depth32,
      blend: true,
    )
    splatDesc = PipelineDesc(
      vertex: splatVertex,
      fragment: splatFragment,
      attributes: SplatAttributes,
      stride: SplatStride,
      colorFormat: app.gpuSwapchainFormat(),
      depthFormat: Depth32,
    )
    # Water blends over the ground already drawn, and still writes depth: a
    # river ribbon folding over itself on a bend, or running into a lake,
    # covers what lies behind instead of doubling up on it.
    waterDesc = PipelineDesc(
      vertex: waterVertex,
      fragment: waterFragment,
      attributes: WaterAttributes,
      stride: WaterStride,
      colorFormat: app.gpuSwapchainFormat(),
      depthFormat: Depth32,
      blend: true,
    )
    pipeline = newPipeline(device, meshDesc)
    wireframePipeline = newPipeline(device, meshDesc.asWireframe())
    splatWireframePipeline = newPipeline(device, splatDesc.asWireframe())
    waterWireframePipeline = newPipeline(device, waterDesc.asWireframe())
  result = Artist3D(
    device: device,
    pipeline: pipeline,
    wireframePipeline: wireframePipeline,
    vertexBuffer: newDynamicBuffer(device, {VertexData}, 4096),
    indexBuffer: newDynamicBuffer(device, {IndexData}, 4096),
    view: identity(),
    projection: identity(),
    model: identity(),
    material: vec4(1, 1, 1, 1),
    lightDir: normalize(vec3(-0.5, -1, -0.3)),
    lightIntensity: 0.8,
    ambient: 0.3,
    shininess: 32,
    referenceAspect: app.designAspect(),
    colorFormat: app.gpuSwapchainFormat(),
    current: Vertex(normal: vec3(0, 0, 1), color: vec4(1, 1, 1, 1), uv: vec2(0, 0)),
    post: post,
    overlayPipeline: newPipeline(device, PipelineDesc(
      vertex: fullscreenVertex,
      fragment: overlayFragment,
      colorFormat: app.gpuSwapchainFormat(),
      hasDepth: false,
      blend: true,
      premultiplied: true,
    )),
    overlaySampler: newSampler(device),
    shapePipeline: newPipeline(device, PipelineDesc(
      vertex: shapeVertex,
      fragment: shapeFragment,
      attributes: ShapeAttributes,
      stride: ShapeStride,
      colorFormat: app.gpuSwapchainFormat(),
      hasDepth: false,
      blend: true,
      premultiplied: true,
    )),
    shapeBuffer: newDynamicBuffer(device, {VertexData}, 4096),
    splatPipeline: newPipeline(device, splatDesc),
    splatWireframePipeline: splatWireframePipeline,
    splatDepthPipeline: post.newDepthPipeline(splatVertex, SplatAttributes, SplatStride),
    splatVertexBuffer: newDynamicBuffer(device, {VertexData}, 4096),
    splatIndexBuffer: newDynamicBuffer(device, {IndexData}, 4096),
    splatOptions: newSplatOptions(),
    splatSampler: newSampler(device, repeat = true, mipmaps = true, anisotropy = 8),
    splatPixelSampler: newSampler(device, repeat = true, mipmaps = true, pixelated = true),
    meshSampler: newSampler(device, repeat = true, mipmaps = true, anisotropy = 8),
    meshPixelSampler: newSampler(device, repeat = true, mipmaps = true, pixelated = true),
    meshBytes: @[255'u8, 255'u8, 255'u8, 255'u8], # one white cell until an atlas comes
    meshCell: 1,
    meshCount: 1,
    meshStaged: true,
    meshCellIndex: -1,
    waterPipeline: newPipeline(device, waterDesc),
    waterWireframePipeline: waterWireframePipeline,
    waterDepthPipeline: post.newDepthPipeline(waterVertex, WaterAttributes, WaterStride),
    waterVertexBuffer: newDynamicBuffer(device, {VertexData}, 4096),
    waterIndexBuffer: newDynamicBuffer(device, {IndexData}, 4096),
    waterOptions: newWaterOptions(),
    # The sky neither tests nor writes anything the scene cares about: it
    # draws first, where the cleared depth lets every fragment through, and
    # writes none of it, so the world always lands on top of the dome.
    skyPipeline: newPipeline(device, PipelineDesc(
      vertex: skyVertex,
      fragment: skyFragment,
      colorFormat: app.gpuSwapchainFormat(),
      depthFormat: Depth32,
      depthWrite: false,
    )),
    skySampler: newSampler(device),
    skyPixelSampler: newSampler(device, pixelated = true),
    fog: newFogOptions(),
    sprites: newBillboardPass(device, app.gpuSwapchainFormat()),
    planes: newPlanePass(device, app.gpuSwapchainFormat()),
    aspect: 1.0f,
    retro: newRetroOptions(),
    blowUpSampler: newSampler(device, pixelated = true),
  )

proc reset*(a: Artist3D) =
  a.vertices.setLen(0)
  a.indices.setLen(0)
  a.batches.setLen(0)
  a.face.setLen(0)
  a.building = false
  a.splatVertices.setLen(0)
  a.splatIndices.setLen(0)
  a.splatBatches.setLen(0)
  a.splatting = false
  a.waterVertices.setLen(0)
  a.waterIndices.setLen(0)
  a.waterBatches.setLen(0)
  a.watering = false
  a.sprites.reset()
  a.planes.reset()
  a.shapes2d.clearShapes()

proc vertexCount*(a: Artist3D): int =
  ## Vertices queued for this frame: a proxy for the work the LOD keeps down.
  a.vertices.len + a.splatVertices.len + a.waterVertices.len +
    a.sprites.queued * 6 + # each billboard's six corners, built on the GPU
    a.planes.queued

proc setView*(a: Artist3D, eye, target, up: Vec3) =
  a.view = lookAt(eye, target, up)
  a.eye = eye

proc setPerspective*(a: Artist3D, fovY, near, far: float32) =
  # The real aspect is only known at present time (swapchain size), so the
  # projection is rebuilt per frame in present(). Seed it now from the
  # letterbox reference, so viewProjection() answers with a sane frustum
  # even before the first present has measured the window.
  a.fovY = fovY
  a.near = near
  a.far = far
  a.perspective = true
  a.fovTan = tan(fovY / 2.0f)
  if a.referenceAspect > 0:
    a.projection = perspectiveMatrix(fovY, a.referenceAspect, near, far)

proc viewProjection*(a: Artist3D): Mat4 =
  ## The matrix the queued batches will be drawn with: the projection last
  ## present() built for the real window, times the view set for this frame.
  ## Anything culling against the view frustum uses this and only this --
  ## a look-alike projection assembled elsewhere drifts from what the GPU
  ## actually shows, and culls what the screen was about to draw.
  a.projection * a.view

proc setLetterbox*(a: Artist3D, referenceAspect: float32) =
  ## Letterbox fit without black bars: the region matching `referenceAspect`
  ## is always fully visible; windows with a different aspect reveal extra
  ## world (overscan) where the bars would be, never a distorted image.
  ## Pass 0 to disable and fall back to plain aspect-corrected perspective.
  a.referenceAspect = referenceAspect

proc setProjection*(a: Artist3D, projection: Mat4) =
  a.projection = projection

proc setLight*(a: Artist3D, direction: Vec3, intensity: float32) =
  a.lightDir = normalize(direction)
  a.lightIntensity = intensity

proc setAmbient*(a: Artist3D, ambient: float32) =
  a.ambient = ambient

proc setMaterial*(a: Artist3D, color: Vec4) =
  a.material = color

proc setSsao*(a: Artist3D, options: SsaoOptions) =
  ## Enabled: the scene renders to offscreen targets and goes through the
  ## depth/occlusion/composite chain. Disabled: direct-to-swapchain as usual.
  a.ssao = options

proc setWireframe*(a: Artist3D, enabled: bool) =
  ## Draw the scene's triangles as their edges instead of their surfaces:
  ## meshes, splatted ground, water and billboards all come out in outlines,
  ## lit and textured and fogged as they were, and what lies behind a surface
  ## shows through it. Holds every frame until the next call. The occlusion
  ## pass stands down while this is on -- it shades solid surfaces, and there
  ## are none to shade -- so the frame goes to the window as if `setSsao`
  ## had been switched off. A driver that cannot rasterise lines fills the
  ## triangles instead, and the frame simply looks as it did before.
  a.wireframe = enabled
  a.sprites.wireframe = enabled

proc setSky*(a: Artist3D, options: SkyOptions) =
  ## What sky, if any, stands behind the frames to come: the dome is drawn
  ## before the scene, and the skybox cube is rebuilt at the next present
  ## when `options.skybox` is a picture the artist has not seen.
  a.sky = options

proc setRetro*(a: Artist3D, options: RetroOptions) =
  ## Draw the scene small and blow it up, its textures unfiltered -- or,
  ## with the look off, at the window's own resolution, filtered as ever.
  ## Holds every frame until the next call (see `ellipse/drawing/retro`).
  a.retro = options
  a.sprites.pixelated = options.pixelatedTextures
  a.planes.pixelated = options.pixelatedTextures

proc setFog*(a: Artist3D, options: FogOptions) =
  ## The haze the scene sinks into: it rides every scene shader -- meshes,
  ## splatted ground, and water -- and reaches the depth pass too, which
  ## drops geometry the fog has already swallowed.
  a.fog = options

proc pushMatrix*(a: Artist3D) =
  a.stack.add a.model

proc popMatrix*(a: Artist3D) =
  if a.stack.len > 0:
    a.model = a.stack.pop()

proc loadMatrix*(a: Artist3D, m: Mat4) =
  a.model = m

proc multMatrix*(a: Artist3D, m: Mat4) =
  a.model = a.model * m

proc translate*(a: Artist3D, v: Vec3) =
  a.model = a.model * translationMatrix(v)

proc translate*(a: Artist3D, x, y, z: float32) =
  a.translate(vec3(x, y, z))

proc scale*(a: Artist3D, v: Vec3) =
  a.model = a.model * scalingMatrix(v)

proc scale*(a: Artist3D, x, y, z: float32) =
  a.scale(vec3(x, y, z))

proc rotate*(a: Artist3D, angle: float32, axis: Vec3) =
  a.model = a.model * rotationMatrix(angle, axis)

proc setColor*(a: Artist3D, color: Vec4) =
  a.current.color = color

proc setColor*(a: Artist3D, r, g, b: float32, alpha: float32 = 1) =
  a.current.color = vec4(r, g, b, alpha)

proc setNormal*(a: Artist3D, normal: Vec3) =
  a.current.normal = normal

proc setNormal*(a: Artist3D, x, y, z: float32) =
  a.current.normal = vec3(x, y, z)

proc setTexCoord*(a: Artist3D, uv: Vec2) =
  a.current.uv = uv

proc setTexCoord*(a: Artist3D, u, v: float32) =
  a.current.uv = vec2(u, v)

proc appendVertex(a: Artist3D, v: Vertex) =
  a.indices.add a.vertices.len.uint32
  a.vertices.add v

proc `end`*(a: Artist3D) =
  if not a.building:
    return
  if a.splatting:
    a.building = false
    a.splatting = false
    a.pending.indexCount = a.splatIndices.len.uint32 - a.pending.firstIndex
    if a.pending.indexCount > 0:
      a.splatBatches.add a.pending
    return
  if a.watering:
    a.building = false
    a.watering = false
    a.pending.indexCount = a.waterIndices.len.uint32 - a.pending.firstIndex
    if a.pending.indexCount > 0:
      a.waterBatches.add a.pending
    return
  case a.mode
  of TriangleFan:
    if a.face.len > 2:
      for i in 2 ..< a.face.len:
        a.appendVertex(a.face[0])
        a.appendVertex(a.face[i - 1])
        a.appendVertex(a.face[i])
    a.face.setLen(0)
  of Quads:
    if a.face.len == 3:
      a.appendVertex(a.face[0])
      a.appendVertex(a.face[1])
      a.appendVertex(a.face[2])
    a.face.setLen(0)
  else:
    discard
  a.building = false
  a.pending.indexCount = a.indices.len.uint32 - a.pending.firstIndex
  if a.pending.indexCount > 0:
    a.batches.add a.pending

proc begin*(a: Artist3D, mode: DrawMode = Triangles) =
  if a.building:
    a.`end`()
  a.building = true
  a.mode = mode
  a.face.setLen(0)
  a.pending = Batch(
    firstIndex: a.indices.len.uint32,
    uniforms: a.uniformState(a.model, a.projection * a.view),
  )

proc vertex*(a: Artist3D, v: Vec3) =
  if not a.building or a.splatting or a.watering:
    return
  let vertex = Vertex(
    position: v,
    normal: a.current.normal,
    color: a.current.color,
    uv: a.current.uv,
  )
  case a.mode
  of Triangles:
    a.appendVertex(vertex)
  of TriangleStrip:
    a.face.add vertex
    if a.face.len == 3:
      a.appendVertex(a.face[0])
      a.appendVertex(a.face[1])
      a.appendVertex(a.face[2])
      a.face.delete(0)
  of TriangleFan:
    a.face.add vertex
    if a.face.len > 2:
      a.appendVertex(a.face[0])
      a.appendVertex(a.face[^2])
      a.appendVertex(a.face[^1])
  of Quads:
    a.face.add vertex
    if a.face.len == 4:
      a.appendVertex(a.face[0])
      a.appendVertex(a.face[1])
      a.appendVertex(a.face[2])
      a.appendVertex(a.face[0])
      a.appendVertex(a.face[2])
      a.appendVertex(a.face[3])
      a.face.setLen(0)

proc vertex*(a: Artist3D, x, y, z: float32) =
  a.vertex(vec3(x, y, z))

proc quad*(a: Artist3D, v0, v1, v2, v3: Vertex) =
  ## Immediate quad from complete vertices: appends the two triangles
  ## directly, skipping the per-corner staging the generic path does.
  ## Vertex-rich meshes stream through this.
  if not a.building or a.splatting or a.watering:
    return
  case a.mode
  of Quads:
    a.appendVertex(v0)
    a.appendVertex(v1)
    a.appendVertex(v2)
    a.appendVertex(v0)
    a.appendVertex(v2)
    a.appendVertex(v3)
  else:
    discard

proc beginSplat*(a: Artist3D) =
  ## Open a batch of splatted ground under the current matrices and light:
  ## `splatQuad` adds to it, and `end` closes it. The ground is drawn with
  ## the atlas `setSplatAtlas` last staged, and nothing until there is one.
  if a.building:
    a.`end`()
  a.building = true
  a.splatting = true
  a.pending = Batch(
    firstIndex: a.splatIndices.len.uint32,
    uniforms: a.uniformState(a.model, a.projection * a.view),
  )

proc splatQuad*(a: Artist3D, v0, v1, v2, v3: SplatVertex) =
  ## Two triangles of splatted ground, corners in winding order; the four
  ## vertices are shared between them.
  if not a.splatting:
    return
  let first = a.splatVertices.len.uint32
  a.splatVertices.add v0
  a.splatVertices.add v1
  a.splatVertices.add v2
  a.splatVertices.add v3
  a.splatIndices.add [first, first + 1, first + 2, first, first + 2, first + 3]

proc beginWater*(a: Artist3D) =
  ## Open a batch of water under the current matrices: `waterQuad` adds to
  ## it, and `end` closes it. Water is drawn after everything else, blended
  ## over it, with the options `setWaterOptions` last set.
  if a.building:
    a.`end`()
  a.building = true
  a.watering = true
  a.pending = Batch(
    firstIndex: a.waterIndices.len.uint32,
    uniforms: a.uniformState(a.model, a.projection * a.view),
  )

proc waterQuad*(a: Artist3D, v0, v1, v2, v3: WaterVertex) =
  ## Two triangles of water, corners in winding order; the four vertices are
  ## shared between them.
  if not a.watering:
    return
  let first = a.waterVertices.len.uint32
  a.waterVertices.add v0
  a.waterVertices.add v1
  a.waterVertices.add v2
  a.waterVertices.add v3
  a.waterIndices.add [first, first + 1, first + 2, first, first + 2, first + 3]

proc setWaterOptions*(a: Artist3D, options: WaterOptions) =
  a.waterOptions = options

proc setSplatAtlas*(a: Artist3D, atlas: TextureAtlas) =
  ## Stage the layer textures splatted ground is drawn with: cell `i` of the
  ## atlas is layer `i`. The cells are uploaded and mipmapped at the next
  ## present, and serve every frame after until the next atlas is staged.
  if atlas.cell <= 0 or atlas.cells <= 0 or
      atlas.pixels.len < atlas.width * atlas.height * 4:
    return
  a.splatBytes = atlas.layered()
  a.splatCell = atlas.cell.uint32
  a.splatCount = atlas.cells.uint32
  a.splatStaged = true

proc setMeshAtlas*(a: Artist3D, atlas: TextureAtlas) =
  ## Stage the array texture mesh batches sample with `setMeshCell`: cell
  ## `i` of the atlas is layer `i`. Uploaded and mipmapped at the next
  ## present, like the splat atlas, and it serves every textured mesh from
  ## then on until the next atlas is staged.
  if atlas.cell <= 0 or atlas.cells <= 0 or
      atlas.pixels.len < atlas.width * atlas.height * 4:
    return
  a.meshBytes = atlas.layered()
  a.meshCell = atlas.cell.uint32
  a.meshCount = atlas.cells.uint32
  a.meshStaged = true

proc setMeshCell*(a: Artist3D, cell: int) =
  ## The batches begun from here sample layer `cell` of the staged mesh
  ## atlas, at each vertex's uv; -1 draws them in flat colour, as always.
  a.meshCellIndex = cell

proc setBillboardAtlas*(a: Artist3D, atlas: BillboardAtlas) =
  ## Stage the sprites billboards are drawn with: layer `i` of the atlas is
  ## the `layer` an instance names. Uploaded and mipmapped at the next
  ## present, and serves every frame after until the next one is staged.
  a.sprites.setAtlas(atlas)

proc setBillboardOptions*(a: Artist3D, options: BillboardOptions) =
  a.sprites.options = options

proc newBillboardBuffer*(a: Artist3D,
                         instances: sink seq[BillboardInstance]): BillboardBuffer =
  ## Hand a set of billboards to the GPU once: they upload at the next
  ## present and are drawn from, run by run, with `drawBillboards` after.
  a.sprites.newBillboardBuffer(instances)

proc updateBillboards*(a: Artist3D, buffer: BillboardBuffer,
                       instances: sink seq[BillboardInstance]) =
  ## Rewrite a standing set's instances -- for billboards that move: the
  ## new set uploads at the next present.
  a.sprites.restage(buffer, instances)

proc drawBillboards*(a: Artist3D, buffer: BillboardBuffer, first, count: int,
                     grow = 1.0f) =
  ## Draw `count` of `buffer`'s instances from `first` this frame, each
  ## `grow` times its size: one draw call, whatever the count.
  a.sprites.queue(buffer, first, count, grow)

proc billboardCount*(a: Artist3D): int =
  ## Billboards asked for this frame.
  a.sprites.queued

proc setPlaneTexture*(a: Artist3D, width, height: int,
                      pixels: openArray[uint8]) =
  ## Stage the RGBA8 sheet sprite planes sample: uploaded at the next
  ## present, and it serves every plane from then on until the next sheet
  ## is staged.
  a.planes.setTexture(width, height, pixels)

proc setPlaneCutoff*(a: Artist3D, cutoff: float32) =
  ## Opacity under which a plane's texel is cut away.
  a.planes.cutoff = cutoff

proc drawPlaneQuad*(a: Artist3D, corners: array[4, Vec3],
                    uv: array[4, Vec2], color: Vec4 = vec4(1, 1, 1, 1)) =
  ## Lay a sprite plane on the frame: world corners in winding order, the
  ## sheet's uv at each, tinted by `color` and lit by nothing but it.
  a.planes.queueQuad(corners, uv, color)

proc setSplatOptions*(a: Artist3D, options: SplatOptions) =
  a.splatOptions = options

proc uploadSplatAtlas(a: Artist3D, cmd: CommandBuffer) =
  if not a.splatTexture.isNil:
    a.device.retire(a.splatTexture)
  var levels = 1'u32
  while (a.splatCell shr levels) > 0:
    inc levels
  a.splatTexture = newLayeredTexture(a.device, a.splatCell, a.splatCell,
    a.splatCount, levels, R8G8B8A8)
  cmd.uploadLayers(a.splatTexture, addr a.splatBytes[0], a.splatCell,
    a.splatCell, a.splatCount)
  cmd.generateMipmaps(a.splatTexture)
  a.splatBytes = @[]
  a.splatStaged = false

proc uploadMeshAtlas(a: Artist3D, cmd: CommandBuffer) =
  if not a.meshTexture.isNil:
    a.device.retire(a.meshTexture)
  var levels = 1'u32
  while (a.meshCell shr levels) > 0:
    inc levels
  a.meshTexture = newLayeredTexture(a.device, a.meshCell, a.meshCell,
    a.meshCount, levels, R8G8B8A8)
  cmd.uploadLayers(a.meshTexture, addr a.meshBytes[0], a.meshCell,
    a.meshCell, a.meshCount)
  cmd.generateMipmaps(a.meshTexture)
  a.meshBytes = @[]
  a.meshStaged = false

proc render*(a: Artist3D, mesh: Mesh) =
  let
    firstIndex = a.indices.len.uint32
    hasNormals = mesh.normals.len == mesh.vertices.len
    viewProj = a.projection * a.view
  if mesh.indices.len == 0:
    for f in 0 ..< (mesh.vertices.len div 3):
      let
        p0 = mesh.vertices[f * 3]
        p1 = mesh.vertices[f * 3 + 1]
        p2 = mesh.vertices[f * 3 + 2]
        flatNormal = faceNormal(p0, p1, p2)
      for k in 0 ..< 3:
        let i = f * 3 + k
        a.appendVertex(Vertex(
          position: mesh.vertices[i],
          normal: if hasNormals: mesh.normals[i] else: flatNormal,
          color: a.current.color,
          uv: if mesh.uvs.len > i: mesh.uvs[i] else: vec2(0, 0),
        ))
  else:
    for f in 0 ..< (mesh.indices.len div 3):
      var faceIndices: array[3, uint32]
      for k in 0 ..< 3:
        faceIndices[k] = mesh.indices[f * 3 + k]
      let flatNormal = faceNormal(
        mesh.vertices[faceIndices[0]],
        mesh.vertices[faceIndices[1]],
        mesh.vertices[faceIndices[2]],
      )
      for k in 0 ..< 3:
        let i = faceIndices[k]
        a.appendVertex(Vertex(
          position: mesh.vertices[i],
          normal: if hasNormals: mesh.normals[i] else: flatNormal,
          color: a.current.color,
          uv: if mesh.uvs.len > i.int: mesh.uvs[i] else: vec2(0, 0),
        ))
  a.batches.add Batch(
    firstIndex: firstIndex,
    indexCount: (a.indices.len - firstIndex.int).uint32,
    uniforms: a.uniformState(a.model, viewProj),
  )

proc render*(a: Artist3D, mesh: Mesh, model: Mat4) =
  a.pushMatrix()
  a.loadMatrix(model)
  a.render(mesh)
  a.popMatrix()

proc refreshProjection(a: Artist3D, frame: GpuFrame) =
  if frame.width > 0 and frame.height > 0:
    a.aspect = frame.width.float32 / frame.height.float32
  if not (a.perspective and frame.width > 0 and frame.height > 0):
    return
  let
    aspect = a.aspect
    # Letterbox fit: widen the frustum until the reference region fits,
    # never shrink it, so the bars are filled by extra scene content.
    scale =
      if a.referenceAspect > 0:
        max(1.0f, a.referenceAspect / aspect)
      else:
        1.0f
  let fovY = 2.0f * arctan(tan(a.fovY / 2.0f) * scale)
  a.fovTan = tan(fovY / 2.0f) # the reach the occlusion pass walks by
  a.projection = perspectiveMatrix(fovY, aspect, a.near, a.far)
  let viewProj = a.projection * a.view
  for batch in a.batches.mitems:
    batch.uniforms.viewProj = viewProj
  for batch in a.splatBatches.mitems:
    batch.uniforms.viewProj = viewProj
  for batch in a.waterBatches.mitems:
    batch.uniforms.viewProj = viewProj

proc drawBatches(a: Artist3D, cmd: CommandBuffer, pass: RenderPass, pipeline: Pipeline,
                 pushFragment: proc () = nil, textured: bool = false) =
  pass.bindPipeline(pipeline)
  pass.bindVertexBuffers([BufferBinding(buffer: a.vertexBuffer)])
  pass.bindIndexBuffer(a.indexBuffer)
  if textured:
    let sampler =
      if a.retro.pixelatedTextures: a.meshPixelSampler else: a.meshSampler
    pass.bindFragmentSamplers([(texture: a.meshTexture, sampler: sampler)])
  for batch in a.batches:
    cmd.pushVertexUniforms(0, batch.uniforms)
    if not pushFragment.isNil:
      pushFragment()
    pass.drawIndexed(batch.indexCount, firstIndex = batch.firstIndex)

proc drawSplats(a: Artist3D, cmd: CommandBuffer, pass: RenderPass, pipeline: Pipeline,
                pushFragment: proc (); textured: bool) =
  if a.splatBatches.len == 0 or a.splatTexture.isNil:
    return
  pass.bindPipeline(pipeline)
  pass.bindVertexBuffers([BufferBinding(buffer: a.splatVertexBuffer)])
  pass.bindIndexBuffer(a.splatIndexBuffer)
  if textured:
    let sampler =
      if a.retro.pixelatedTextures: a.splatPixelSampler else: a.splatSampler
    pass.bindFragmentSamplers([(texture: a.splatTexture, sampler: sampler)])
  for batch in a.splatBatches:
    cmd.pushVertexUniforms(0, batch.uniforms)
    pushFragment()
    pass.drawIndexed(batch.indexCount, firstIndex = batch.firstIndex)

proc drawWater(a: Artist3D, cmd: CommandBuffer, pass: RenderPass, pipeline: Pipeline,
               pushFragment: proc ()) =
  if a.waterBatches.len == 0:
    return
  pass.bindPipeline(pipeline)
  pass.bindVertexBuffers([BufferBinding(buffer: a.waterVertexBuffer)])
  pass.bindIndexBuffer(a.waterIndexBuffer)
  let o = a.waterOptions
  for batch in a.waterBatches:
    # The vertex stage heaves the surf, by the same waves the fragment
    # stage foams: seconds, height, period, reach; and fades the swell out
    # with distance from the eye.
    var uniforms = batch.uniforms
    uniforms.color = vec4(a.eye.x, a.eye.y, a.eye.z, 0)
    uniforms.params = vec4(o.time, o.surfHeight, max(o.surfPeriod, 0.1f),
                           max(o.surfReach, 1e-3f))
    cmd.pushVertexUniforms(0, uniforms)
    pushFragment()
    pass.drawIndexed(batch.indexCount, firstIndex = batch.firstIndex)

func waterUniforms(a: Artist3D): WaterUniforms =
  let
    o = a.waterOptions
    fog = a.fog
  WaterUniforms(
    shallow: vec4(o.shallow.x, o.shallow.y, o.shallow.z, o.clarity),
    deep: vec4(o.deep.x, o.deep.y, o.deep.z, o.rippleMeters),
    sky: vec4(o.sky.x, o.sky.y, o.sky.z, o.rippleStrength),
    eye: vec4(a.eye.x, a.eye.y, a.eye.z, o.time),
    sun: vec4(-a.lightDir.x, -a.lightDir.y, -a.lightDir.z, a.lightIntensity),
    ambient: vec4(a.ambient, 0, 0, 0),
    fogNear: vec4(fog.nearColor, fog.density),
    fogFar: vec4(fog.farColor, fog.falloff),
    fogLimit: vec4(fog.limit, 0, 0, 0),
    surf: vec4(o.surfHeight, max(o.surfPeriod, 0.1f), max(o.surfReach, 1e-3f), 0),
  )

proc syncSkybox(a: Artist3D, cmd: CommandBuffer) =
  ## Bring the cube texture to what the staged sky asks for: rebuild it
  ## when a different picture came, and keep a white one at hand so the
  ## sky's sampler always has a binding, skybox or not.
  let wanted = if a.sky.useSkybox: a.sky.skybox else: nil
  if not wanted.isNil and a.skybox.source != wanted:
    if not a.skybox.texture.isNil:
      a.device.retire(a.skybox.texture)
      a.skybox.texture = nil
    let face = wanted.faceSize.uint32
    a.skybox = SkyboxState(
      source: wanted,
      texture: newCubeTexture(a.device, face, R8G8B8A8),
      size: face,
    )
    var bytes = wanted.faces()
    cmd.uploadCubeFaces(a.skybox.texture, addr bytes[0], face)
  if a.skybox.texture.isNil:
    a.skybox = SkyboxState(
      texture: newCubeTexture(a.device, 1, R8G8B8A8),
      size: 1,
    )
    var white = newSeq[uint8](6 * 4)
    for byte in white.mitems:
      byte = 255'u8
    cmd.uploadCubeFaces(a.skybox.texture, addr white[0], 1)

proc drawSky(a: Artist3D, cmd: CommandBuffer, pass: RenderPass) =
  ## The dome behind the frame: one fullscreen triangle, its fragments
  ## aimed by un-projecting the screen through the camera's rotation,
  ## sampled from the skybox where one shows and painted from the sky's
  ## colours where none does.
  var uniforms = skyUniforms(a.sky, a.view,
    vec4(a.fovTan * a.aspect, a.fovTan, 0, 0),
    hasTexture = not a.skybox.source.isNil)
  cmd.pushVertexUniforms(0, uniforms)
  cmd.pushFragmentUniforms(0, uniforms)
  pass.bindPipeline(a.skyPipeline)
  let sampler =
    if a.retro.pixelatedTextures: a.skyPixelSampler else: a.skySampler
  pass.bindFragmentSamplers([(texture: a.skybox.texture, sampler: sampler)])
  pass.drawPrimitive(3)

func scenePipelines(a: Artist3D): tuple[mesh, splat, water: Pipeline] =
  ## Which pipelines this frame's scene draws through: the outlining ones
  ## while `setWireframe` is on, the filled ones while it is not.
  if a.wireframe:
    (a.wireframePipeline, a.splatWireframePipeline, a.waterWireframePipeline)
  else:
    (a.pipeline, a.splatPipeline, a.waterPipeline)

proc drawScene(a: Artist3D, cmd: CommandBuffer, pass: RenderPass) =
  ## The sky first, then every batch in colour: meshes, then splatted
  ## ground, then the water blended over both -- all of them sinking into
  ## the same fog. Wireframe frames take the outlining pipelines, and the
  ## billboards outline themselves (see `setWireframe`).
  if a.sky.enabled:
    a.drawSky(cmd, pass)
  let (mesh, splat, waterPipeline) = a.scenePipelines()
  let fog = fogUniforms(a.fog, a.eye)
  a.drawBatches(cmd, pass, mesh,
    proc () = cmd.pushFragmentUniforms(0, fog), textured = true)
  let uniforms = SplatUniforms(
    splat: vec4(
      max(a.splatOptions.metersPerRepeat, 1e-3f), max(a.splatOptions.blendDepth, 1e-3f),
      a.splatOptions.heightContrast, 0),
    fog: fog,
  )
  a.drawSplats(cmd, pass, splat,
    proc () = cmd.pushFragmentUniforms(0, uniforms), textured = true)
  a.sprites.drawColour(cmd, pass, a.view, a.projection * a.view, a.eye,
    vec3(-a.lightDir.x, -a.lightDir.y, -a.lightDir.z), a.lightIntensity,
    a.ambient, fog)
  a.planes.drawColour(cmd, pass, a.projection * a.view, fog)
  let water = a.waterUniforms()
  a.drawWater(cmd, pass, waterPipeline,
    proc () = cmd.pushFragmentUniforms(0, water))

proc drawDepth(a: Artist3D, cmd: CommandBuffer, pass: RenderPass) =
  ## Every batch again, packing linear depth for the occlusion pass.
  let
    (near, far) = a.nearFar()
    pushDepth = a.post.newDepthUniformPusher(cmd, near, far, depthFogFade(a.fog))
  a.drawBatches(cmd, pass, a.post.depthPipeline, pushDepth)
  a.drawSplats(cmd, pass, a.splatDepthPipeline, pushDepth, textured = false)
  a.sprites.drawDepth(cmd, pass, a.view, a.projection * a.view, a.eye, near,
    far, depthFogFade(a.fog))
  a.planes.drawDepth(cmd, pass, a.projection * a.view, near, far,
    depthFogFade(a.fog))
  a.drawWater(cmd, pass, a.waterDepthPipeline, pushDepth)

proc renderScene(a: Artist3D, cmd: CommandBuffer, target, depth: gpu.Texture,
                 width, height: uint32, clearColor: ClearColor) =
  ## The scene into `target`, `width` by `height`: through the occlusion
  ## chain when it is on, straight in when it is not. A wireframe frame
  ## goes straight in whatever the occlusion pass is set to: edges leave no
  ## surface for it to shade, and its depth would be read from geometry the
  ## frame no longer fills.
  if a.ssao.enabled and not a.wireframe:
    a.post.ensureSize(width, height)
    let (near, far) = a.nearFar()
    let scene = a.post.beginScene(cmd, clearColor, depth)
    a.drawScene(cmd, scene)
    scene.endRender()
    let depthPass = a.post.beginDepth(cmd, depth)
    a.drawDepth(cmd, depthPass)
    depthPass.endRender()
    a.post.runOcclusion(cmd, a.ssao, near, far, a.fovTan)
    a.post.runComposite(cmd, target)
  else:
    let pass = cmd.beginRender(target, clearColor, depth)
    a.drawScene(cmd, pass)
    pass.endRender()

proc ensureRetroTargets(a: Artist3D, width, height: uint32) =
  if not a.retroColor.isNil and a.retroWidth == width and
      a.retroHeight == height:
    return
  if not a.retroColor.isNil:
    a.device.retire(a.retroColor)
    a.device.retire(a.retroDepth)
  a.retroColor = newColorTexture(a.device, width, height, a.colorFormat)
  a.retroDepth = newDepthTexture(a.device, width, height)
  a.retroWidth = width
  a.retroHeight = height

proc presentScene(a: Artist3D, frame: GpuFrame, target: gpu.Texture,
                  clearColor: ClearColor) =
  ## The scene onto `target`, the frame's size: at that size as ever, or,
  ## with the retro look on, into the small picture first and blown up from
  ## it -- one fullscreen pass sampling the nearest pixel, so each stays a
  ## hard-edged block.
  if not a.retro.enabled:
    a.renderScene(frame.cmd, target, frame.depth, frame.width, frame.height,
      clearColor)
    return
  let (width, height) = a.retro.pictureSize(frame.width, frame.height)
  a.ensureRetroTargets(width, height)
  a.renderScene(frame.cmd, a.retroColor, a.retroDepth, width, height,
    clearColor)
  let pass = frame.cmd.beginRender(target, clearColor)
  pass.bindPipeline(a.overlayPipeline)
  pass.bindFragmentSamplers([
    (texture: a.retroColor, sampler: a.blowUpSampler),
  ])
  pass.drawPrimitive(3)
  pass.endRender()

proc stage(picture: var StagedPicture, width, height: int,
           pixels: openArray[uint8]) =
  if width <= 0 or height <= 0 or pixels.len < width * height * 4:
    return
  picture.bytes.setLen(width * height * 4)
  copyMem(addr picture.bytes[0], unsafeAddr pixels[0], picture.bytes.len)
  picture.width = width.uint32
  picture.height = height.uint32
  picture.valid = true
  picture.dirty = true
  picture.dirtyX0 = 0
  picture.dirtyY0 = 0
  picture.dirtyX1 = picture.width
  picture.dirtyY1 = picture.height

proc stageArea(picture: var StagedPicture, width, height: int,
               pixels: openArray[uint8], x0, y0, x1, y1: int) =
  ## `stage` for the columns `x0 ..< x1` and rows `y0 ..< y1` of a picture
  ## whose rest is staged already: only those pixels are copied, and only
  ## they go up on the next present. A picture of another size is taken
  ## whole.
  if width <= 0 or height <= 0 or pixels.len < width * height * 4:
    return
  if picture.width != width.uint32 or picture.height != height.uint32 or
      picture.bytes.len != width * height * 4:
    picture.stage(width, height, pixels)
    return
  picture.valid = true
  let
    ax0 = clamp(x0, 0, width)
    ay0 = clamp(y0, 0, height)
    ax1 = clamp(x1, 0, width)
    ay1 = clamp(y1, 0, height)
  if ax1 <= ax0 or ay1 <= ay0:
    return
  let span = (ax1 - ax0) * 4
  for y in ay0 ..< ay1:
    let at = (y * width + ax0) * 4
    copyMem(addr picture.bytes[at], unsafeAddr pixels[at], span)
  if picture.dirty:
    picture.dirtyX0 = min(picture.dirtyX0, ax0.uint32)
    picture.dirtyY0 = min(picture.dirtyY0, ay0.uint32)
    picture.dirtyX1 = max(picture.dirtyX1, ax1.uint32)
    picture.dirtyY1 = max(picture.dirtyY1, ay1.uint32)
  else:
    picture.dirty = true
    picture.dirtyX0 = ax0.uint32
    picture.dirtyY0 = ay0.uint32
    picture.dirtyX1 = ax1.uint32
    picture.dirtyY1 = ay1.uint32

proc setOverlayPicture*(a: Artist3D, width, height: int,
                        pixels: openArray[uint8]) =
  ## Stage the premultiplied BGRA8 picture `present` blends over every
  ## frame -- row 0 at the window's top: the seam the offscreen UI paints
  ## through. The bytes are copied; the picture rides until
  ## `clearOverlayPicture` or the next stage.
  a.overlay.stage(width, height, pixels)

proc updateOverlayPicture*(a: Artist3D, width, height: int,
                           pixels: openArray[uint8], x0, y0, x1, y1: int) =
  ## `setOverlayPicture` when only the columns `x0 ..< x1` and rows
  ## `y0 ..< y1` of `pixels` changed since the last stage: just those are
  ## copied and uploaded. The picture shows again if it was cleared.
  a.overlay.stageArea(width, height, pixels, x0, y0, x1, y1)

proc clearOverlayPicture*(a: Artist3D) =
  ## Stop drawing the staged picture; the next present shows only the scene.
  a.overlay.valid = false

proc setBackdropPicture*(a: Artist3D, width, height: int,
                         pixels: openArray[uint8]) =
  ## Stage a premultiplied BGRA8 picture laid over the scene but under the
  ## frame's shapes and the overlay: a map for the shapes to mark up, with
  ## the UI still on top. Staged and kept like the overlay picture.
  a.backdrop.stage(width, height, pixels)

proc clearBackdropPicture*(a: Artist3D) =
  ## Stop drawing the backdrop picture.
  a.backdrop.valid = false

proc shapes*(a: Artist3D): var Shapes =
  ## The frame's 2D shapes, in window pixels: draw markers, icons and
  ## pointers into it (see `ellipse/drawing/shapes`). They are laid over
  ## the scene and the backdrop, under the overlay, and cleared once the
  ## frame is presented.
  a.shapes2d

proc presentPicture(a: Artist3D, cmd: CommandBuffer, target: gpu.Texture,
                    picture: var StagedPicture) =
  ## One fullscreen pass over the frame so far: upload the staged picture if
  ## it changed since, and blend it with premultiplied alpha.
  if picture.texture.isNil or picture.textureWidth != picture.width or
      picture.textureHeight != picture.height:
    if not picture.texture.isNil:
      a.device.retire(picture.texture)
    picture.texture = newPictureTexture(a.device, picture.width,
      picture.height, Rgba8)
    picture.textureWidth = picture.width
    picture.textureHeight = picture.height
    picture.dirty = true
    picture.dirtyX0 = 0
    picture.dirtyY0 = 0
    picture.dirtyX1 = picture.width
    picture.dirtyY1 = picture.height
  if picture.dirty:
    cmd.uploadPictureArea(picture.texture, addr picture.bytes[0],
      picture.width, picture.dirtyX0, picture.dirtyY0, picture.dirtyX1,
      picture.dirtyY1)
    picture.dirty = false
  let pass = cmd.beginOverlay(target)
  pass.bindPipeline(a.overlayPipeline)
  pass.bindFragmentSamplers([
    (texture: picture.texture, sampler: a.overlaySampler),
  ])
  pass.drawPrimitive(3)
  pass.endRender()

proc presentShapes(a: Artist3D, cmd: CommandBuffer, target: gpu.Texture,
                   width, height: uint32) =
  ## The frame's shapes in one pass over what `target` shows; `present`
  ## uploads their vertices before any pass opens.
  if a.shapes2d.vertices.len == 0 or width == 0 or height == 0:
    return
  let pass = cmd.beginOverlay(target)
  pass.bindPipeline(a.shapePipeline)
  pass.bindVertexBuffers([BufferBinding(buffer: a.shapeBuffer)])
  cmd.pushVertexUniforms(0, ShapeUniforms(
    viewport: vec4(width.float32, height.float32, 0, 0)))
  pass.drawPrimitive(a.shapes2d.vertices.len.uint32)
  pass.endRender()

proc presentLayers(a: Artist3D, cmd: CommandBuffer, target: gpu.Texture,
                   width, height: uint32) =
  ## Everything laid over the scene, bottom to top: the backdrop picture,
  ## the shapes, the overlay picture.
  if a.backdrop.valid:
    a.presentPicture(cmd, target, a.backdrop)
  a.presentShapes(cmd, target, width, height)
  if a.overlay.valid:
    a.presentPicture(cmd, target, a.overlay)

proc snapshot*(a: Artist3D, path: string) =
  ## Save the frame being built to `path` as a PNG once present() draws it.
  ## The readback blocks for the GPU, so use it for debugging, not per frame.
  a.snapshotPath = path

proc snapshotScene(a: Artist3D, frame: GpuFrame, clearColor: ClearColor) =
  ## Re-renders the queued batches into an offscreen target and records a
  ## CPU readback in the same command buffer; bytes become readable after
  ## the frame is submitted and its fence waited on. The whole present
  ## sequence is replayed onto the snapshot target -- the occlusion
  ## composite, the retro blow-up and the UI overlay included -- so the
  ## file shows what the window shows, in the window's orientation.
  if a.snapshotTarget.isNil or a.snapshotWidth != frame.width or a.snapshotHeight != frame.height:
    if not a.snapshotTarget.isNil:
      a.device.retire(a.snapshotTarget)
    a.snapshotTarget = newColorTexture(a.device, frame.width, frame.height, a.colorFormat)
    a.snapshotWidth = frame.width
    a.snapshotHeight = frame.height
  a.presentScene(frame, a.snapshotTarget, clearColor)
  a.presentLayers(frame.cmd, a.snapshotTarget, frame.width, frame.height)
  a.snapshotDownload = frame.cmd.stageDownload(a.snapshotTarget, frame.width, frame.height)

proc saveSnapshot(a: Artist3D, path: string, width, height: uint32) =
  a.device.waitLastFence()
  let pixels = a.device.finishDownload(a.snapshotDownload)
  a.snapshotDownload = nil
  if writePng(path, width.int, height.int, pixels, bgra = a.colorFormat == Rgba8):
    echo "snapshot: wrote ", path
  else:
    echo "snapshot: failed to encode ", path

proc present*(a: Artist3D, app: App, clearColor: ClearColor) =
  let frame = app.gpuFrame()
  var snapshotPath = a.snapshotPath
  a.snapshotPath = ""
  if frame.valid:
    if a.splatStaged:
      a.uploadSplatAtlas(frame.cmd)
    if a.meshStaged:
      a.uploadMeshAtlas(frame.cmd)
    a.sprites.upload(frame.cmd)
    a.planes.upload(frame.cmd)
    frame.cmd.upload(a.shapeBuffer, a.shapes2d.vertices)
    if a.batches.len > 0 or a.splatBatches.len > 0 or a.waterBatches.len > 0 or
        a.sprites.pending or a.planes.pending or a.sky.enabled:
      a.refreshProjection(frame)
      if a.sky.enabled:
        a.syncSkybox(frame.cmd)
      frame.cmd.upload(a.vertexBuffer, a.vertices)
      frame.cmd.upload(a.indexBuffer, a.indices)
      frame.cmd.upload(a.splatVertexBuffer, a.splatVertices)
      frame.cmd.upload(a.splatIndexBuffer, a.splatIndices)
      frame.cmd.upload(a.waterVertexBuffer, a.waterVertices)
      frame.cmd.upload(a.waterIndexBuffer, a.waterIndices)
      a.presentScene(frame, frame.target, clearColor)
      if snapshotPath.len > 0:
        a.snapshotScene(frame, clearColor)
    else:
      frame.beginRender(clearColor)
      frame.pass.endRender()
    a.presentLayers(frame.cmd, frame.target, frame.width, frame.height)
  frame.endFrame()
  a.reset()
  if frame.valid and not a.snapshotDownload.isNil:
    a.saveSnapshot(snapshotPath, frame.width, frame.height)

proc present*(a: Artist3D, app: App, color: chroma.Color) =
  a.present(app, (color.r.float32, color.g.float32, color.b.float32, color.a.float32))
