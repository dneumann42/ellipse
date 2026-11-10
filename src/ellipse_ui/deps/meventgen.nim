## Standard Nim port of the shared code generation for widget events
## (`ellipse_ui/events`), used by the `widget` macro (`mwidget`) and the
## `handleEvents` / `defineEvent` macros (`mevents`).
##
## In the nimony kit these rewrites lived in template plugins working on NIF
## trees; here they are plain macros operating on `NimNode`s. The source
## shapes (verified against the standard parser):
##
##   emits Toggled(on: bool)   Command(emits, ObjConstr Toggled (on: bool))
##   emits Saved()             Command(emits, Call Saved)      declares, no fields
##   emits Saved               Command(emits, Saved)           references
##   event Toggled(e): ...     Command(event, Call(Toggled e), StmtList)
##   event Saved: ...          Command(event, Saved, StmtList)
##
## Generated per declared event (top level, ahead of the widget proc):
##
##   type Toggled* = object
##     on*: bool
##   const ToggledKind* = EventKind(uint32(<FNV-1a of "module.Toggled">))
##   registerEventKind(ToggledKind, "module.Toggled")
##   proc emit*(ev: Toggled): bool {.discardable.} =
##     var evPayload = ev
##     result = dispatchEvent(ToggledKind, "Toggled", addr evPayload)
##
## and per frame (a widget body or a `handleEvents` block):
##
##   proc evHandler(evKindArg: EventKind, evPayloadArg: pointer): EventFlow {.closure.} =
##     result = efPass
##     if evKindArg == ToggledKind:
##       result = efConsumed
##       proc evOnToggled(e: var Toggled) {.closure.} =
##         <handler body, bare `reemit` -> `reemit()`>
##       evOnToggled(cast[ptr Toggled](evPayloadArg)[])
##   pushEventFrame("Name", uint32(<hash>), <id>, evHandler, @[ToggledKind, ...])
##   try:
##     <remaining statements>
##   finally:
##     popEventFrame()
##
## The payload reaches the handler as a `var` parameter so `e.field = x`
## writes through to the payload a `reemit` passes on. A `return` in a
## handler ends just that handler. `finally` closes the frame however the
## body exits.
##
## Generated names (`evHandler`, `evOn<Name>`, `evKindArg`, `evPayloadArg`)
## are plain identifiers no widget would pick, so a widget's own `kind` or
## `payload` stays visible inside its handler bodies.
##
## Every generated identifier is a plain node (newIdentNode), resolved in the
## module the macro expands into -- exactly where the nimony plugin emitted
## its idents, and where `ellipse_ui/events` (re)exported symbols are in
## scope at every use site.
{.push gcsafe.}


import std/[macros, strutils]

proc fnv1a*(s: string): uint32 =
  result = 2166136261'u32
  for ch in s:
    result = (result xor uint32(ord(ch))) * 16777619'u32

proc moduleNameOf*(info: LineInfo): string =
  ## The base name (no directory, no extension) of the source at `info`.
  let path = info.filename
  var start = 0
  var stop = path.len
  for i in 0 ..< path.len:
    if path[i] == '/' or path[i] == '\\':
      start = i + 1
  for i in start ..< path.len:
    if path[i] == '.':
      stop = i
      break
  result = ""
  for i in start ..< stop:
    result.add path[i]

template identNode(s: string): NimNode = newIdentNode(s)

proc exported(name: string): NimNode =
  ## `name*` -- the parser shape: Postfix(Ident "*", Ident name).
  newTree(nnkPostfix, newIdentNode("*"), newIdentNode(name))

proc pragmaList(n: varargs[NimNode]): NimNode =
  result = newNimNode(nnkPragma)
  for x in n:
    result.add x

proc addrOf(n: NimNode): NimNode =
  newTree(nnkCommand, newIdentNode("addr"), n)

proc routine(kind: NimNodeKind, name: NimNode, params, pragmas, body: NimNode): NimNode =
  ## name, pattern, typevars, params, pragmas, (reserved), body -- the
  ## layout the standard parser produces.
  newTree(kind, name, newEmptyNode(), newEmptyNode(), params, pragmas,
    newEmptyNode(), body)

type
  EventField* = object
    name*: string
    typ*: NimNode

  EventDecl* = object
    name*: string
    declares*: bool           ## `emits Name(...)` / `Name()`: generate it
    fields*: seq[EventField]
    node*: NimNode            # for error reporting

  EventHandlerDecl* = object
    name*: string
    binding*: string          ## the payload name, "" for `event Name:`
    body*: NimNode            # the handler's StmtList
    node*: NimNode

  EventSections* = object
    decls*: seq[EventDecl]
    handlers*: seq[EventHandlerDecl]
    rest*: seq[NimNode]       ## every other top-level statement, in order
    error*: string
    errorAt*: NimNode

proc isCommandNamed(n: NimNode; name: string): bool =
  n.kind == nnkCommand and n[0].kind == nnkIdent and n[0].strVal == name

proc fail(s: var EventSections; msg: string; at: NimNode) =
  if s.error.len == 0:
    s.error = msg
    s.errorAt = at

proc parseEventHead*(s: var EventSections; owner: string; head: NimNode) =
  ## Parse `Name`, `Name()` or `Name(field: T, ...)` into a declaration.
  var d = EventDecl(name: "", declares: false, fields: @[], node: head)
  case head.kind
  of nnkIdent:
    d.name = head.strVal                     # bare: declared elsewhere
  of nnkCall:
    # Name() -- declared with no fields
    if head.len < 1 or head[0].kind != nnkIdent:
      s.fail(owner & ": expected `Name` or `Name(field: T, ...)`", head)
      return
    d.name = head[0].strVal
    d.declares = true
    if head.len > 1:
      s.fail(owner & ": expected `Name` or `Name(field: T, ...)`", head)
      return
  of nnkObjConstr:
    # Name(field: T, ...) -- declared with fields
    if head.len < 1 or head[0].kind != nnkIdent:
      s.fail(owner & ": expected `Name` or `Name(field: T, ...)`", head)
      return
    d.name = head[0].strVal
    d.declares = true
    for i in 1 ..< head.len:
      let f = head[i]
      if f.kind != nnkExprColonExpr or f[0].kind != nnkIdent:
        s.fail(owner & ": event `" & d.name & "` fields need types: " &
          "`emits " & d.name & "(field: T)`", f)
        return
      d.fields.add EventField(name: f[0].strVal, typ: f[1])
  else:
    s.fail(owner & ": expected `Name` or `Name(field: T, ...)`", head)
    return
  for e in s.decls:
    if e.name == d.name:
      s.fail(owner & ": `emits " & d.name & "` appears twice", head)
      return
  s.decls.add d

proc parseHandler(s: var EventSections; owner: string; n: NimNode) =
  # n: Command(event, <head>, [StmtList])
  var h = EventHandlerDecl(name: "", binding: "", body: nil, node: n)
  let head = n[1]
  case head.kind
  of nnkIdent:
    h.name = head.strVal
  of nnkCall:
    if head.len < 1 or head[0].kind != nnkIdent:
      s.fail(owner & ": expected `event Name(e):` or `event Name:`", n)
      return
    h.name = head[0].strVal
    if head.len == 2 and head[1].kind == nnkIdent:
      h.binding = head[1].strVal
    elif head.len > 1:
      s.fail(owner & ": expected `event " & h.name &
        "(e):` -- one payload name", n)
      return
  else:
    s.fail(owner & ": expected `event Name(e):` or `event Name:`", n)
    return
  if n.len >= 3 and n[2].kind == nnkStmtList:
    h.body = n[2]
  else:
    s.fail(owner & ": `event " & h.name & "` needs a handler body", n)
    return
  for e in s.handlers:
    if e.name == h.name:
      s.fail(owner & ": two `event " & h.name & "` handlers", n)
      return
  s.handlers.add h

proc collectEventSections*(body: NimNode; owner: string;
                           allowEmits: bool): EventSections =
  ## Split a statement list into its `emits` declarations, its `event`
  ## handlers and everything else.
  result = EventSections(decls: @[], handlers: @[], rest: @[], error: "")
  for stmt in body:
    if isCommandNamed(stmt, "emits"):
      if stmt.len != 2:
        result.fail(owner & ": expected `Name` or `Name(field: T, ...)`",
          stmt)
      else:
        result.parseEventHead(owner, stmt[1])
    elif isCommandNamed(stmt, "event"):
      result.parseHandler(owner, stmt)
    else:
      result.rest.add stmt

proc findStrayEvent(n: NimNode; found: var NimNode): bool =
  ## An `event` section anywhere below the top level of a body.
  if isCommandNamed(n, "event") and n.len >= 3 and n[2].kind == nnkStmtList:
    found = n
    return true
  for c in n:
    if findStrayEvent(c, found):
      return true
  return false

proc emittedName(n: NimNode): string =
  ## `emit Name(...)` / `emit Name`: the constructed event's name.
  result = ""
  if isCommandNamed(n, "emit") and n.len >= 2:
    case n[1].kind
    of nnkCall, nnkObjConstr:
      if n[1][0].kind == nnkIdent:
        result = n[1][0].strVal
    else:
      discard

proc findUndeclaredEmit(n: NimNode; decls: seq[EventDecl];
                        found: var NimNode; name: var string): bool =
  let e = emittedName(n)
  if e.len > 0:
    var known = false
    for d in decls:
      if d.name == e:
        known = true
    if not known:
      found = n
      name = e
      return true
  for c in n:
    if findUndeclaredEmit(c, decls, found, name):
      return true
  return false

proc checkSections*(s: var EventSections; owner: string; checkEmits: bool) =
  ## Reject `event` sections below the top level and -- for widgets --
  ## emits of events the widget did not declare.
  var found: NimNode = nil
  for r in s.rest:
    if findStrayEvent(r, found):
      s.fail(owner & ": `event` handlers must sit at the top level of the body",
        found)
      return
  if not checkEmits:
    return
  var name = ""
  for r in s.rest:
    if findUndeclaredEmit(r, s.decls, found, name):
      s.fail(owner & " emits `" & name & "` without declaring `emits " &
        name & "`", found)
      return
  for h in s.handlers:
    if findUndeclaredEmit(h.body, s.decls, found, name):
      s.fail(owner & " emits `" & name & "` without declaring `emits " &
        name & "`", found)
      return

# --- output --------------------------------------------------------------------

const
  handlerName = "evHandler"
  kindParam = "evKindArg"
  payloadParam = "evPayloadArg"

proc kindIdent*(name: string): string = name & "Kind"

proc reemitCalls(n: NimNode): NimNode =
  ## Copy a subtree, turning bare `reemit` idents into `reemit()` calls.
  if n.kind == nnkIdent and n.strVal == "reemit":
    return newCall(identNode("reemit"))
  result = copyNimNode(n)
  for c in n:
    result.add reemitCalls(c)

proc emitEventType*(dest: var seq[NimNode]; d: EventDecl; module: string) =
  ## The type, kind constant, registration and `emit` overload of `d`.
  let qualified = if module.len > 0: module & "." & d.name else: d.name
  # type Name* = object with exported fields
  let recList = newNimNode(nnkRecList)
  for f in d.fields:
    recList.add newTree(nnkIdentDefs, exported(f.name), f.typ.copyNimTree(),
      newEmptyNode())
  let objTy = newNimNode(nnkObjectTy).add(newEmptyNode(), newEmptyNode(),
    recList)
  dest.add newTree(nnkTypeSection,
    newTree(nnkTypeDef, exported(d.name), newEmptyNode(), objTy))
  # const NameKind* = EventKind(uint32(hash))
  dest.add newTree(nnkConstSection, newTree(nnkConstDef,
    exported(kindIdent(d.name)), newEmptyNode(),
    newCall(identNode("EventKind"), newLit(fnv1a(qualified)))))
  # registerEventKind(NameKind, "module.Name")
  dest.add newCall(identNode("registerEventKind"),
    identNode(kindIdent(d.name)), newLit(qualified))
  # proc emit*(ev: Name): bool {.discardable.} =
  #   var evPayload = ev
  #   result = dispatchEvent(NameKind, "Name", addr evPayload)
  let body = newStmtList(
    newVarStmt(identNode("evPayload"), identNode("ev")),
    newAssignment(identNode("result"),
      newCall(identNode("dispatchEvent"), identNode(kindIdent(d.name)),
        newLit(d.name), addrOf(identNode("evPayload")))))
  let params = newNimNode(nnkFormalParams).add(identNode("bool"))
  params.add newTree(nnkIdentDefs, identNode("ev"), identNode(d.name),
    newEmptyNode())
  dest.add routine(nnkProcDef, exported("emit"), params,
    pragmaList(identNode("discardable")), body)

proc emitEventFrame*(dest: var seq[NimNode]; s: EventSections;
                     frameName: string; idIdent: string) =
  ## The handler closure (when there are handlers), `pushEventFrame`, then
  ## the remaining statements in `try ... finally: popEventFrame()`. `idIdent`
  ## names an `ElementId` in scope keying the frame, "" for none.
  if s.handlers.len > 0:
    let ifChain = newNimNode(nnkIfStmt)
    for h in s.handlers:
      let onName = "evOn" & h.name
      let branch = newNimNode(nnkElifBranch).add(
        newCall(identNode("=="), identNode(kindParam),
          identNode(kindIdent(h.name))))
      let inner = newStmtList(
        newAssignment(identNode("result"), identNode("efConsumed")))
      # proc evOnName(e: var Name) {.closure.} = <body>
      let hp = newNimNode(nnkFormalParams).add(newEmptyNode())
      hp.add newTree(nnkIdentDefs,
        identNode(if h.binding.len > 0: h.binding else: "evUnusedArg"),
        newTree(nnkVarTy, identNode(h.name)), newEmptyNode())
      inner.add routine(nnkProcDef, identNode(onName), hp,
        pragmaList(identNode("closure")), reemitCalls(h.body))
      # evOnName(cast[ptr Name](evPayloadArg)[])
      inner.add newCall(identNode(onName),
        newTree(nnkBracketExpr,
          newTree(nnkCast, newTree(nnkPtrTy, identNode(h.name)),
            identNode(payloadParam))))
      branch.add inner
      ifChain.add branch
    # proc evHandler(evKindArg: EventKind, evPayloadArg: pointer): EventFlow = ...
    let fp = newNimNode(nnkFormalParams).add(identNode("EventFlow"))
    fp.add newTree(nnkIdentDefs, identNode(kindParam),
      identNode("EventKind"), newEmptyNode())
    fp.add newTree(nnkIdentDefs, identNode(payloadParam),
      identNode("pointer"), newEmptyNode())
    let handlerBody = newStmtList(
      newAssignment(identNode("result"), identNode("efPass")), ifChain)
    dest.add routine(nnkProcDef, identNode(handlerName), fp,
      pragmaList(identNode("closure")), handlerBody)

  # pushEventFrame("Name", uint32(hash), id, [handler, @[kinds]])
  var push = newCall(identNode("pushEventFrame"), newLit(frameName),
    newLit(fnv1a(frameName)))
  if idIdent.len > 0:
    push.add newTree(nnkDotExpr, identNode(idIdent), identNode("id"))
  else:
    push.add newLit(0'u32)
  if s.handlers.len > 0:
    push.add identNode(handlerName)
    let kinds = newNimNode(nnkBracket)
    for h in s.handlers:
      kinds.add identNode(kindIdent(h.name))
    push.add newTree(nnkPrefix, identNode("@"), kinds)
  dest.add push

  # try: <rest> finally: popEventFrame()
  let restList = newStmtList()
  for r in s.rest:
    restList.add r.copyNimTree()
  dest.add newTree(nnkTryStmt, restList,
    newTree(nnkFinally, newStmtList(newCall(identNode("popEventFrame")))))
