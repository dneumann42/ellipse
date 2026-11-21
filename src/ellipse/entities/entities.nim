import std/[typetraits, tables, algorithm, macros, sysrand, hashes, atomics]

type
  ComponentKey = object
    label: string
    digest: Hash
  EntityId* = uint64
  EntitySlots = ref object
    ## Stable small numbers for entity ids, shared by a manager and its
    ## component buffers, which index plain arrays by them.
    slots: Table[EntityId, int32]
    free: seq[int32]
    next: int32
    generation: uint64 ## changes whenever an id gains or loses its slot
    serial: uint64 ## unique per table, so a remembered lookup never
      ## outlives the table it came from
  AbstractComponentBuffer* = ref object of RootObj
    ids: EntitySlots
    sparse: seq[int32] ## entity slot -> component index + 1; 0: none
    dead: seq[int] ## freed component slots, handed to the next add
  ComponentBuffer*[T] = ref object of AbstractComponentBuffer
    data: seq[T]
  View* = ref object
    required: seq[string]
    excluded: seq[string]
    revision*: uint64
    entities: seq[EntityId]
    index: Table[EntityId, int]
  EntityManager* = object
    entities: seq[EntityId]
    entityIndex: Table[EntityId, int]
    ids: EntitySlots
    componentBuffers: Table[ComponentKey, AbstractComponentBuffer]
    views: seq[View]

func hash(key: ComponentKey): Hash = key.digest

func `==`(a, b: ComponentKey): bool =
  a.digest == b.digest and a.label == b.label

func componentKey(label: string): ComponentKey =
  ComponentKey(label: label, digest: hash(label))

proc slotBuffer[T](self: EntityManager): AbstractComponentBuffer {.inline.} =
  ## Look the buffer up by the component's name, not by a per-process slot
  ## number. A number handed out lazily inside a generic can differ between
  ## incrementally compiled modules (``--ic:on``), so ``add`` in one module
  ## and ``get`` in another would index different slots for the same type.
  const key = componentKey(name(T))
  self.componentBuffers.getOrDefault(key)

var slotTables: Atomic[uint64]

proc newEntitySlots(): EntitySlots =
  EntitySlots(serial: slotTables.fetchAdd(1) + 1)

proc initEntityManager*(): EntityManager =
  result = EntityManager(ids: newEntitySlots())

var lastLookup {.threadvar.}: tuple[serial: uint64, id: EntityId, slot: int32,
                                    generation: uint64]

proc slotOf(ids: EntitySlots, id: EntityId): int32 {.inline.} =
  ## The id's slot, or -1. Systems read several components of one entity in
  ## a row; the last lookup is remembered per thread, so they hash once.
  if ids.isNil: return -1
  {.cast(gcsafe), cast(noSideEffect).}:
    if lastLookup.serial == ids.serial and lastLookup.id == id and
        lastLookup.generation == ids.generation:
      return lastLookup.slot
    result = ids.slots.getOrDefault(id, -1)
    lastLookup = (ids.serial, id, result, ids.generation)

proc claimSlot(ids: EntitySlots, id: EntityId): int32 =
  result = ids.slots.getOrDefault(id, -1)
  if result >= 0: return
  if ids.free.len > 0: result = ids.free.pop()
  else:
    result = ids.next
    inc ids.next
  ids.slots[id] = result
  inc ids.generation

proc releaseSlot(ids: EntitySlots, id: EntityId) =
  var slot: int32
  if ids.slots.pop(id, slot):
    ids.free.add slot
    inc ids.generation

proc ensureIds(self: var EntityManager) {.inline.} =
  if self.ids.isNil: self.ids = newEntitySlots()

proc indexOf(self: AbstractComponentBuffer, entityId: EntityId): int {.inline.} =
  ## The entity's component index in this buffer, or -1.
  let slot = self.ids.slotOf(entityId)
  if slot < 0 or slot >= self.sparse.len: -1 else: self.sparse[slot].int - 1

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
  let slot = self.ids.claimSlot(entityId)
  if slot >= self.sparse.len: self.sparse.setLen(slot + 1)
  var index = self.sparse[slot].int - 1
  if index < 0:
    index = self.nextComponentIndex()
    self.sparse[slot] = int32(index + 1)
  self.data[index] = component

proc get*[T](self: ComponentBuffer[T], entityId: EntityId): var T =
  let index = self.indexOf(entityId)
  if index < 0:
    raise newException(KeyError, "entity has no " & $T)
  self.data[index]

proc hasEntity*(self: AbstractComponentBuffer, entityId: EntityId): bool =
  self.indexOf(entityId) >= 0

proc remove*(self: AbstractComponentBuffer, entityId: EntityId): bool =
  ## Forget one entity's slot: the index goes back to the dead pool for the
  ## next add, and the mapping is dropped so the view can be evicted cleanly.
  let index = self.indexOf(entityId)
  if index < 0:
    return false
  self.dead.add(index)
  self.sparse[self.ids.slotOf(entityId)] = 0
  return true

proc hasComponent(self: EntityManager, entityId: EntityId, component: ComponentKey): bool =
  let buffer = self.componentBuffers.getOrDefault(component)
  not buffer.isNil and buffer.hasEntity(entityId)

proc matches(self: View, manager: EntityManager, entityId: EntityId): bool =
  for component in self.excluded:
    if manager.hasComponent(entityId, componentKey(component)): return false
  for component in self.required:
    if not manager.hasComponent(entityId, componentKey(component)):
      return false
  return true

proc addEntity(self: View, entityId: EntityId) =
  self.index[entityId] = self.entities.len
  self.entities.add(entityId)
  inc self.revision

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
  inc self.revision

proc refreshView(self: View, manager: EntityManager, entityId: EntityId) =
  let matches = self.matches(manager, entityId)
  if entityId in self.index:
    if not matches: self.removeEntity(entityId)
  elif matches:
    self.addEntity(entityId)

proc refreshViews(self: var EntityManager, entityId: EntityId) =
  ## Cache-bust hook: hands a changed entity to every view so the ones that
  ## now match add it to their cache. Runs on spawn and on every add.
  for view in self.views:
    view.refreshView(self, entityId)

proc spawn*(self: var EntityManager): EntityId =
  self.ensureIds()
  result = generateNextId()
  discard self.ids.claimSlot(result)
  self.entityIndex[result] = self.entities.len
  self.entities.add(result)
  self.refreshViews(result)

proc adopt*(self: var EntityManager, entityId: EntityId): bool =
  ## Take in an entity by a known id — the load half of a save that keeps
  ## its ids stable, so components and scene state that name an id still
  ## find their entity. False when the roster already holds it; the id
  ## gets no second copy and no views change.
  if self.entityIndex.hasKey(entityId):
    return false
  self.ensureIds()
  discard self.ids.claimSlot(entityId)
  self.entityIndex[entityId] = self.entities.len
  self.entities.add(entityId)
  self.refreshViews(entityId)
  return true

proc add*[T](self: var EntityManager, entityId: EntityId, component: T) =
  const key = componentKey(name(T))
  self.ensureIds()
  if not self.componentBuffers.hasKey(key):
    self.componentBuffers[key] = AbstractComponentBuffer(ComponentBuffer[T](ids: self.ids))
  var buffer = cast[ComponentBuffer[T]](self.componentBuffers[key])
  buffer.add(entityId, component)
  self.refreshViews(entityId)

proc get*[T](self: EntityManager, entityId: EntityId): var T =
  let buffer = self.slotBuffer[:T]()
  if buffer.isNil:
    const key = componentKey(name(T))
    raise newException(KeyError, "no component " & key.label)
  cast[ComponentBuffer[T]](buffer).get(entityId)

proc componentBuffer*[T](self: EntityManager): ComponentBuffer[T] =
  ## Resolve a typed buffer once outside hot entity loops. Empty views may
  ## have no buffer yet; callers must tolerate nil in that case.
  cast[ComponentBuffer[T]](self.slotBuffer[:T]())

proc exists*(self: EntityManager, entityId: EntityId): bool =
  self.entityIndex.hasKey(entityId)

proc has*[T](self: EntityManager, entityId: EntityId): bool =
  let buffer = self.slotBuffer[:T]()
  not buffer.isNil and buffer.hasEntity(entityId)

proc despawn*(self: var EntityManager, entityId: EntityId): bool =
  ## Forget an entity for good: it leaves the roster, every component buffer
  ## frees its slot, and every view cache evicts it.
  let found = self.entityIndex.getOrDefault(entityId, -1)
  if found < 0:
    return false
  let last = self.entities[^1]
  self.entities[found] = last
  self.entityIndex[last] = found
  self.entityIndex.del(entityId)
  self.entities.setLen(self.entities.len - 1)
  for buffer in self.componentBuffers.values:
    discard buffer.remove(entityId)
  for view in self.views:
    view.removeEntity(entityId)
  self.ids.releaseSlot(entityId)
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
    if view.required == components and view.excluded.len == 0:
      return view

  result = View(required: components)
  for entityId in self.entities:
    if result.matches(self, entityId):
      result.addEntity(entityId)
  self.views.add(result)

proc withoutNames*(self: var EntityManager, matching: View, excluded: seq[string]): View =
  var names = excluded
  names.sort()
  for view in self.views:
    if view.required == matching.required and view.excluded == names: return view
  result = View(required: matching.required, excluded: names)
  for id in matching.entities:
    if result.matches(self, id): result.addEntity(id)
  self.views.add result

macro without*(self: var EntityManager, matching: View, components: varargs[typed]): untyped =
  var names = newTree(nnkBracket)
  for component in components: names.add newCall(bindSym"name", component)
  result = newCall(bindSym"withoutNames", self, matching, newTree(nnkPrefix, ident"@", names))

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
