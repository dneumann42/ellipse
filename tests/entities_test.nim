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
