import std/[typetraits, table]

type
  EntityId* = uint64
  ComponentBuffer*[T] = object
    data: seq[T]
    entityIndex: Table[EntityId, int]
    dead: seq[int]

  EntityManager* = object
