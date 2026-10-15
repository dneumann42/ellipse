import std/[sets, sequtils, macros, streams, os]

import owl/objects
import owl/objects as owl
import owl/[evaluator, modules, libraries/base]
import plugnim

const SceneStackPath = "scene-stack.owl"

type
  SceneID* = string
  SceneStep* = enum
    Init
    Load
    Unload
    UI
    Update
    Draw
  SceneStack* = object
    load, push, goto, unload: HashSet[SceneID]
    stack: seq[SceneID]

proc initSceneStack*(): SceneStack =
  result = SceneStack(stack: @[])

proc toOwl(id: SceneID): owl.Object =
  result = str id

proc toOwl(ids: HashSet[SceneID]): owl.Object =
  var xs: seq[owl.Object] = @[]
  for id in ids:
    xs.add toOwl(id)
  result = list(xs)

proc toOwl(ids: seq[SceneID]): owl.Object =
  var xs: seq[owl.Object] = @[]
  for id in ids:
    xs.add toOwl(id)
  result = list(xs)

proc fromOwl(v: owl.Object, id: var SceneID) =
  doAssert v.isString
  id = v.toStr

proc fromOwl(v: owl.Object, ids: var HashSet[SceneID]) =
  doAssert v.isList
  ids.clear()
  for item in v.toSeq():
    var id: SceneID
    fromOwl(item, id)
    ids.incl(id)

proc fromOwl(v: owl.Object, ids: var seq[SceneID]) =
  doAssert v.isList
  ids.setLen(0)
  for item in v.toSeq():
    var id: SceneID
    fromOwl(item, id)
    ids.add(id)

proc toOwl*(sceneStack: SceneStack): owl.Object =
  result = record(@[
    pair(symbol"load", sceneStack.load.toOwl()),
    pair(symbol"push", sceneStack.push.toOwl()),
    pair(symbol"goto", sceneStack.goto.toOwl()),
    pair(symbol"unload", sceneStack.unload.toOwl()),
    pair(symbol"stack", sceneStack.stack.toOwl()),
  ])

proc fromOwl*(v: owl.Object, sceneStack: var SceneStack) =
  doAssert v.isRecord
  v.field("load").fromOwl(sceneStack.load)
  v.field("push").fromOwl(sceneStack.push)
  v.field("goto").fromOwl(sceneStack.goto)
  v.field("unload").fromOwl(sceneStack.unload)
  v.field("stack").fromOwl(sceneStack.stack)

var owlBaseEnv: ref Environment = nil

proc readOwl(source: string, filename: string): owl.Object =
  if owlBaseEnv == nil:
    owlBaseEnv = baseModule().env
  let forms = readSource(source, filename)
  result = evalForms(owlBaseEnv, forms)

proc read*(sceneStack: var SceneStack, stream: Stream) =
  readOwl(stream.readAll(), SceneStackPath).fromOwl(sceneStack)

proc write*(sceneStack: SceneStack, stream: Stream) =
  stream.write(sceneStack.toOwl().toCode())
  stream.write("\n")

proc save*(sceneStack: SceneStack) =
  var persisted = SceneStack(stack: sceneStack.stack)
  var fs = openFileStream(SceneStackPath, fmWrite)
  defer: fs.close()
  persisted.write(fs)

proc loadSceneStackState*(sceneStack: var SceneStack) =
  if not fileExists(SceneStackPath):
    sceneStack.save()
    return
  var fs = openFileStream(SceneStackPath, fmRead)
  defer: fs.close()
  sceneStack.read(fs)
  sceneStack.load.clear()
  sceneStack.push.clear()
  sceneStack.goto.clear()
  sceneStack.unload.clear()
  if sceneStack.stack.len > 0:
    sceneStack.load.incl(sceneStack.stack[^1])

proc activeScene*(self: SceneStack): SceneID =
  result = ""
  try:
    if self.stack.len == 0:
      return
    result = self.stack[^1]
  except:
    discard

proc isSceneActive*(self: SceneStack, id: SceneID): bool =
  result = self.activeScene() == id

proc shouldLoad*(self: SceneStack, id: SceneID): bool =
  result = self.load.contains(id)

proc shouldUnload*(self: SceneStack, id: SceneID): bool =
  result = self.unload.contains(id)

proc push*(self: var SceneStack, newScene: SceneID) =
  self.push.incl(newScene)

proc pop*(self: var SceneStack): SceneID {.discardable.} =
  result = ""
  if self.stack.len == 0:
    return
  result = self.stack[^1]
  discard self.stack.pop()
  self.unload.incl(result)

proc goto*(self: var SceneStack, sceneId: SceneID): SceneID =
  result = self.pop()
  self.stack.setLen(0)
  self.push(sceneId)

proc handlePushed*(self: var SceneStack) =
  var pushed = self.push.items.toSeq()
  for p in pushed:
    self.stack.add(p)
    self.push.excl(p)
    self.load.incl(p)
  self.save()

proc handleLoads*(self: var SceneStack): bool =
  result = self.load.len > 0
  self.load.clear()

proc handleUnloads*(self: var SceneStack) =
  let changed = self.unload.len > 0
  self.unload.clear()
  if changed:
    self.save()

macro scene*(args: varargs[untyped]): untyped =
  if args.len < 2:
    error "scene expects a name and an indented block of proc definitions, " &
      "e.g. `scene MainMenuScene:`", args
  let body = args[^1]
  let head = args[0 ..< ^1]
  if body.kind != nnkStmtList:
    error "a scene body must be an indented block of proc definitions.", body
  let sceneId = newLit head[0].strVal

  func procName(name: NimNode): string =
    if name.kind == nnkPostfix:
      name[1].strVal
    else:
      name.strVal

  func renameProc(name: NimNode, newName: string): NimNode =
    if name.kind == nnkPostfix:
      newTree(nnkPostfix, copyNimTree(name[0]), ident newName)
    else:
      ident newName

  func hasSceneStackParam(procDef: NimNode): bool =
    for i in 1 ..< procDef.params.len:
      let defs = procDef.params[i]
      for j in 0 ..< defs.len - 2:
        if defs[j].eqIdent("sceneStack"):
          return true

  var transformed = newStmtList()
  for item in body:
    if item.kind != nnkProcDef:
      transformed.add item
      continue
    var procDef = copyNimTree(item)
    if procName(procDef.name) in ["load", "unload"]:
      continue
    if not hasSceneStackParam(procDef):
      procDef.params.add newIdentDefs(ident"sceneStack", nnkVarTy.newTree(ident"SceneStack"))
    let isEarlyUpdate = procName(procDef.name) in ["earlyUpdate", "loadScene"]
    var guards = newStmtList()
    guards.add quote do:
      if not sceneStack.isSceneActive(`sceneId`):
        return
    if isEarlyUpdate:
      guards.add quote do:
        if not sceneStack.shouldLoad(`sceneId`):
          return
    if procName(procDef.name) == "loadScene":
      procDef.name = renameProc(procDef.name, "earlyUpdate")
    var newBody = newStmtList()
    newBody.add guards
    newBody.add procDef.body
    procDef.body = newBody
    transformed.add procDef

  var call = newCall(bindSym"plugin")
  for arg in head:
    call.add arg
  call.add transformed
  let exportedSceneId = postfix(copyNimTree(head[0]), "*")
  result = newStmtList(
    call,
    quote do:
      const `exportedSceneId`: SceneID = `sceneId`
  )
  
