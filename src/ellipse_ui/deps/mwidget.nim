## Standard Nim port of the nimony template plugin: the `widget` definition
## macro. Included into `ellipse_ui/ui`.
##
## Rewrites a widget definition
##
##   widget PageWrapper(title: string, rightAction: proc(): void,
##                      body: proc(): void):
##     ...
##     rightAction()
##     ...
##     body()
##
## into a pair of declarations:
##
##   proc PageWrapperImpl*(title: string,
##                         rightAction: proc(): void {.closure.} = emptySlot,
##                         body: proc(): void {.closure.} = emptySlot) = ...
##   template PageWrapper*(title: untyped = ..., rightAction: untyped = ...,
##                         body: untyped = ...): untyped =
##     block:
##       proc slotX(): void {.closure.} = body   # caller block spliced in
##       PageWrapperImpl(title, rightAction, slotX)
##
## The proc is the widget proper: slots are real closures and `slot()` in
## the implementation is a real call (conditional, repeated, any position).
## `PageWrapperImpl(...) do(): ...` works for callers that need no capture.
##
## The template adds the trailing-colon syntax:
##
##   PageWrapper(title = "Home", rightAction = renderAct):
##     textElement("This is the body")
##
## Named arguments bind to parameters by name, and the trailing block binds
## positionally to the last parameter (the `body` slot). Slot proctypes get
## `{.closure.}` injected so closure bodies and plain global procs both bind
## to them. The last declared parameter is treated as the block slot when
## its type is a proc type; `emptySlot` (declared next to the `widget`
## macro) backs the defaults.
##
## Value slots: a block slot may declare parameters --
##
##   widget TabbedView(id: ElementId, tabs: seq[string],
##                     body: proc(tabIndex: int): void):
##     ...
##     body(picked)
##
## The generated slot proc carries the declared parameter list, so the
## caller's trailing block sees those names in scope. Omitting a value
## slot's block splices its filler ident into the generated slot proc and
## fails there with a type error; `NameImpl` alone keeps working, since the
## implementation proc's default is the same generated
## `emptySlot_<Widget>_<param>` no-op of the slot's exact shape.
##
## Focusable widgets: a `focusable` modifier before the name
##
##   widget focusable Toggle(label: string, on: bool):
##     ...
##
## makes the widget a keyboard-focus stop (`ellipse_ui/focus`). The
## generated proc and template gain an `id: ElementId` parameter (first)
## and a `tabIndex: int = 0` parameter (last before the block slot) unless
## the definition declares either itself, and the implementation opens with
## `registerFocus(id, tabIndex)` -- so the body can ask `focused(id)`,
## `gainedFocus(id)`, `keyActivated(id)` or paint `.focusRing(id)`.
##
## Values and defaults: `widget Name(params) -> T:` gives the proc a return
## type and the template an `untyped` one, so `x = Name(...)` reads the
## widget's `result`. A parameter written `name = value` gets an inferred
## type and that default in both the proc and the template. A valued widget
## with a block slot leaves its slot proc in the caller's scope instead of
## a `block:`.
##
## Events (`ellipse_ui/events`): the body's top-level `emits Name(...)`
## lines and `event Name(e): ...` sections are lifted out (`meventgen`).
## Declared event types are generated ahead of the proc; every widget body
## opens an event frame -- keyed by `id` when the widget has an
## `id: ElementId` -- that holds its handlers while the rest of the body
## runs. A direct `emit Name(...)` of an event the widget does not declare
## is a compile error.
##
## Hot widgets: a `hot` modifier (with or without `focusable`)
##
##   widget hot StatusPill(label: string):
##     ...
##
## keeps the source exactly this small and generates the rest: a packed
## `NameParams` object, a library entry exported as `exportc
## "ellipseHot_Name"` -- the name the running app dlsyms -- and three
## `when defined(...)` shapes: the plain app compiles the body as usual;
## the hot app (`-d:ellipseHotApp`) turns `NameImpl` into pack-and-dispatch
## through `hotWidget` (`ellipse_ui/widgets`, `ellipse/hotload`); the
## library (`-d:ellipseHotLib`) compiles the body plus its entry. The body
## never lands in the hot app, so the library's fresh copy can never be
## interposed by the executable's stale one. See `ellipse/hotload`.
##
## Head shapes verified against the standard parser (see `meventgen`):
##   ObjConstr Name(field: T, ...), Call Name(), Ident Name. A modifier
##   wraps the head in a command: Command(focusable <head>).

import std/[macros, strutils, envvars]
import ./meventgen

type
  WidgetParam = object
    name: string
    typ: NimNode        ## the declared type (nil for `name = value`)
    isSlot: bool        ## declared type is a proc type
    slotArgs: bool      ## slot proctype declares parameters (a *value slot*)
    filler: string      ## non-empty: the generated no-op name backing its default
    injected: string    ## non-empty: a macro-added param of this type ident
    zeroDefault: bool   ## defaults to `0` (the injected `tabIndex`)
    defaultVal: NimNode ## `name = value`: the default (type inferred)
    hasDefault: bool

proc newIdent(s: string): NimNode = newIdentNode(s)

proc exported(name: string): NimNode =
  newTree(nnkPostfix, newIdent("*"), newIdent(name))

proc pragmaList(n: varargs[NimNode]): NimNode =
  result = newNimNode(nnkPragma)
  for x in n:
    result.add x

proc addrOf(n: NimNode): NimNode =
  newTree(nnkCommand, newIdent("addr"), n)

proc routine(kind: NimNodeKind, name: NimNode, params, pragmas,
             body: NimNode): NimNode =
  newTree(kind, name, newEmptyNode(), newEmptyNode(), params, pragmas,
    newEmptyNode(), body)

proc isProcTy(n: NimNode): bool = n.kind == nnkProcTy

proc slotParamsOf(t: NimNode): NimNode =
  ## The `FormalParams` child of a proc type, or nil.
  for c in t:
    if c.kind == nnkFormalParams:
      return c
  return nil

proc proctypeHasParams(t: NimNode): bool =
  let p = slotParamsOf(t)
  p != nil and p.len > 1

proc withClosure(t: NimNode): NimNode =
  ## Copy a proc type ensuring a `{.closure.}` pragma -- slot parameters and
  ## packed slot fields must accept caller closures.
  result = t.copyNimTree
  var pragmas: NimNode = nil
  for i in 0 ..< result.len:
    if result[i].kind == nnkPragma:
      pragmas = result[i]
  if pragmas != nil:
    for p in pragmas:
      if p.kind == nnkIdent and p.strVal == "closure":
        return result
    pragmas.add newIdent("closure")
  elif result.len > 1:
    result[result.len - 1] = pragmaList(newIdent("closure"))
  else:
    result.add pragmaList(newIdent("closure"))

proc paramType(p: WidgetParam): NimNode =
  if p.injected.len > 0:
    newIdent(p.injected)
  elif p.isSlot:
    withClosure(p.typ)
  else:
    p.typ.copyNimTree

proc emitSlotFiller(dest: var seq[NimNode]; p: WidgetParam) =
  ## `proc emptySlot_<Widget>_<param>(<slot params>): void = discard` -- a
  ## typed no-op backing a value slot's defaults. The parameter list is
  ## copied verbatim from the declared proctype.
  let fp = newNimNode(nnkFormalParams).add(newIdent("void"))
  let pp = slotParamsOf(p.typ)
  if pp != nil:
    for i in 1 ..< pp.len:
      fp.add pp[i].copyNimTree
  dest.add routine(nnkProcDef, exported(p.filler), fp, newEmptyNode(),
    newStmtList(newTree(nnkDiscardStmt, newEmptyNode())))

proc emitParam(dest: NimNode; p: WidgetParam) =
  ## A typed parameter of the generated implementation proc; proc-typed
  ## slots get `{.closure.}` types and default to the `emptySlot` proc.
  var defs = newTree(nnkIdentDefs, newIdent(p.name))
  if p.injected.len > 0:
    defs.add newIdent(p.injected)
  elif p.hasDefault:
    defs.add newEmptyNode()                    # inferred from the default
  else:
    defs.add p.paramType
  if p.isSlot:
    defs.add newIdent(if p.filler.len > 0: p.filler else: "emptySlot")
  elif p.zeroDefault:
    defs.add newLit(0)
  elif p.hasDefault:
    defs.add p.defaultVal.copyNimTree
  else:
    defs.add newEmptyNode()
  dest.add defs

proc emitSlotParam(dest: NimNode; p: WidgetParam; isBlockSlot: bool) =
  ## untyped parameter of the generated wrapper template. A plain block
  ## slot defaults to a *statement* (`emptySlot()`), since its argument
  ## lands in the closure proc's body; a *value* block slot defaults to
  ## the bare filler ident. Every other slot defaults to a bare proc
  ## ident. Non-slot parameters get `emptySlot()` so that omitting a
  ## required data argument fails with a type mismatch at the
  ## implementation call instead of silently binding the trailing block.
  var defs = newTree(nnkIdentDefs, newIdent(p.name), newIdent("untyped"))
  if p.zeroDefault:
    defs.add newLit(0)
  elif p.hasDefault:
    defs.add p.defaultVal.copyNimTree
  elif p.isSlot and not isBlockSlot:
    defs.add newIdent(if p.filler.len > 0: p.filler else: "emptySlot")
  elif p.isSlot and p.filler.len > 0:
    defs.add newIdent(p.filler)
  else:
    defs.add newCall(newIdent("emptySlot"))
  dest.add defs

proc packedConstr(name: string; params: seq[WidgetParam]): NimNode =
  ## `NameParams(label: label, ...)` -- pack the in-scope parameters.
  result = newTree(nnkObjConstr, newIdent(name & "Params"))
  for p in params:
    result.add newTree(nnkExprColonExpr, newIdent(p.name), newIdent(p.name))

proc emitImplShape(dest: var seq[NimNode]; name: string;
                   params: seq[WidgetParam]; hasRet: bool; callee: string;
                   viaWidget: bool) =
  ## `proc NameImpl*(params...) [-> bool]` for one of the two app shapes:
  ## pack the arguments, then either hand them to `hotWidget` (the
  ## dispatcher, which paints a placeholder while no library is loaded) or
  ## call the in-binary draw proc directly (plain builds).
  let fp = newNimNode(nnkFormalParams)
  if hasRet:
    fp.add newIdent("bool")
  else:
    fp.add newEmptyNode()
  for p in params:
    emitParam(fp, p)
  let packed = newIdent("packed")
  var body = newStmtList(newVarStmt(packed, packedConstr(name, params)))
  if hasRet:
    var call: NimNode
    if viaWidget:
      call = newCall(newIdent("hotWidget"), newLit("ellipseHot_" & name),
                     newLit(name), addrOf(packed))
    else:
      call = newCall(newIdent(callee), addrOf(packed))
    if viaWidget:
      body.add newAssignment(newIdent("result"),
        newTree(nnkInfix, newIdent(">"), call, newLit(0)))
    else:
      body.add newAssignment(newIdent("result"), call)
  else:
    # plain builds: the draw call is a void statement (discarding a void
    # expression is illegal); the dispatcher returns cint, so discard it
    if viaWidget:
      body.add newTree(nnkDiscardStmt, newCall(newIdent("hotWidget"),
        newLit("ellipseHot_" & name), newLit(name), addrOf(packed)))
    else:
      body.add newCall(newIdent(callee), addrOf(packed))
  dest.add routine(nnkProcDef, exported(name & "Impl"), fp, newEmptyNode(),
    body)

proc emitHotDrawProc(dest: var seq[NimNode]; name: string;
                     params: seq[WidgetParam]; hasRet: bool;
                     focusable: bool; sections: EventSections;
                     idIdent: string) =
  ## The body proper in packed form: `proc nameDraw(a: ptr NameParams)`
  ## unpacks every field to a local of its source name, so the author's
  ## body runs verbatim -- event frame included.
  let fp = newNimNode(nnkFormalParams)
  fp.add if hasRet: newIdent("bool") else: newEmptyNode()
  fp.add newTree(nnkIdentDefs, newIdent("a"),
    newTree(nnkPtrTy, newIdent(name & "Params")), newEmptyNode())
  var body = newStmtList()
  for p in params:
    body.add newTree(nnkLetSection, newTree(nnkIdentDefs, newIdent(p.name),
      newEmptyNode(), newTree(nnkDotExpr, newIdent("a"), newIdent(p.name))))
  if focusable:
    body.add newCall(newIdent("registerFocus"), newIdent("id"),
      newIdent("tabIndex"))
  var frame: seq[NimNode] = @[]
  emitEventFrame(frame, sections, name, idIdent)
  for n in frame:
    body.add n
  dest.add routine(nnkProcDef, newIdent(name.toLowerAscii[0 .. 0] &
    name[1 .. ^1] & "Draw"), fp, newEmptyNode(), body)

proc emitHotEntry(dest: var seq[NimNode]; name: string; hasRet: bool) =
  ## The exported library entry -- `exportc "ellipseHot_Name"` is exactly
  ## the name the running app scans for and dlsyms.
  let draw = name.toLowerAscii[0 .. 0] & name[1 .. ^1] & "Draw"
  let fp = newNimNode(nnkFormalParams).add(newIdent("cint"))
  fp.add newTree(nnkIdentDefs, newIdent("args"), newIdent("pointer"),
    newEmptyNode())
  var body = newStmtList(newTree(nnkLetSection, newTree(nnkIdentDefs,
    newIdent("a"), newEmptyNode(), newTree(nnkCast,
      newTree(nnkPtrTy, newIdent(name & "Params")), newIdent("args")))))
  if hasRet:
    # result = cint(ord(nameDraw(a)))
    body.add newAssignment(newIdent("result"), newCall(newIdent("cint"),
      newCall(newIdent("ord"), newCall(newIdent(draw), newIdent("a")))))
  else:
    body.add newCall(newIdent(draw), newIdent("a"))
    body.add newAssignment(newIdent("result"), newLit(0))
  dest.add routine(nnkProcDef, newIdent(
      name.toLowerAscii[0 .. 0] & name[1 .. ^1] & "HotEntry"), fp,
    pragmaList(newIdent("cdecl"), newTree(nnkExprColonExpr,
      newIdent("exportc"), newLit("ellipseHot_" & name))), body)

proc emitHotScaffolding(dest: var seq[NimNode]; name: string;
                        params: seq[WidgetParam]; hasRet: bool;
                        focusable: bool; sections: EventSections;
                        idIdent: string) =
  ## One widget, three shapes chosen by `when defined(...)` -- invisible
  ## from the source, which stays a plain `widget hot Name(...):`.
  ##
  ##   -d:ellipseHotApp   `NameImpl` packs and dispatches through the
  ##                      loaded library's entry (placeholder until one is)
  ##   -d:ellipseHotLib   the body proper (`nameDraw`) plus its entry
  ##   plain builds       the body, forwarded to directly: behaves exactly
  ##                      like a widget written without the modifier
  ##
  ## The body compiles into the library and the plain app only, never into
  ## the hot app -- so the library's (fresh) copy can never be interposed
  ## by the executable's (stale) one.
  # type NameParams = object, one field per (final) parameter
  let recList = newNimNode(nnkRecList)
  for p in params:
    recList.add newTree(nnkIdentDefs, newIdent(p.name), p.paramType,
      newEmptyNode())
  dest.add newTree(nnkTypeSection, newTree(nnkTypeDef,
    newIdent(name & "Params"), newEmptyNode(),
    newNimNode(nnkObjectTy).add(newEmptyNode(), newEmptyNode(), recList)))

  let appBranch = newNimNode(nnkElifBranch).add(
    newCall(newIdent("defined"), newIdent("ellipseHotApp")))
  var appBody: seq[NimNode] = @[]
  emitImplShape(appBody, name, params, hasRet, "", true)
  appBranch.add newStmtList(appBody)

  let elseNode = newNimNode(nnkElse)
  var elseBody: seq[NimNode] = @[]
  emitHotDrawProc(elseBody, name, params, hasRet, focusable, sections,
                  idIdent)
  var entryWhen: seq[NimNode] = @[]
  emitHotEntry(entryWhen, name, hasRet)
  elseBody.add newTree(nnkWhenStmt, newTree(nnkElifBranch,
    newCall(newIdent("defined"), newIdent("ellipseHotLib")),
    newStmtList(entryWhen)))
  emitImplShape(elseBody, name, params, hasRet,
    name.toLowerAscii[0 .. 0] & name[1 .. ^1] & "Draw", false)
  elseNode.add newStmtList(elseBody)

  dest.add newTree(nnkWhenStmt, appBranch, elseNode)

proc parseParams(head: NimNode): seq[WidgetParam] =
  result = @[]
  for i in 1 ..< head.len:
    let c = head[i]
    if c.kind == nnkExprColonExpr and c[0].kind == nnkIdent:
      let typ = c[1]
      var p = WidgetParam(name: c[0].strVal, typ: typ, isSlot: isProcTy(typ))
      p.slotArgs = p.isSlot and proctypeHasParams(typ)
      result.add p
    elif c.kind == nnkExprEqExpr and c[0].kind == nnkIdent:
      result.add WidgetParam(name: c[0].strVal, typ: c[1],
                             defaultVal: c[1], hasDefault: true)
    else:
      result.add WidgetParam(name: "")   # validation below rejects it

proc hasParam(params: seq[WidgetParam]; name: string): bool =
  for p in params:
    if p.name == name:
      return true
  return false

proc refsNames(n: NimNode; names: openArray[string]): bool =
  ## Does the tree mention any of `names` as an identifier anywhere?
  ## (Standard template/parameter scoping rewrites even field selectors
  ## like `activeTheme.text.control`, so selectors count too.)
  if n.kind == nnkIdent and n.strVal in names:
    return true
  for c in n:
    if refsNames(c, names):
      return true
  return false

proc wrapCollidingDefaults(name: string; params: var seq[WidgetParam];
                            helpers: var seq[NimNode]) =
  ## A `name = value` default is authored in the widget's own scope -- the
  ## nimony kit judged defaults there, where parameter names are unbound.
  ## Standard nim binds every preceding parameter inside later defaults
  ## (and template instantiation substitutes parameter names inside
  ## inserted argument/default trees), so a default mentioning a word that
  ## is also a parameter name (`fontSize = activeTheme.text.control` under
  ## a `text` parameter) would be rewritten to the caller's argument.
  ## Such defaults are hoisted into a `default_<Widget>_<param>()` proc
  ## compiled in the widget module: identifiers resolve at the definition
  ## scope, the value is still computed at the call site -- the nimony
  ## semantics exactly.
  var paramNames: seq[string] = @[]
  for p in params:
    paramNames.add p.name
  for i in 0 ..< params.len:
    if params[i].hasDefault and refsNames(params[i].defaultVal, paramNames):
      let helper = "default_" & name & "_" & params[i].name
      let fp = newNimNode(nnkFormalParams).add(newIdent("auto"))
      helpers.add routine(nnkProcDef, newIdent(helper), fp, newEmptyNode(),
        newStmtList(params[i].defaultVal.copyNimTree()))
      params[i].defaultVal = newCall(newIdent(helper))

proc strParamsOf(t: NimNode): seq[string] =
  ## Parameter source strings of a slot proc type, e.g. "tabIndex: int".
  let pp = slotParamsOf(t)
  if pp != nil:
    for i in 1 ..< pp.len:
      let d = pp[i]
      if d.kind == nnkIdentDefs and d.len >= 2:
        result.add d[0].strVal & ": " & d[1].toStrLit.strVal

proc ellipseWidgetSlots*(args: NimNode; implName: string;
    paramNames, defaults: openArray[string]; blockSlot: string;
    slotParams: openArray[string]; wrapBlock: bool): NimNode =
  ## The sigmatch of a value-slot widget wrapper (nimony rewrote these at
  ## the AST level; standard-nim *templates* would capture-avoid the slot
  ## proc's declared parameters away from the caller's trailing block, so
  ## the wrapper is a macro and this proc binds its arguments): named
  ## `name = value` arguments bind by name, the rest positionally, the
  ## trailing block to the slot; omitted parameters take the widget's
  ## defaults. The block lands inside the generated slot proc -- its
  ## declared parameter names are in the caller block's scope.
  var items: seq[NimNode] = @[]
  for x in args:
    items.add x
  var blockArg: NimNode = nil
  if items.len > 0 and blockSlot.len > 0 and
      items[^1].kind == nnkStmtList:
    blockArg = items[^1]
    items.setLen(items.len - 1)
  var named: seq[(string, NimNode)] = @[]
  var pos: seq[NimNode] = @[]
  for x in items:
    if x.kind == nnkExprEqExpr and x.len >= 2 and x[0].kind == nnkIdent:
      named.add (x[0].strVal, x[1])
    else:
      pos.add x
  var bound: seq[NimNode] = @[]
  var slotVal: NimNode = nil
  var slotIdx = -1
  var pi = 0
  for i, pn in paramNames:
    var val: NimNode = nil
    for j in 0 ..< named.len:
      if named[j][0] == pn and named[j][1] != nil:
        val = named[j][1]
        named[j][1] = nil
        break
    if val == nil and pi < pos.len:
      if pn != blockSlot or blockArg == nil:
        val = pos[pi]
        inc pi
    if val == nil:
      if pn == blockSlot and blockArg != nil:
        val = blockArg
      else:
        val = parseExpr(defaults[i])
    if pn == blockSlot:
      slotVal = val
      slotIdx = i
    bound.add val
  let impl = newCall(newIdentNode(implName))
  if blockSlot.len == 0:
    for b in bound:
      impl.add b
    return impl
  let slotSym = genSym(nskProc, "slot")
  let fp = newNimNode(nnkFormalParams).add(newIdentNode("void"))
  for sp in slotParams:
    let e = parseExpr(sp)   # "name: Type" -> nnkExprColonExpr
    fp.add newTree(nnkIdentDefs, e[0], e[1], newEmptyNode())
  let slotProc = routine(nnkProcDef, slotSym, fp,
    pragmaList(newIdent("closure")), newStmtList(slotVal))
  for i, b in bound:
    if i != slotIdx:
      impl.add b
  impl.add slotSym
  let stmts = newStmtList(slotProc, impl)
  if wrapBlock:
    newTree(nnkBlockStmt, newEmptyNode(), stmts)
  else:
    stmts

macro widget*(head: untyped, body: untyped): untyped =
  ## Define a widget: the `NameImpl` proc plus the `Name` call-site
  ## template (see the module header).
  var h = head
  var focusable = false
  var hot = false
  # modifiers nest: `widget hot focusable Name(...)` arrives as
  # Command(hot, Command(focusable, <head>)); accept either order
  while h.kind == nnkCommand and h.len == 2 and h[0].kind == nnkIdent:
    case h[0].strVal
    of "focusable": focusable = true
    of "hot": hot = true
    else:
      error("widget: unknown modifier `" & h[0].strVal &
        "` (supported: focusable, hot)", h)
    h = h[1]
  # `Name(params) -> T`: a widget with a value, returned by both the
  # implementation proc and the wrapper template
  var retType: NimNode = nil
  var hasRet = false
  if h.kind == nnkInfix and h[0].kind == nnkIdent and h[0].strVal == "->":
    retType = h[2]
    hasRet = true
    h = h[1]
  var name = ""
  var params: seq[WidgetParam] = @[]
  case h.kind
  of nnkIdent:
    name = h.strVal
  of nnkCall, nnkObjConstr:
    if h[0].kind != nnkIdent:
      error("widget: expected `Name` or `Name(params)`", h)
    name = h[0].strVal
    if h.kind == nnkCall and h.len > 1:
      error("widget: expected `Name` or `Name(params)`, got a call", h)
    params = parseParams(h)
  else:
    error("widget: expected `widget [modifiers] Name(params): body`", h)
  if name.len == 0:
    error("widget: expected `widget Name(params): body`", h)
  for p in params:
    if p.name.len == 0 or (not p.hasDefault and p.typ.isNil) or
        p.typ.kind == nnkEmpty:
      error("widget `" & name & "`: every parameter needs a type or a " &
        "default: `name: Type` / `name = value`", head)

  if body.kind != nnkStmtList:
    error("widget `" & name & "`: expected an implementation body", body)

  # events: lift `emits` / `event` sections out of the body
  let owner = "widget `" & name & "`"
  var sections = collectEventSections(body, owner, allowEmits = true)
  if sections.error.len == 0:
    checkSections(sections, owner, checkEmits = true)
  if sections.error.len > 0:
    error(sections.error, sections.errorAt)

  # the trailing block fills the last declared parameter when it is a slot
  var blockSlot = ""
  if params.len > 0 and params[^1].isSlot:
    blockSlot = params[^1].name

  # value slots (parameterized proc types): each gets a generated no-op
  # proc of the same shape backing its defaults, named after the widget
  for i in 0 ..< params.len:
    if params[i].slotArgs:
      params[i].filler = "emptySlot_" & name & "_" & params[i].name

  # focusable: `id` leads, `tabIndex` sits right before the block slot so
  # `W(id = x, ..., tabIndex = 2): body` still hands the block to the slot
  if focusable:
    var full: seq[WidgetParam] = @[]
    if not hasParam(params, "id"):
      full.add WidgetParam(name: "id", injected: "ElementId")
    let addTab = not hasParam(params, "tabIndex")
    for i in 0 ..< params.len:
      if addTab and blockSlot.len > 0 and i == params.len - 1:
        full.add WidgetParam(name: "tabIndex", injected: "int",
                             zeroDefault: true)
      full.add params[i]
    if addTab and blockSlot.len == 0:
      full.add WidgetParam(name: "tabIndex", injected: "int",
                           zeroDefault: true)
    params = full

  # the frame is keyed by the widget's element id when it has one
  var idIdent = ""
  for p in params:
    if p.name == "id" and (p.injected == "ElementId" or
        (p.typ != nil and p.typ.kind == nnkIdent and
         p.typ.strVal == "ElementId")):
      idIdent = "id"

  if hot and hasRet and not (retType.kind == nnkIdent and
      retType.strVal == "bool"):
    error("widget `" & name & "`: hot widgets return nothing, or `bool` " &
      "through `focusable` (packed returns cross the library boundary by " &
      "value)", head)

  # defaults that mention a parameter name are hoisted to a helper proc:
  # standard nim would bind/insert the parameter's argument inside them
  # (see `wrapCollidingDefaults`)
  var helpers: seq[NimNode] = @[]
  wrapCollidingDefaults(name, params, helpers)

  result = newStmtList()
  # event types this widget declares
  var declOut: seq[NimNode] = @[]
  for d in sections.decls:
    if d.declares:
      emitEventType(declOut, d, moduleNameOf(head.lineInfoObj))
  for n in declOut:
    result.add n
  # hoisted default-value helpers
  for n in helpers:
    result.add n
  # no-op procs backing value slots' defaults
  var fillers: seq[NimNode] = @[]
  for p in params:
    if p.slotArgs:
      emitSlotFiller(fillers, p)
  for n in fillers:
    result.add n

  if hot:
    var scaffold: seq[NimNode] = @[]
    emitHotScaffolding(scaffold, name, params, hasRet, focusable, sections,
                       idIdent)
    for n in scaffold:
      result.add n
  else:
    let fp = newNimNode(nnkFormalParams)
    fp.add if hasRet: retType.copyNimTree() else: newEmptyNode()
    for p in params:
      emitParam(fp, p)
    var implBody = newStmtList()
    if focusable:
      implBody.add newCall(newIdent("registerFocus"), newIdent("id"),
        newIdent("tabIndex"))
    var frame: seq[NimNode] = @[]
    emitEventFrame(frame, sections, name, idIdent)
    for n in frame:
      implBody.add n
    result.add routine(nnkProcDef, exported(name & "Impl"), fp,
      newEmptyNode(), implBody)

  # --- the caller wrapper -----------------------------------------------
  if blockSlot.len > 0:
    # A slot widget's wrapper splices the caller's trailing block into a
    # generated proc. As a standard-nim *template* that substitution is
    # capture-avoiding (the block's free idents keep their call-site
    # bindings, which breaks a value slot's declared parameters, and a
    # genSym'd slot proc inside a template body trips cgen), so the
    # wrapper is a macro: `ellipseWidgetSlots` binds the args and builds
    # the slot proc at each expansion, exactly where the nimony plugin
    # rewrote the tree.
    let names = newTree(nnkBracket)
    let defs = newTree(nnkBracket)
    for p in params:
      names.add newLit(p.name)
      if p.zeroDefault:
        defs.add newLit("0")
      elif p.hasDefault:
        defs.add newLit(p.defaultVal.toStrLit.strVal)
      elif p.isSlot and p.name != blockSlot:
        defs.add newLit(if p.filler.len > 0: p.filler else: "emptySlot")
      elif p.name == blockSlot and p.filler.len > 0:
        defs.add newLit(p.filler)
      else:
        defs.add newLit("emptySlot()")
    let sps = newTree(nnkBracket)
    for p in params:
      if p.name == blockSlot:
        for s in strParamsOf(p.typ):
          sps.add newLit(s)
    let dispatch = newCall(newIdent("ellipseWidgetSlots"),
      newIdent("args"), newLit(name & "Impl"), names, defs,
      newLit(blockSlot), sps, newLit(not hasRet))
    let mp = newNimNode(nnkFormalParams).add(newIdent("untyped"))
    mp.add newTree(nnkIdentDefs, newIdent("args"),
      newTree(nnkBracketExpr, newIdent("varargs"), newIdent("untyped")),
      newEmptyNode())
    result.add routine(nnkMacroDef, exported(name), mp, newEmptyNode(),
      dispatch)
  else:
    # No block slot: a plain template wrapper, params passed through by
    # position; omitted args bind the same defaults as the nimony plugin
    # emitted (`emptySlot()` for data params, so forgetting one fails at
    # the implementation call rather than binding the trailing block).
    let tp = newNimNode(nnkFormalParams)
    tp.add if hasRet: newIdent("untyped") else: newEmptyNode()
    for p in params:
      emitSlotParam(tp, p, false)
    var call = newCall(newIdent(name & "Impl"))
    for p in params:
      call.add newIdent(p.name)          # positional pass-through
    result.add routine(nnkTemplateDef, exported(name), tp, newEmptyNode(),
      call)

  if getEnv("WIDGET_DSL_DEBUG").len > 0:
    echo "=== generated for ", name
    echo result.repr
