import std/[importutils, unittest]
import ellipse/worlds

privateAccess(Terrain)

suite "editable worlds":
  test "sculpt and paint survive a snapshot and subsequent independent edits":
    let terrain = newTerrain(9, spacing = 2f, origin = vec2(-8, -8), height = 2)
    let center = vec3(0, 2, 0)
    terrain.sculpt(center, 4, 6)
    check terrain.heightAt(4, 4) == 8
    check terrain.heightAt(5, 4) == 8
    check terrain.heightAt(6, 4) == 2
    terrain.paint(center, 4, 2, 0.5f)
    check terrain.weightsAt(4, 4)[2] == 128
    check terrain.weightsAt(6, 4)[0] == 255
    terrain.flatten(center, 4, 4, 0.5f)
    check terrain.heightAt(4, 4) == 6
    var snapshot = terrain.terrainData
    let restored = newTerrain(snapshot)
    snapshot.heights[40] = -5
    terrain.setHeight(4, 4, 0)
    check restored.surfaceAt(0, 0) == 6
    check restored.weightsAt(4, 4)[2] == 128
    check snapshot.heights[40] == -5

  test "smoothing reads original neighbors throughout the stroke":
    let terrain = newTerrain(7)
    terrain.setHeight(3, 3, 9)
    terrain.smooth(vec3(3, 0, 3), 4)
    for x in 2 .. 4:
      for z in 2 .. 4:
        check terrain.heightAt(x, z) == 1

  test "ray traverses cell boundaries and intersects the rendered triangle":
    let terrain = newTerrain(5, spacing = 2, origin = vec2(1, -1))
    terrain.setHeight(2, 2, 4)
    check terrain.surfaceAt(4.5f, 2) == 2
    let vertical = terrain.groundHit(vec3(4.5f, 10, 2), vec3(0, -2, 0))
    check vertical == (true, vec3(4.5f, 2, 2))
    let horizontal = terrain.groundHit(vec3(-3, 2, 3), vec3(1, 0, 0))
    check horizontal == (true, vec3(4, 2, 3))
    let reverse = terrain.groundHit(vec3(15, 2, 3), vec3(-1, 0, 0))
    check reverse == (true, vec3(6, 2, 3))
    check not terrain.groundHit(vec3(-3, 2, 3), vec3(1, 0, 0), reach = 6).hit
    check not terrain.groundHit(vec3(-3, 2, 3), vec3(0, -1, 0)).hit
    check not terrain.groundHit(vec3(5, 9, 3), vec3(0, 0, 0)).hit

  test "paint invalidates shared vertices and sculpt updates neighboring normals":
    let
      terrain = newTerrain(66)
      artist = Artist3D()
    artist.renderTerrain(terrain)
    let old = terrain.meshes[8]
    artist.renderTerrain(terrain)
    check terrain.meshes[8] == old
    terrain.paint(vec3(32, 0, 32), 0.5f, 1)
    for tile in [0, 1, 3, 4]:
      check terrain.meshes[tile].isNil
    check terrain.meshes[8] == old
    artist.renderTerrain(terrain)
    terrain.setHeight(31, 31, 3)
    for tile in [0, 1, 3, 4]:
      check terrain.meshes[tile].isNil
    check terrain.meshes[8] == old

  test "world sprites and meshes are regular entity components":
    let world = newWorld()
    let sprite = world.addBillboard(BillboardInstance(position: vec3(1, 2, 3)))
    let mesh = world.addMesh(StaticMesh())
    check get[BillboardInstance](world.entities, sprite).position == vec3(1, 2, 3)
    check get[WorldMesh](world.entities, mesh).transform == identity()
    check world.entities.despawn(sprite)
    check not has[BillboardInstance](world.entities, sprite)
