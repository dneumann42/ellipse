## Arrows move the brush. Q/E orbit. [/] resize the brush.
## Hold R/F to raise/lower, S to smooth or P to paint. 1–3 select the paint texture.

import std/[math, monotimes, times]
import ellipse/worlds
import ellipse/world/noise
import ellipse/platform/[keyboard, sdl]

proc terrainTextures(): TextureAtlas =
  let colors = [[91, 128, 69], [152, 111, 71], [122, 132, 144]]
  result = newTextureAtlas(16, colors.len, 1)
  for layer, color in colors:
    for x in 0 ..< result.cell:
      for z in 0 ..< result.cell:
        let pixel = result.texelIndex(layer, x, z)
        let grain = (x * 31 + z * 17 + x * z * 13) mod 43 - 21
        for channel in 0 .. 2:
          result.pixels[pixel + channel] = uint8(color[channel] + grain)
        result.pixels[pixel + 3] = uint8(120 + grain * 2)

proc brushRing(artist: Artist3D, terrain: Terrain, center: Vec3, radius: float32) =
  proc rim(r, angle: float32): Vec3 =
    let x = center.x + r * cos(angle)
    let z = center.z + r * sin(angle)
    vec3(x, terrain.surfaceAt(x, z) + 0.12f, z)
  artist.setMaterial(vec4(1, 0.8, 0.25, 1))
  artist.begin(Quads)
  artist.setNormal(0, 1, 0)
  for i in 0 ..< 48:
    let a = i.float32 * PI.float32 / 24
    let b = (i + 1).float32 * PI.float32 / 24
    artist.vertex(rim(radius, a))
    artist.vertex(rim(radius - 0.13f, a))
    artist.vertex(rim(radius - 0.13f, b))
    artist.vertex(rim(radius, b))
  artist.`end`()

proc addScenery(artist: Artist3D, world: World) =
  var atlas = newBillboardAtlas(16, 16)
  var pixels = newSeq[uint8](16 * 16 * 4)
  for y in 0 ..< 16:
    for x in 0 ..< 16:
      let
        leaf = y < 12 and abs(x - 8) <= 1 + y div 3
        trunk = y >= 11 and abs(x - 8) <= 1
      if leaf or trunk:
        let i = (y * 16 + x) * 4
        pixels[i] = if leaf: 35 else: 109
        pixels[i + 1] = if leaf: uint8(126 + x * 6) else: 72
        pixels[i + 2] = 51
        pixels[i + 3] = 255
  discard atlas.addSprite(16, 16, pixels)
  artist.setBillboardAtlas(atlas)
  for spot in [vec2(-21, 19), vec2(-18, 23), vec2(-14, 20)]:
    discard world.addBillboard(BillboardInstance(
      position: vec3(spot.x, world.terrain.surfaceAt(spot.x, spot.y), spot.y),
      size: vec2(4, 6), shade: 1))

  artist.beginRecording()
  artist.setMaterial(vec4(0.5, 0.56, 0.63, 1))
  artist.render(Mesh(vertices: @[vec3(-2, 0, -1), vec3(0, 3, 0),
    vec3(2, 0, -1), vec3(0, 0, 2)], indices: @[0'u32, 1, 2, 2, 1, 3, 3, 1, 0]))
  let rock = artist.endRecording()
  discard world.addMesh(rock, translationMatrix(vec3(20, world.terrain.surfaceAt(20, 20), 20)))

proc axis(positive, negative: Key): float32 =
  (ord(keyHeld(positive)) - ord(keyHeld(negative))).float32

proc runEditor() =
  var app = initApp(AppConfig(appname: "Ellipse Terrain Editor", width: 960, height: 640))
  let
    artist = newArtist(app)
    terrain = newTerrain(65, origin = vec2(-32, -32))
    world = newWorld(terrain)
  for x in 0 ..< terrain.sampleCount:
    for z in 0 ..< terrain.sampleCount:
      terrain.setHeight(x, z, 6f * (fbm(x.float32 * 0.07f, z.float32 * 0.07f, seed = 29) - 0.5f))
  artist.setSplatAtlas(terrainTextures())
  artist.setSplatOptions(newSplatOptions(metersPerRepeat = 4f))
  artist.setLight(vec3(-0.5, -1, -0.3), 0.8)
  artist.setAmbient(0.45)
  addScenery(artist, world)

  var
    running = true
    previous = getMonoTime()
    cursor = vec3(0, 0, 0)
    angle = 0.55f
    radius = 5f
    layer: TerrainLayer = 1
  while running:
    processEvents(running)
    if not running or keyHeld(keyEscape): break
    let now = getMonoTime()
    let dt = min((now - previous).inMicroseconds.float32 / 1_000_000, 0.1)
    previous = now
    cursor.x = clamp(cursor.x + axis(keyRight, keyLeft) * dt * 15, -32f, 32f)
    cursor.z = clamp(cursor.z + axis(keyDown, keyUp) * dt * 15, -32f, 32f)
    angle += axis(keyE, keyQ) * dt
    radius = clamp(radius + axis(keyRightBracket, keyLeftBracket) * dt * 8, 1f, 16f)
    for i, key in [key1, key2, key3]:
      if keyHeld(key): layer = TerrainLayer(i)
    let hit = terrain.groundHit(vec3(cursor.x, 250, cursor.z), vec3(0, -1, 0))
    if hit.hit:
      terrain.sculpt(hit.point, radius, axis(keyR, keyF) * dt * 5)
      if keyHeld(keyS):
        terrain.smooth(hit.point, radius, 1f - exp(-dt * 5))
      if keyHeld(keyP):
        terrain.paint(hit.point, radius, layer, 1f - exp(-dt * 5))
    artist.setView(vec3(sin(angle) * 57, 48, cos(angle) * 57), vec3(0, 0, 0), vec3(0, 1, 0))
    artist.setPerspective(0.9f, 0.1f, 250)
    artist.renderWorld(world)
    if hit.hit: artist.brushRing(terrain, hit.point, radius)
    artist.present(app, (0.11f, 0.15f, 0.21f, 1f))

proc main() =
  configureVideoDriver()
  initialize()
  try:
    runEditor()
  finally:
    deinitialize()

main()
