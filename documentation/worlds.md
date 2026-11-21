# Editable 3D worlds

Run `make run_terrain_editor` from the Ellipse checkout. The example generates
three terrain textures, a tree billboard, and a mesh in code. It needs the same
SDL GPU setup as `hello3d`.

| Control | Action |
| --- | --- |
| Arrow keys | Move the brush |
| Q / E | Orbit the camera |
| [ / ] | Change brush radius |
| R / F | Raise / lower ground |
| S | Smooth the ground |
| 1 / 2 / 3 | Select grass, earth, or stone |
| P | Paint the selected texture |
| Esc | Exit |

## Create and edit terrain

```nim
import ellipse/worlds

let terrain = newTerrain(129, spacing = 1f, origin = vec2(-64, -64))
let world = newWorld(terrain)

let hit = terrain.groundHit(vec3(0, 20, 0), vec3(0, -1, 0))
if hit.hit:
  terrain.sculpt(hit.point, radius = 7f, delta = 3f)
  terrain.paint(hit.point, radius = 5f, layer = 1, strength = 0.7f)

let saved = terrain.terrainData()
let restored = newTerrain(saved)
```

Terrain uses a square sample grid with Y up. The origin is the world X and Z of
sample `(0, 0)` and `size - 1` gives the number of cells on each side.
`setHeight` edits a sample directly. `sculpt` takes a signed height change in
world units. `flatten` blends toward a given elevation and `smooth` averages
neighboring heights. Brush centers and radii use world coordinates. Painting
blends toward a layer in the range `0 ..< SplatLayers`. Pass the per-stroke
strength in the range `0 .. 1`.

Use `surfaceAt(x, z)` for height queries. It interpolates the rendered triangles
and clamps coordinates at the edge. Use `groundHit` with a camera ray to place a
brush or object. Its `reach` is a distance in world units, and intersections must
fall inside the terrain footprint.

`TerrainData` contains the grid dimensions, heights, and paint weights. Save it
with your application's serializer, keep a copy for undo, or build one from
imported height and splat maps. Arrays are X-major with Z contiguous, and each
material sample contains nine byte weights that add up to 255.

## Draw a world

1. Set your artist's camera and lighting. Stage the terrain textures with
   `artist.setSplatAtlas(atlas)`. Atlas cell order is the paint layer order.
   Supply a cell for each layer you use. Load an image with
   `readTextureAtlas(path, cellSize)` or fill a `newTextureAtlas` in code. The
   alpha channel controls the height-based texture blend.
2. For sprites, stage a `BillboardAtlas` on the artist and call
   `world.addBillboard(instance)`. For meshes, record a `StaticMesh` with the same
   artist and call `world.addMesh(mesh, transform)`. Both return an entity ID.
   Store game components in `world.entities`, update the
   `BillboardInstance` or `WorldMesh` component to move an object, and use
   `world.entities.despawn(id)` to remove it.
3. Call `artist.renderWorld(world)` each frame before `artist.present`.
   Terrain tiles are recorded on demand. Editing a tile rebuilds its geometry
   and updates shared edges and normals as needed.

Each artist uses one splat atlas and one billboard atlas per frame. Use
`artist.renderTerrain(terrain)` if your program manages its own objects.
