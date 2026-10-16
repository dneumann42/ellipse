import std/[math, times]

import ellipse/platform/sdl
import ellipse/drawing/artist3d

proc cubeFace(a: Artist3D, normal: Vec3, corners: array[4, Vec3]) =
  a.setNormal(normal)
  let uvs = [vec2(0, 0), vec2(1, 0), vec2(1, 1), vec2(0, 1)]
  for i in 0 ..< 4:
    a.setTexCoord(uvs[i])
    a.vertex(corners[i])

proc cube(a: Artist3D, s: float32) =
  cubeFace(a, vec3(0, 0, 1), [vec3(-s, -s, s), vec3(s, -s, s), vec3(s, s, s), vec3(-s, s, s)])
  cubeFace(a, vec3(0, 0, -1), [vec3(s, -s, -s), vec3(-s, -s, -s), vec3(-s, s, -s), vec3(s, s, -s)])
  cubeFace(a, vec3(1, 0, 0), [vec3(s, -s, s), vec3(s, -s, -s), vec3(s, s, -s), vec3(s, s, s)])
  cubeFace(a, vec3(-1, 0, 0), [vec3(-s, -s, -s), vec3(-s, -s, s), vec3(-s, s, s), vec3(-s, s, -s)])
  cubeFace(a, vec3(0, 1, 0), [vec3(-s, s, s), vec3(s, s, s), vec3(s, s, -s), vec3(-s, s, -s)])
  cubeFace(a, vec3(0, -1, 0), [vec3(-s, -s, -s), vec3(s, -s, -s), vec3(s, -s, s), vec3(-s, -s, s)])

proc floor(a: Artist3D, s: float32) =
  a.setMaterial(vec4(0.25, 0.3, 0.35, 1))
  a.begin(Triangles)
  a.setNormal(0, 1, 0)
  a.setTexCoord(0, 0)
  a.vertex(-s, 0, -s)
  a.setTexCoord(s * 2, 0)
  a.vertex(s, 0, -s)
  a.setTexCoord(s * 2, s * 2)
  a.vertex(s, 0, s)
  a.setTexCoord(0, 0)
  a.vertex(-s, 0, -s)
  a.setTexCoord(s * 2, s * 2)
  a.vertex(s, 0, s)
  a.setTexCoord(0, s * 2)
  a.vertex(-s, 0, s)
  a.end()

proc tetrahedron(): Mesh =
  result.vertices = @[
    vec3(1, 1, 1), vec3(-1, -1, 1), vec3(-1, 1, -1), vec3(1, -1, -1),
  ]
  result.indices = @[
    0'u32, 1, 2,
    0, 3, 1,
    0, 2, 3,
    1, 3, 2,
  ]

proc main() =
  configureVideoDriver()
  initialize()

  var app = initApp(AppConfig(appname: "Ellipse 3D", appversion: "v0.1.0"))
  let artist = newArtist(app)
  let mesh = tetrahedron()

  var
    running = true
    start = cpuTime()
    previous = start
    angle = 0'f32

  while running:
    processEvents(running)
    let now = cpuTime()
    let dt = (now - previous).float32
    previous = now
    angle += dt

    artist.setView(vec3(4, 3, 5), vec3(0, 0.5, 0), vec3(0, 1, 0))
    artist.setPerspective(degToRad(60.0).float32, 0.1, 50)
    artist.setLight(vec3(-0.5, -1, -0.3), 0.85)
    artist.setAmbient(0.25)

    floor(artist, 2.0)

    artist.setMaterial(vec4(0.85, 0.35, 0.2, 1))
    artist.loadMatrix(identity())
    artist.translate(0, 1, 0)
    artist.rotate(angle, vec3(0, 1, 0))
    artist.rotate(angle * 0.7, vec3(1, 0, 0))
    artist.begin(Quads)
    cube(artist, 0.7)
    artist.end()

    artist.setMaterial(vec4(0.2, 0.6, 0.9, 1))
    artist.loadMatrix(identity())
    artist.translate(-2.2, 0.6, -1)
    artist.rotate(-angle, vec3(1, 0.5, 0))
    artist.render(mesh)

    artist.present(app, color(0.08, 0.09, 0.13))

  deinitialize()

main()
