import std/[hashes, tables]

import ../platform/sysrand

type
  AbstractComponentBuffer* = ref object of RootObj

  ComponentBuffer* [T] = ref object of AbstractComponentBuffer
    data: seq[T]
    dead: seq[int] # indexes that are dead

  Entity = distinct uint64
  
  Ents = object
    components: Table[string, AbstractComponentBuffer]
    entityIndexes: Table[Entity, int]
    entities: seq[Entity]  

proc hash*(e: Entity): Hash {.borrow.}

proc initComponentBuffer*[T](): ComponentBuffer[T] =
  ComponentBuffer[T]()

proc add*[T](buff: var ComponentBuffer[T], comp: T): int =
  if buff.dead.len() > 0:
    result = buff[^1]
    discard buff.pop()
    buff.data[result] = comp
    return
  result = buff.data.len()
  buff.data.add(comp)

proc initEnts*(): Ents =
  Ents()

proc randomUint64(): uint64 {.raises.} =
  let bytes = urandom(8)
  result = 0'u64
  for i in 0 ..< 8:
    result = result or (uint64(bytes[i]) shl (i * 8))

proc spawn*(ents: var Ents): Entity {.discardable, raises.} =
  result = Entity(randomUint64())

proc add*[T](ents: var Ents, ent: Entity, comp: T) =
  discard

when isMainModule:
  import std/[syncio]  
  echo "HERE?"
