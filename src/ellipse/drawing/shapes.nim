## Shapes: flat 2D drawing in window pixels, laid over the finished frame --
## markers, icons and pointers over a map, or anything else that wants to
## sit on the picture rather than in the world. Coordinates run from the
## window's top-left corner, x across and y down, one unit a pixel; colours
## are straight (not premultiplied) RGBA.
##
## Every shape is tessellated here, on the CPU, into plain coloured
## triangles; edges get a pixel-wide fringe fading to clear, so they come out
## smooth without multisampling. The artist draws the frame's shapes in one
## pass -- over the scene and its backdrop picture, under the UI overlay --
## and forgets them, like the rest of its batches, once the frame is
## presented: draw them again every frame they should show.

import std/[math]

import ../platform/gpu
import geometry

type
  ShapeVertex* = object
    position*: Vec2 ## window pixels from the top-left corner
    color*: Vec4 ## straight RGBA

  Shapes* = object
    ## The frame's 2D shapes, as triangles in drawing order.
    vertices*: seq[ShapeVertex]

const
  ShapeAttributes*: seq[Attribute] = @[
    Attribute(location: 0, offset: 0, format: Float2),
    Attribute(location: 1, offset: 8, format: Float4),
  ]
  ShapeStride* = uint32 sizeof(ShapeVertex)
  feather = 0.5f ## half the fringe: edges fade over a pixel, centred on them

func `+`(a, b: Vec2): Vec2 = vec2(a.x + b.x, a.y + b.y)
func `-`(a, b: Vec2): Vec2 = vec2(a.x - b.x, a.y - b.y)
func `*`(a: Vec2, s: float32): Vec2 = vec2(a.x * s, a.y * s)

func clear(color: Vec4): Vec4 = vec4(color.x, color.y, color.z, 0)

func segmentsFor(radius: float32): int =
  ## Enough sides that a circle reads round at its size, and no more.
  clamp(int(ceil(radius * 0.8f)), 12, 128)

proc clearShapes*(s: var Shapes) =
  s.vertices.setLen(0)

proc triangle(s: var Shapes, a, b, c: Vec2, ca, cb, cc: Vec4) =
  s.vertices.add ShapeVertex(position: a, color: ca)
  s.vertices.add ShapeVertex(position: b, color: cb)
  s.vertices.add ShapeVertex(position: c, color: cc)

proc quad(s: var Shapes, a, b, c, d: Vec2, ca, cb, cc, cd: Vec4) =
  s.triangle(a, b, c, ca, cb, cc)
  s.triangle(a, c, d, ca, cc, cd)

proc fillConvex*(s: var Shapes, points: openArray[Vec2], color: Vec4) =
  ## A convex polygon, its corners in either winding, filled in `color` with
  ## smoothed edges. Concave outlines come out wrong: split them first.
  let n = points.len
  if n < 3:
    return
  var area = 0.0f
  for i in 0 ..< n:
    let (p, q) = (points[i], points[(i + 1) mod n])
    area += p.x * q.y - q.x * p.y
  if abs(area) < 1e-6f:
    return
  # Outward edge normals: which side is out depends on the winding.
  let side = if area > 0: 1.0f else: -1.0f
  var normals = newSeq[Vec2](n)
  for i in 0 ..< n:
    let
      d = points[(i + 1) mod n] - points[i]
      l = max(sqrt(d.x * d.x + d.y * d.y), 1e-6f)
    normals[i] = vec2(d.y / l * side, -d.x / l * side)
  # Each corner moves half a pixel in and out along its miter: the solid
  # core inside, the clear rim outside. A sharp corner's miter is capped so
  # its fringe stays a fringe and not a spike.
  var inner, outer = newSeq[Vec2](n)
  for i in 0 ..< n:
    let
      a = normals[(i + n - 1) mod n]
      b = normals[i]
      cosine = max(a.x * b.x + a.y * b.y, -0.8f)
      miter = (a + b) * (feather / (1.0f + cosine))
    inner[i] = points[i] - miter
    outer[i] = points[i] + miter
  let rim = color.clear
  for i in 1 ..< n - 1:
    s.triangle(inner[0], inner[i], inner[i + 1], color, color, color)
  for i in 0 ..< n:
    let j = (i + 1) mod n
    s.quad(inner[i], inner[j], outer[j], outer[i], color, color, rim, rim)

proc fillTriangle*(s: var Shapes, a, b, c: Vec2, color: Vec4) =
  s.fillConvex([a, b, c], color)

proc fillRect*(s: var Shapes, x, y, width, height: float32, color: Vec4) =
  ## A rectangle `width` by `height` from its top-left corner at `x`, `y`.
  s.fillConvex([vec2(x, y), vec2(x + width, y), vec2(x + width, y + height),
                vec2(x, y + height)], color)

proc fillCircle*(s: var Shapes, center: Vec2, radius: float32, color: Vec4,
                 segments = 0) =
  ## A disc; `segments` 0 picks enough sides for its size.
  if radius <= 0:
    return
  let count = if segments > 2: segments else: segmentsFor(radius)
  var points = newSeq[Vec2](count)
  for k in 0 ..< count:
    let angle = k.float32 / count.float32 * 2.0f * PI
    points[k] = center + vec2(cos(angle), sin(angle)) * radius
  s.fillConvex(points, color)

proc strokeCircle*(s: var Shapes, center: Vec2, radius, width: float32,
                   color: Vec4, segments = 0) =
  ## A ring `width` pixels thick, centred on the circle of `radius`.
  if radius <= 0 or width <= 0:
    return
  let
    count = if segments > 2: segments else: segmentsFor(radius + width * 0.5f)
    half = width * 0.5f
    # Four radii out from the centre: clear, solid, solid, clear. A ring
    # thinner than its fringe keeps a hairline core, dimmed to its width.
    core = max(half - feather, 0.0f)
    solid = if half < feather: vec4(color.x, color.y, color.z,
                                    color.w * width / (2.0f * feather))
            else: color
    radii = [max(radius - half - feather, 0.0f), radius - core,
             radius + core, radius + half + feather]
    colors = [color.clear, solid, solid, color.clear]
  for k in 0 ..< count:
    let
      a0 = k.float32 / count.float32 * 2.0f * PI
      a1 = (k + 1).float32 / count.float32 * 2.0f * PI
      d0 = vec2(cos(a0), sin(a0))
      d1 = vec2(cos(a1), sin(a1))
    for band in 0 .. 2:
      let (r0, r1) = (radii[band], radii[band + 1])
      s.quad(center + d0 * r0, center + d1 * r0, center + d1 * r1,
             center + d0 * r1, colors[band], colors[band], colors[band + 1],
             colors[band + 1])

func winding(points: openArray[Vec2]): float32 =
  ## +1 or -1: which way the corner list turns.
  var area = 0.0f
  for i in 0 ..< points.len:
    let (p, q) = (points[i], points[(i + 1) mod points.len])
    area += p.x * q.y - q.x * p.y
  if area > 0: 1.0f else: -1.0f

func cross(o, a, b: Vec2): float32 =
  (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)

func hurt(a, b, c, p: Vec2, side: float32): bool =
  ## Whether the corner `p` stabs the triangle `a, b, c`, whose winding is
  ## `side`. Corners exactly on an edge do not count.
  if side > 0:
    cross(a, b, p) > 1e-6f and cross(b, c, p) > 1e-6f and cross(c, a, p) > 1e-6f
  else:
    cross(a, b, p) < -1e-6f and cross(b, c, p) < -1e-6f and cross(c, a, p) < -1e-6f

proc edgeNormals(points: openArray[Vec2], side: float32): seq[Vec2] =
  ## The outward unit normal of each edge, given the winding.
  let n = points.len
  result.setLen(n)
  for i in 0 ..< n:
    let
      d = points[(i + 1) mod n] - points[i]
      l = max(sqrt(d.x * d.x + d.y * d.y), 1e-6f)
    result[i] = vec2(d.y / l * side, -d.x / l * side)

proc mitered(points: openArray[Vec2], normals: openArray[Vec2],
             dist: float32): seq[Vec2] =
  ## Each corner moved `dist` along the normal bisector, so the offset edges
  ## still meet. A sharp corner's miter is capped, like `fillConvex`'s.
  let n = points.len
  result.setLen(n)
  for i in 0 ..< n:
    let
      a = normals[(i + n - 1) mod n]
      b = normals[i]
      cosine = max(a.x * b.x + a.y * b.y, -0.8f)
      miter = (a + b) * (dist / (1.0f + cosine))
    result[i] = points[i] + miter

proc fillPolygon*(s: var Shapes, points: openArray[Vec2], color: Vec4) =
  ## A simple polygon, concave or convex, filled in `color` with its outer
  ## edge smoothed. It must not cross itself; holes want a ring path, not a
  ## repeat. The interior is cut into triangles here, on the CPU.
  let n = points.len
  if n < 3:
    return
  let side = winding(points)
  # Ear clipping: a corner whose turn follows the winding, and which holds no
  # other corner in its triangle, is an ear -- snip it and go around again.
  var left: seq[int]
  for i in 0 ..< n:
    left.add i
  var snipped = 0
  while left.len > 3 and snipped <= n * n:
    var ear = -1
    for t in 0 ..< left.len:
      let
        a = points[left[(t + left.len - 1) mod left.len]]
        b = points[left[t]]
        c = points[left[(t + 1) mod left.len]]
      if cross(a, b, c) * side <= 1e-6f:
        continue # a hollow corner: no ear here
      var clear = true
      for u in 0 ..< left.len:
        if u == t or (u + 1) mod left.len == t or
            (u + left.len - 1) mod left.len == t:
          continue
        if hurt(a, b, c, points[left[u]], side):
          clear = false
          break
      if clear:
        ear = t
        break
    if ear < 0: # crossed or degenerate: fan what's left and be done
      for t in 1 ..< left.len - 1:
        s.triangle(points[left[0]], points[left[t]], points[left[t + 1]],
                   color, color, color)
      left.setLen(0)
      break
    s.triangle(points[left[(ear + left.len - 1) mod left.len]],
               points[left[ear]], points[left[(ear + 1) mod left.len]],
               color, color, color)
    left.delete(ear)
    inc snipped
  if left.len == 3:
    s.triangle(points[left[0]], points[left[1]], points[left[2]],
               color, color, color)
  # The fringe only along the border: solid up to each edge, clear a half
  # pixel out.
  let
    rim = color.clear
    normals = edgeNormals(points, side)
    outer = mitered(points, normals, feather)
  for i in 0 ..< n:
    let j = (i + 1) mod n
    s.quad(points[i], points[j], outer[j], outer[i], color, color, rim, rim)

proc strokePolygon*(s: var Shapes, points: openArray[Vec2], width: float32,
                    color: Vec4) =
  ## A ring `width` pixels thick following the closed polygon, its corners
  ## mitred so the stroke bends with the outline instead of doubling up.
  let n = points.len
  if n < 3 or width <= 0:
    return
  let
    side = winding(points)
    half = width * 0.5f
    # Four offsets out from the centre line: clear, solid, solid, clear. A
    # ring thinner than its fringe keeps a hairline core, dimmed to its width.
    core = max(half - feather, 0.0f)
    solid = if half < feather: vec4(color.x, color.y, color.z,
                                    color.w * width / (2.0f * feather))
            else: color
    offsets = [-(half + feather), -core, core, half + feather]
    colors = [color.clear, solid, solid, color.clear]
    normals = edgeNormals(points, side)
  var rings: array[4, seq[Vec2]]
  for r in 0 .. 3:
    rings[r] = mitered(points, normals, offsets[r])
  for i in 0 ..< n:
    let j = (i + 1) mod n
    for band in 0 .. 2:
      s.quad(rings[band][i], rings[band][j], rings[band + 1][j],
             rings[band + 1][i], colors[band], colors[band],
             colors[band + 1], colors[band + 1])

proc line*(s: var Shapes, a, b: Vec2, width: float32, color: Vec4) =
  ## A straight stroke from `a` to `b`, `width` pixels across, square-ended.
  let
    d = b - a
    l = sqrt(d.x * d.x + d.y * d.y)
  if l < 1e-6f or width <= 0:
    return
  let across = vec2(-d.y / l, d.x / l) * (width * 0.5f)
  s.fillConvex([a + across, b + across, b - across, a - across], color)

proc polyline*(s: var Shapes, points: openArray[Vec2], width: float32,
               color: Vec4, closed = false) =
  ## Strokes from point to point, the joints rounded. A translucent colour
  ## doubles up where segments overlap at the joints.
  if points.len < 2:
    return
  let last = if closed: points.len else: points.len - 1
  for i in 0 ..< last:
    s.line(points[i], points[(i + 1) mod points.len], width, color)
  for i in 0 ..< points.len:
    if closed or (i > 0 and i < points.high):
      s.fillCircle(points[i], width * 0.5f, color)

proc fillPointer*(s: var Shapes, tip: Vec2, direction: Vec2, length,
                  width: float32, color: Vec4) =
  ## An arrowhead: a triangle `length` pixels long and `width` across its
  ## back, its point at `tip` and aimed along `direction`.
  let l = sqrt(direction.x * direction.x + direction.y * direction.y)
  if l < 1e-6f or length <= 0:
    return
  let
    ahead = direction * (1.0f / l)
    across = vec2(-ahead.y, ahead.x) * (width * 0.5f)
    back = tip - ahead * length
  s.fillTriangle(tip, back + across, back - across, color)

proc arrow*(s: var Shapes, a, b: Vec2, width: float32, color: Vec4,
            headLength = 0.0f, headWidth = 0.0f) =
  ## A stroke from `a` with an arrowhead at `b`; the head is sized from the
  ## stroke's width unless told otherwise.
  let
    d = b - a
    l = sqrt(d.x * d.x + d.y * d.y)
  if l < 1e-6f:
    return
  let
    headL = min(if headLength > 0: headLength else: width * 4.0f, l)
    headW = if headWidth > 0: headWidth else: width * 3.5f
  s.line(a, b - d * (headL * 0.9f / l), width, color)
  s.fillPointer(b, d, headL, headW, color)

proc marker*(s: var Shapes, center: Vec2, radius: float32, fill,
             outline: Vec4, heading = vec2(0, 0)) =
  ## A map marker: a disc ringed in `outline`, and -- when `heading` is not
  ## zero -- a pointer standing off its edge the way `heading` points.
  let ringWidth = max(1.5f, radius * 0.3f)
  if heading.x != 0 or heading.y != 0:
    let
      l = sqrt(heading.x * heading.x + heading.y * heading.y)
      ahead = heading * (1.0f / l)
      tip = center + ahead * (radius * 2.1f)
    s.fillPointer(tip + ahead * ringWidth * 0.6f, ahead,
                  radius * 1.3f + ringWidth, radius * 1.5f + ringWidth * 1.2f,
                  outline)
    s.fillPointer(tip, ahead, radius * 1.3f, radius * 1.5f, fill)
  s.fillCircle(center, radius + ringWidth, outline)
  s.fillCircle(center, radius, fill)
