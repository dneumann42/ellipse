import std/[math]

import ../platform/gpu

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
    occlusion*: float32 ## sky occlusion, 0 outdoors; local lights stay independent

  Mesh* = object
    vertices*: seq[Vec3]
    indices*: seq[uint32]
    normals*: seq[Vec3]
    uvs*: seq[Vec2]

  DrawMode* = enum
    Triangles, TriangleStrip, TriangleFan, Quads

const
  VertexAttributes*: seq[Attribute] = @[
    Attribute(location: 0, offset: 0, format: Float3),
    Attribute(location: 1, offset: 12, format: Float3),
    Attribute(location: 2, offset: 24, format: Float4),
    Attribute(location: 3, offset: 40, format: Float2),
    Attribute(location: 4, offset: 48, format: Float32),
  ]
  VertexStride* = uint32 sizeof(Vertex)

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

func faceNormal*(a, b, c: Vec3): Vec3 =
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
