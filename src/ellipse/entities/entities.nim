import std/[typetraits, tables, algorithm, macros, sysrand]

type
  EntityId* = uint64
  AbstractComponentBuffer* = ref object of RootObj
    entityIndex: Table[EntityId, int]
    dead: seq[int] ## freed component slots, handed to the next add
  ComponentBuffer*[T] = ref object of AbstractComponentBuffer
    data: seq[T]
  View* = ref object
    required: seq[string]
    entities: seq[EntityId]
    index: Table[EntityId, int]
  EntityManager* = object
    entities: seq[EntityId]
    componentBuffers: Table[string, AbstractComponentBuffer]
    views: seq[View]

proc initEntityManager*(): EntityManager =
  result = EntityManager()

proc randomUint64(): uint64 =
  var bytes: array[8, byte]
  if not urandom(bytes):
    raise newException(IOError, "OS random-number generator failed")

  for b in bytes:
    result = (result shl 8) or uint64(b)

proc generateNextId(): uint64 =
  result = randomUint64()
  while result == 0:
    # keep 0 free: callers use it to mean "no entity"
    result = randomUint64()

proc nextComponentIndex*[T](self: ComponentBuffer[T]): int =
  if self.dead.len > 0:
    result = self.dead[^1]
    discard self.dead.pop()
  else:
    result = self.data.len
    self.data.setLen(self.data.len + 1)

proc add*[T](self: ComponentBuffer[T], entityId: EntityId, component: T) =
  let index = self.nextComponentIndex()
  self.data[index] = component
  self.entityIndex[entityId] = index

proc get*[T](self: ComponentBuffer[T], entityId: EntityId): var T =
  self.data[self.entityIndex[entityId]]

proc hasEntity*(self: AbstractComponentBuffer, entityId: EntityId): bool =
  self.entityIndex.hasKey(entityId)

proc remove*(self: AbstractComponentBuffer, entityId: EntityId): bool =
  ## Forget one entity's slot: the index goes back to the dead pool for the
  ## next add, and the mapping is dropped so the view can be evicted cleanly.
  if not self.entityIndex.hasKey(entityId):
    return false

  self.dead.add(self.entityIndex[entityId])
  self.entityIndex.del(entityId)
  return true

proc hasComponent(self: EntityManager, entityId: EntityId, component: string): bool =
  let buffer = self.componentBuffers.getOrDefault(component)
  not buffer.isNil and buffer.hasEntity(entityId)

proc matches(self: View, manager: EntityManager, entityId: EntityId): bool =
  for component in self.required:
    if not manager.hasComponent(entityId, component):
      return false
  return true

proc addEntity(self: View, entityId: EntityId) =
  self.index[entityId] = self.entities.len
  self.entities.add(entityId)

proc removeEntity(self: View, entityId: EntityId) =
  if not self.index.hasKey(entityId):
    return
  let
    slot = self.index[entityId]
    last = self.entities[^1]
  self.entities[slot] = last
  self.index.del(entityId)
  if last != entityId:
    self.index[last] = slot
  self.entities.setLen(self.entities.len - 1)

proc refreshView(self: View, manager: EntityManager, entityId: EntityId) =
  if not self.index.hasKey(entityId) and self.matches(manager, entityId):
    self.addEntity(entityId)

proc refreshViews(self: var EntityManager, entityId: EntityId) =
  ## Cache-bust hook: hands a changed entity to every view so the ones that
  ## now match add it to their cache. Runs on spawn and on every add.
  for view in self.views:
    view.refreshView(self, entityId)

proc spawn*(self: var EntityManager): EntityId =
  result = generateNextId()
  self.entities.add(result)
  self.refreshViews(result)

proc add*[T](self: var EntityManager, entityId: EntityId, component: T) =
  if not self.componentBuffers.hasKey(name(T)):
    self.componentBuffers[name(T)] = AbstractComponentBuffer(ComponentBuffer[T]())
  var buffer = cast[ComponentBuffer[T]](self.componentBuffers[name(T)])
  buffer.add(entityId, component)
  self.refreshViews(entityId)

proc get*[T](self: EntityManager, entityId: EntityId): var T =
  cast[ComponentBuffer[T]](self.componentBuffers[name(T)]).get(entityId)

proc exists*(self: EntityManager, entityId: EntityId): bool =
  entityId in self.entities

proc has*[T](self: EntityManager, entityId: EntityId): bool =
  self.hasComponent(entityId, name(T))

proc despawn*(self: var EntityManager, entityId: EntityId): bool =
  ## Forget an entity for good: it leaves the roster, every component buffer
  ## frees its slot, and every view cache evicts it.
  var found = -1
  for index, entity in self.entities:
    if entity == entityId:
      found = index
      break
  if found < 0:
    return false

  self.entities[found] = self.entities[^1]
  self.entities.setLen(self.entities.len - 1)
  for buffer in self.componentBuffers.values:
    discard buffer.remove(entityId)
  for view in self.views:
    view.removeEntity(entityId)
  return true

iterator entities*(self: EntityManager): EntityId =
  for ent in self.entities.items:
    yield ent

iterator entities*(self: View): EntityId =
  for ent in self.entities.items:
    yield ent

proc len*(self: View): int =
  self.entities.len

proc contains*(self: View, entityId: EntityId): bool =
  self.index.hasKey(entityId)

proc viewFromNames*(self: var EntityManager, required: seq[string]): View =
  var names = required
  sort(names)
  var components: seq[string] = @[]
  for component in names:
    if components.len == 0 or components[^1] != component:
      components.add(component)

  for view in self.views:
    if view.required == components:
      return view

  result = View(required: components)
  for entityId in self.entities:
    if result.matches(self, entityId):
      result.addEntity(entityId)
  self.views.add(result)

macro view*(self: var EntityManager, components: varargs[typed]): untyped =
  func isComponentType(comp: NimNode): bool =
    let typ = comp.getType()
    typ.kind == nnkBracketExpr and typ.len > 0 and typ[0].kind == nnkSym and
      typ[0].strVal == "typeDesc"

  var names = newTree(nnkBracket)
  for component in components:
    if not component.isComponentType:
      error("view takes component types, `" & component.repr & "` is not one",
        component)
    names.add newCall(bindSym"name", component)
  result = newCall(bindSym"viewFromNames", self, newTree(nnkPrefix, ident"@", names))

when isMainModule:
  discard
