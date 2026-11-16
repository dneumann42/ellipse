import std/[unittest, algorithm]

import ellipse/entities/entities

type
  Position = object
    x, y: float32
  Velocity = object
    dx, dy: float32
  Sprite = object
    path: string

proc collect(view: View): seq[EntityId] =
  for entityId in view.entities:
    result.add(entityId)
  sort(result)

suite "entities":
  test "view caches entities that match every component":
    var em = initEntityManager()
    let moving = em.view(Position, Velocity)
    let a = em.spawn()
    let b = em.spawn()

    em.add(a, Position(x: 1, y: 2))
    check collect(moving) == newSeq[EntityId]()

    em.add(a, Velocity(dx: 1, dy: 0))
    em.add(b, Position(x: 0, y: 0))
    check collect(moving) == @[a]

    em.add(b, Velocity(dx: 0, dy: 1))
    check collect(moving) == sorted(@[a, b])
    check moving.len == 2

  test "views are shared per component set":
    var em = initEntityManager()
    let first = em.view(Position, Velocity)
    check em.view(Velocity, Position) == first
    check em.view(Position, Velocity, Position) == first
    check em.viewFromNames(@["Position", "Velocity"]) == first
    check em.view(Position) != first

  test "views created after entities are filled from them":
    var em = initEntityManager()
    let a = em.spawn()
    em.add(a, Position(x: 0, y: 0))
    em.add(a, Sprite(path: "a.png"))

    let renderable = em.view(Position, Sprite)
    check collect(renderable) == @[a]
    check a in renderable
    check renderable.len == 1

    check em.view(Sprite, Velocity).len == 0

  test "spawning refreshes every view":
    var em = initEntityManager()
    let all = em.viewFromNames(newSeq[string]())
    let a = em.spawn()
    check collect(all) == @[a]

  test "components follow their entity through despawn and slot reuse":
    var em = initEntityManager()
    let a = em.spawn()
    let b = em.spawn()
    em.add(a, Position(x: 1, y: 1))
    em.add(b, Position(x: 2, y: 2))
    check em.get[:Position](a).x == 1
    check em.despawn(a)
    check not em.has[:Position](a)
    expect KeyError: discard em.get[:Position](a)
    let c = em.spawn() # takes a's freed slot
    check not em.has[:Position](c)
    em.add(c, Position(x: 3, y: 3))
    check em.get[:Position](c).x == 3
    check em.get[:Position](b).x == 2
    em.get[:Position](b).x = 5
    check em.get[:Position](b).x == 5
    em.add(b, Position(x: 7, y: 7)) # replaces, not a second copy
    check em.get[:Position](b).x == 7

  test "buffer removal, adopted ids and two managers sharing an id":
    var em = initEntityManager()
    let a = em.spawn()
    em.add(a, Position(x: 1, y: 0))
    em.add(a, Velocity(dx: 4, dy: 0))
    check componentBuffer[Velocity](em).remove(a)
    check not em.has[:Velocity](a)
    check em.has[:Position](a)
    check not componentBuffer[Velocity](em).remove(a)
    var other = initEntityManager()
    check other.adopt(a)
    other.add(a, Position(x: 9, y: 0))
    for _ in 0 ..< 3: # alternate lookups of the same id across managers
      check em.get[:Position](a).x == 1
      check other.get[:Position](a).x == 9
    check not em.has[:Position](12345)
