import std/[math]

import ../platform/[gpu, sdl]
import geometry
import snapshot
import ssao

export geometry
export snapshot
export ssao

type
  Uniforms = object
    model, viewProj: Mat4
    color, light, params: Vec4

  Batch = object
    firstIndex, indexCount: uint32
    uniforms: Uniforms

  Artist3D* = ref object
    device: Device
    pipeline: Pipeline
    vertexBuffer: DynamicBuffer
    indexBuffer: DynamicBuffer
    vertices: seq[Vertex]
    indices: seq[uint32]
    batches: seq[Batch]
    pending: Batch
    view: Mat4
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
    colorFormat: TextureFormat
    snapshotPath: string
    snapshotTarget: gpu.Texture
    snapshotWidth, snapshotHeight: uint32
    snapshotDownload: TextureDownload
    overlayPipeline: Pipeline
    overlaySampler: Sampler
    overlayTexture: gpu.Texture
    overlayWidth, overlayHeight: uint32
    overlayTextureWidth, overlayTextureHeight: uint32
    overlayBytes: seq[uint8]
    overlayValid: bool ## a picture is staged; `overlayBytes` holds it
func uniformState(a: Artist3D, model, viewProj: Mat4): Uniforms =
  Uniforms(
    model: model,
    viewProj: viewProj,
    color: a.material,
    light: vec4(-a.lightDir.x, -a.lightDir.y, -a.lightDir.z, a.lightIntensity),
    params: vec4(a.ambient, a.shininess, a.specular, 0),
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

proc newArtist*(app: App): Artist3D =
  let device = app.gpuDevice
  let
    vertexShader = newShader(device, vertexSpv.toOpenArrayByte(0, vertexSpv.high), VertexShader, numUniformBuffers = 1)
    fragmentShader = newShader(device, fragmentSpv.toOpenArrayByte(0, fragmentSpv.high), FragmentShader)
    fullscreenVertex = newShader(device, fullscreenVertSpv.toOpenArrayByte(0, fullscreenVertSpv.high), VertexShader)
    overlayFragment = newShader(device, overlayFragSpv.toOpenArrayByte(0, overlayFragSpv.high), FragmentShader, numSamplers = 1)
    pipeline = newPipeline(device, PipelineDesc(
      vertex: vertexShader,
      fragment: fragmentShader,
      attributes: VertexAttributes,
      stride: VertexStride,
      colorFormat: app.gpuSwapchainFormat(),
      depthFormat: Depth32,
      blend: true,
    ))
  result = Artist3D(
    device: device,
    pipeline: pipeline,
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
    post: newSsaoPass(device, vertexShader, app.gpuSwapchainFormat()),
    overlayPipeline: newPipeline(device, PipelineDesc(
      vertex: fullscreenVertex,
      fragment: overlayFragment,
      colorFormat: app.gpuSwapchainFormat(),
      hasDepth: false,
      blend: true,
      premultiplied: true,
    )),
    overlaySampler: newSampler(device),
  )

proc reset*(a: Artist3D) =
  a.vertices.setLen(0)
  a.indices.setLen(0)
  a.batches.setLen(0)
  a.face.setLen(0)
  a.building = false

proc vertexCount*(a: Artist3D): int =
  ## Vertices queued for this frame: a proxy for the work the LOD keeps down.
  a.vertices.len

proc setView*(a: Artist3D, eye, target, up: Vec3) =
  a.view = lookAt(eye, target, up)

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
  if not a.building:
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
  ## Terrain and other vertex-rich meshes stream through this.
  if not a.building:
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
  if not (a.perspective and frame.width > 0 and frame.height > 0):
    return
  let
    aspect = frame.width.float32 / frame.height.float32
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

proc drawBatches(a: Artist3D, cmd: CommandBuffer, pass: RenderPass, pipeline: Pipeline,
                 pushFragment: proc () = nil) =
  pass.bindPipeline(pipeline)
  pass.bindVertexBuffers([BufferBinding(buffer: a.vertexBuffer)])
  pass.bindIndexBuffer(a.indexBuffer)
  for batch in a.batches:
    cmd.pushVertexUniforms(0, batch.uniforms)
    if not pushFragment.isNil:
      pushFragment()
    pass.drawIndexed(batch.indexCount, firstIndex = batch.firstIndex)

proc presentSsao(a: Artist3D, frame: GpuFrame, clearColor: ClearColor) =
  a.post.ensureSize(frame.width, frame.height)
  let (near, far) = a.nearFar()
  let scene = a.post.beginScene(frame.cmd, clearColor, frame.depth)
  a.drawBatches(frame.cmd, scene, a.pipeline)
  scene.endRender()
  let depthPass = a.post.beginDepth(frame.cmd, frame.depth)
  a.drawBatches(frame.cmd, depthPass, a.post.depthPipeline,
    a.post.newDepthUniformPusher(frame.cmd, near, far))
  depthPass.endRender()
  a.post.runOcclusion(frame.cmd, a.ssao, near, far, a.fovTan)
  a.post.runComposite(frame.cmd, frame.target)

proc setOverlayPicture*(a: Artist3D, width, height: int,
                        pixels: openArray[uint8]) =
  ## Stage the premultiplied BGRA8 picture `present` blends over every
  ## frame -- row 0 at the window's top: the seam the offscreen UI paints
  ## through. The bytes are copied; the picture rides until
  ## `clearOverlayPicture` or the next stage.
  if width <= 0 or height <= 0 or pixels.len < width * height * 4:
    return
  a.overlayBytes.setLen(width * height * 4)
  copyMem(addr a.overlayBytes[0], unsafeAddr pixels[0], a.overlayBytes.len)
  a.overlayWidth = width.uint32
  a.overlayHeight = height.uint32
  a.overlayValid = true

proc clearOverlayPicture*(a: Artist3D) =
  ## Stop drawing the staged picture; the next present shows only the scene.
  a.overlayValid = false

proc presentOverlay(a: Artist3D, cmd: CommandBuffer, target: gpu.Texture) =
  ## One fullscreen pass over the finished frame: upload the staged picture
  ## and blend it with premultiplied alpha.
  if a.overlayTexture.isNil or a.overlayTextureWidth != a.overlayWidth or
      a.overlayTextureHeight != a.overlayHeight:
    if not a.overlayTexture.isNil:
      a.device.retire(a.overlayTexture)
    a.overlayTexture = newPictureTexture(a.device, a.overlayWidth,
      a.overlayHeight, Rgba8)
    a.overlayTextureWidth = a.overlayWidth
    a.overlayTextureHeight = a.overlayHeight
  cmd.uploadPicture(a.overlayTexture, addr a.overlayBytes[0],
    a.overlayWidth, a.overlayHeight)
  let pass = cmd.beginOverlay(target)
  pass.bindPipeline(a.overlayPipeline)
  pass.bindFragmentSamplers([
    (texture: a.overlayTexture, sampler: a.overlaySampler),
  ])
  pass.drawPrimitive(3)
  pass.endRender()

proc snapshot*(a: Artist3D, path: string) =
  ## Save the frame being built to `path` as a PNG once present() draws it.
  ## The readback blocks for the GPU, so use it for debugging, not per frame.
  a.snapshotPath = path

proc snapshotScene(a: Artist3D, frame: GpuFrame, clearColor: ClearColor) =
  ## Re-renders the queued batches into an offscreen target and records a
  ## CPU readback in the same command buffer; bytes become readable after
  ## the frame is submitted and its fence waited on. With the post chain
  ## active (SSAO), the whole present sequence is replayed onto the
  ## snapshot target -- composite and UI overlay included -- so the file
  ## shows what the window shows, in the window's orientation.
  if a.snapshotTarget.isNil or a.snapshotWidth != frame.width or a.snapshotHeight != frame.height:
    if not a.snapshotTarget.isNil:
      a.device.retire(a.snapshotTarget)
    a.snapshotTarget = newColorTexture(a.device, frame.width, frame.height, a.colorFormat)
    a.snapshotWidth = frame.width
    a.snapshotHeight = frame.height
  let depth = a.device.depthTarget(frame.width, frame.height)
  if a.ssao.enabled:
    a.post.ensureSize(frame.width, frame.height)
    let (near, far) = a.nearFar()
    let scene = a.post.beginScene(frame.cmd, clearColor, depth)
    a.drawBatches(frame.cmd, scene, a.pipeline)
    scene.endRender()
    let depthPass = a.post.beginDepth(frame.cmd, depth)
    a.drawBatches(frame.cmd, depthPass, a.post.depthPipeline,
      a.post.newDepthUniformPusher(frame.cmd, near, far))
    depthPass.endRender()
    a.post.runOcclusion(frame.cmd, a.ssao, near, far, a.fovTan)
    a.post.runComposite(frame.cmd, a.snapshotTarget)
  else:
    let pass = frame.cmd.beginRender(a.snapshotTarget, clearColor, depth)
    a.drawBatches(frame.cmd, pass, a.pipeline)
    pass.endRender()
  if a.overlayValid:
    a.presentOverlay(frame.cmd, a.snapshotTarget)
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
    if a.batches.len > 0:
      a.refreshProjection(frame)
      frame.cmd.upload(a.vertexBuffer, a.vertices)
      frame.cmd.upload(a.indexBuffer, a.indices)
      if a.ssao.enabled:
        a.presentSsao(frame, clearColor)
      else:
        frame.beginRender(clearColor)
        a.drawBatches(frame.cmd, frame.pass, a.pipeline)
        frame.pass.endRender()
      if snapshotPath.len > 0:
        a.snapshotScene(frame, clearColor)
    else:
      frame.beginRender(clearColor)
      frame.pass.endRender()
    if a.overlayValid:
      a.presentOverlay(frame.cmd, frame.target)
  frame.endFrame()
  a.reset()
  if frame.valid and not a.snapshotDownload.isNil:
    a.saveSnapshot(snapshotPath, frame.width, frame.height)

proc present*(a: Artist3D, app: App, color: chroma.Color) =
  a.present(app, (color.r.float32, color.g.float32, color.b.float32, color.a.float32))
