## A 3D world with editable ground and entities for meshes, sprites and game data.

import std/tables
import ./entities/entities
import ./world/terrain

export entities, terrain

type
  World* = ref object
    terrain*: Terrain ## optional
    entities*: EntityManager
    artist: Artist3D
    spriteBuffer: BillboardBuffer
    sprites: seq[BillboardInstance]
  WorldMesh* = object
    mesh*: StaticMesh ## record on the artist that will render the world
    transform*: Mat4

proc newWorld*(terrain: Terrain = nil): World =
  World(terrain: terrain, entities: initEntityManager())

proc addBillboard*(world: World, sprite: BillboardInstance): EntityId =
  result = world.entities.spawn()
  world.entities.add(result, sprite)

proc addMesh*(world: World, mesh: StaticMesh, transform = identity()): EntityId =
  result = world.entities.spawn()
  world.entities.add(result, WorldMesh(mesh: mesh, transform: transform))

proc renderWorld*(artist: Artist3D, world: World) =
  ## Submit the world to the current camera. Stage the terrain and billboard
  ## atlases on the artist before drawing. Call present after submitting.
  if not world.terrain.isNil:
    artist.renderTerrain(world.terrain)
  let
    spriteComponents = componentBuffer[BillboardInstance](world.entities)
    meshComponents = componentBuffer[WorldMesh](world.entities)
  var
    sprites: seq[BillboardInstance]
    batches: OrderedTable[pointer, tuple[mesh: StaticMesh, transforms: seq[Mat4]]]
  for id in world.entities.entities:
    if not spriteComponents.isNil and spriteComponents.hasEntity(id):
      sprites.add spriteComponents.get(id)
    if not meshComponents.isNil and meshComponents.hasEntity(id):
      let visible = meshComponents.get(id)
      if not visible.mesh.isNil:
        batches.mgetOrPut(cast[pointer](visible.mesh), (visible.mesh, @[])).transforms.add visible.transform
  for batch in batches.mvalues:
    artist.drawStaticInstances(batch.mesh, move(batch.transforms))
  if world.artist != artist:
    world.artist = artist
    world.spriteBuffer = nil
  if sprites.len > 0:
    if world.spriteBuffer.isNil:
      world.spriteBuffer = artist.newBillboardBuffer(sprites)
    elif sprites != world.sprites:
      artist.updateBillboards(world.spriteBuffer, sprites)
    artist.drawBillboards(world.spriteBuffer, 0, sprites.len)
    world.sprites = move(sprites)
