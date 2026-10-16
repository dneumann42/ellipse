import std/[math]

import ../platform/sdl

type
  Vec2* = object
    x*, y*: float32

  Vec3* = object
    x*, y*, z*: float32

  Vec4* = object
    x*, y*, z*, w*: float32

  Mat4* = object
    c*: array[16, float32]

  Vertex* = object
    position*: Vec3
    normal*: Vec3
    color*: Vec4
    uv*: Vec2

  Mesh* = object
    vertices*: seq[Vec3]
    indices*: seq[uint32]
    normals*: seq[Vec3]
    uvs*: seq[Vec2]

  DrawMode* = enum
    Triangles, TriangleStrip, TriangleFan, Quads

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

func vec2*(x, y: float32): Vec2 =
  Vec2(x: x.float32, y: y.float32)

func vec3*(x, y, z: float32): Vec3 =
  Vec3(x: x.float32, y: y.float32, z: z.float32)

func vec3*(v: Vec4): Vec3 =
  Vec3(x: v.x, y: v.y, z: v.z)

func vec4*(x, y, z: float32, w: float32 = 1): Vec4 =
  Vec4(x: x.float32, y: y.float32, z: z.float32, w: w.float32)

func vec4*(v: Vec3, w: float32 = 1): Vec4 =
  Vec4(x: v.x, y: v.y, z: v.z, w: w.float32)

func `+`*(a, b: Vec3): Vec3 =
  Vec3(x: a.x + b.x, y: a.y + b.y, z: a.z + b.z)

func `-`*(a, b: Vec3): Vec3 =
  Vec3(x: a.x - b.x, y: a.y - b.y, z: a.z - b.z)

func `*`*(a: Vec3, s: float32): Vec3 =
  Vec3(x: a.x * s, y: a.y * s, z: a.z * s)

func dot*(a, b: Vec3): float32 =
  a.x * b.x + a.y * b.y + a.z * b.z

func cross*(a, b: Vec3): Vec3 =
  Vec3(
    x: a.y * b.z - a.z * b.y,
    y: a.z * b.x - a.x * b.z,
    z: a.x * b.y - a.y * b.x,
  )

func length*(a: Vec3): float32 =
  sqrt(dot(a, a))

func normalize*(a: Vec3): Vec3 =
  let l = length(a)
  if l == 0:
    Vec3(x: 0, y: 1, z: 0)
  else:
    a * (1 / l)

func identity*(): Mat4 =
  Mat4(c: [
    1.0f, 0.0f, 0.0f, 0.0f,
    0.0f, 1.0f, 0.0f, 0.0f,
    0.0f, 0.0f, 1.0f, 0.0f,
    0.0f, 0.0f, 0.0f, 1.0f,
  ])

func `*`*(a, b: Mat4): Mat4 =
  for col in 0 ..< 4:
    for row in 0 ..< 4:
      var sum = 0.0f
      for k in 0 ..< 4:
        sum += a.c[k * 4 + row] * b.c[col * 4 + k]
      result.c[col * 4 + row] = sum

func `*`*(m: Mat4, v: Vec4): Vec4 =
  Vec4(
    x: m.c[0] * v.x + m.c[4] * v.y + m.c[8] * v.z + m.c[12] * v.w,
    y: m.c[1] * v.x + m.c[5] * v.y + m.c[9] * v.z + m.c[13] * v.w,
    z: m.c[2] * v.x + m.c[6] * v.y + m.c[10] * v.z + m.c[14] * v.w,
    w: m.c[3] * v.x + m.c[7] * v.y + m.c[11] * v.z + m.c[15] * v.w,
  )

func translationMatrix*(v: Vec3): Mat4 =
  result = identity()
  result.c[12] = v.x
  result.c[13] = v.y
  result.c[14] = v.z

func scalingMatrix*(v: Vec3): Mat4 =
  result = identity()
  result.c[0] = v.x
  result.c[5] = v.y
  result.c[10] = v.z

func rotationMatrix*(angle: float32, axis: Vec3): Mat4 =
  let
    a = normalize(axis)
    c = cos(angle)
    s = sin(angle)
    t = 1.0f - c
  Mat4(c: [
    t * a.x * a.x + c,       t * a.x * a.y + a.z * s, t * a.x * a.z - a.y * s, 0.0f,
    t * a.x * a.y - a.z * s, t * a.y * a.y + c,       t * a.y * a.z + a.x * s, 0.0f,
    t * a.x * a.z + a.y * s, t * a.y * a.z - a.x * s, t * a.z * a.z + c,       0.0f,
    0.0f,                    0.0f,                    0.0f,                    1.0f,
  ])

func perspectiveMatrix*(fovY, aspect, near, far: float32): Mat4 =
  let
    f = 1.0f / tan(fovY / 2.0f)
    nf = 1.0f / (near - far)
  Mat4(c: [
    f / aspect, 0.0f, 0.0f, 0.0f,
    0.0f, f, 0.0f, 0.0f,
    0.0f, 0.0f, far * nf, -1.0f,
    0.0f, 0.0f, far * near * nf, 0.0f,
  ])

func lookAt*(eye, target, up: Vec3): Mat4 =
  let
    z = normalize(eye - target)
    x = normalize(cross(up, z))
    y = cross(z, x)
  Mat4(c: [
    x.x, y.x, z.x, 0.0f,
    x.y, y.y, z.y, 0.0f,
    x.z, y.z, z.z, 0.0f,
    -dot(x, eye), -dot(y, eye), -dot(z, eye), 1.0f,
  ])

func faceNormal(a, b, c: Vec3): Vec3 =
  let n = cross(b - a, c - a)
  if length(n) == 0:
    vec3(0, 0, 1)
  else:
    normalize(n)

func computeNormals*(mesh: Mesh): seq[Vec3] =
  result.setLen(mesh.vertices.len)
  if mesh.vertices.len == 0:
    return
  var accumulated = newSeq[Vec3](mesh.vertices.len)
  if mesh.indices.len == 0:
    for f in 0 ..< (mesh.vertices.len div 3):
      let n = faceNormal(mesh.vertices[f * 3], mesh.vertices[f * 3 + 1], mesh.vertices[f * 3 + 2])
      for v in (f * 3) ..< (f * 3 + 3):
        accumulated[v] = n
  else:
    for f in 0 ..< (mesh.indices.len div 3):
      let
        ia = mesh.indices[f * 3]
        ib = mesh.indices[f * 3 + 1]
        ic = mesh.indices[f * 3 + 2]
        n = faceNormal(mesh.vertices[ia], mesh.vertices[ib], mesh.vertices[ic])
      for idx in [ia, ib, ic]:
        accumulated[idx] = accumulated[idx] + n
  for i in 0 ..< mesh.vertices.len:
    result[i] = normalize(accumulated[i])

func uniformState(a: Artist3D, model, viewProj: Mat4): Uniforms =
  Uniforms(
    model: model,
    viewProj: viewProj,
    color: a.material,
    light: vec4(-a.lightDir.x, -a.lightDir.y, -a.lightDir.z, a.lightIntensity),
    params: vec4(a.ambient, a.shininess, a.specular, 0),
  )

const
  vertexSpv = staticRead("shaders/spv/mesh.vert.spv")
  fragmentSpv = staticRead("shaders/spv/mesh.frag.spv")

proc newArtist*(app: App): Artist3D =
  let device = app.gpuDevice
  let
    vertexShader = newShader(device, vertexSpv.toOpenArrayByte(0, vertexSpv.high), VertexShader, numUniformBuffers = 1)
    fragmentShader = newShader(device, fragmentSpv.toOpenArrayByte(0, fragmentSpv.high), FragmentShader)
    pipeline = newPipeline(device, PipelineDesc(
      vertex: vertexShader,
      fragment: fragmentShader,
      stride: sizeof(Vertex).uint32,
      attributes: @[
        Attribute(location: 0, offset: 0, format: Float3),
        Attribute(location: 1, offset: 12, format: Float3),
        Attribute(location: 2, offset: 24, format: Float4),
        Attribute(location: 3, offset: 40, format: Float2),
      ],
      colorFormat: app.gpuSwapchainFormat(),
      depthFormat: Depth32,
      blend: true,
    ))
  Artist3D(
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
    current: Vertex(normal: vec3(0, 0, 1), color: vec4(1, 1, 1, 1), uv: vec2(0, 0)),
  )

proc reset*(a: Artist3D) =
  a.vertices.setLen(0)
  a.indices.setLen(0)
  a.batches.setLen(0)
  a.face.setLen(0)
  a.building = false

proc setView*(a: Artist3D, eye, target, up: Vec3) =
  a.view = lookAt(eye, target, up)

proc setPerspective*(a: Artist3D, fovY, near, far: float32) =
  a.projection = perspectiveMatrix(fovY, 1, near, far)

proc setProjection*(a: Artist3D, projection: Mat4) =
  a.projection = projection

proc setLight*(a: Artist3D, direction: Vec3, intensity: float32) =
  a.lightDir = normalize(direction)
  a.lightIntensity = intensity

proc setAmbient*(a: Artist3D, ambient: float32) =
  a.ambient = ambient

proc setMaterial*(a: Artist3D, color: Vec4) =
  a.material = color

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

proc present*(a: Artist3D, app: App, clearColor: ClearColor) =
  let frame = app.gpuFrame()
  if frame.valid:
    if a.batches.len > 0:
      frame.cmd.upload(a.vertexBuffer, a.vertices)
      frame.cmd.upload(a.indexBuffer, a.indices)
      frame.beginRender(clearColor)
      frame.pass.bindPipeline(a.pipeline)
      frame.pass.bindVertexBuffers([BufferBinding(buffer: a.vertexBuffer)])
      frame.pass.bindIndexBuffer(a.indexBuffer)
      for batch in a.batches:
        frame.cmd.pushVertexUniforms(0, batch.uniforms)
        frame.pass.drawIndexed(batch.indexCount, firstIndex = batch.firstIndex)
    else:
      frame.beginRender(clearColor)
  frame.endFrame()
  a.reset()

proc present*(a: Artist3D, app: App, color: chroma.Color) =
  a.present(app, (color.r.float32, color.g.float32, color.b.float32, color.a.float32))
