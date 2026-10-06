## Nimony template plugin: the `widget` definition macro.
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
## Named arguments bind to parameters by name (NIF `(vv name value)`), and
## the trailing block binds positionally to the parameter after the last
## named argument (`sigmatch.orderArgs`), which is `body` when slots are
## passed in declaration order. The wrapper routes that block through a
## named nested `{.closure.}` proc -- the capture form Nimony supports;
## `do:` literals compile to plain procs that cannot reference enclosing
## locals, so caller blocks can capture local state.
##
## Slot proctypes get `{.closure.}` injected so closure bodies and plain
## global procs both bind to them. The last declared parameter is treated
## as the block slot when its type is a proc type; `emptySlot` (declared
## next to the `widget` template) backs the defaults.
##
## Note on ownership: `NifBuilder` (TokenBuf) is move-only -- copies break
## its cursor ownership -- so parameter type trees are carried as
## `NifCursor`s into the (refcounted) input tree, never as copied buffers.
## `NifCursor` copies are cheap and safe.
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
## Input shape (verified against nifler output):
##   (stmts widget (oconstr Name (kv pname ptype)...) (stmts impl...))
## or, for `widget Name():`, the head is `(call Name)`; for `widget Name:`
## it is a bare atom. A modifier wraps the head in a command:
##   (cmd focusable (oconstr Name ...))
## (A `{.focusable.}` pragma would read better, but Nimony sem-checks a
## `pragmax` argument even for an `untyped` parameter and asserts on it.)

import plugins
import std/[syncio, envvars]

type
  WidgetParam = object
    name: string
    typ: NifCursor  ## the declared type, a value in the input tree
    isSlot: bool    ## declared type is a proc type
    injected: string  ## non-empty: a macro-added param of this type ident
    zeroDefault: bool ## defaults to `0` (the injected `tabIndex`)

proc atomText(n: NifCursor): string =
  case n.kind
  of Ident:
    result = n.identText
  of Symbol, SymbolDef:
    result = n.symText
  else:
    result = ""

proc isSlotType(n: NifCursor): bool =
  n.kind == TagLit and n.typeKind == ProctypeT

proc isVoidIdent(n: NifCursor): bool =
  n.kind == Ident and n.identText == "void"

proc isParamsTree(n: NifCursor): bool =
  n.kind == TagLit and n.tagText == "params"

proc addEmptyCall(dest: var NifBuilder; info: LineInfo; ident: string) =
  dest.withTree CallS, info:
    dest.addIdent ident

proc emitPragmasClosure(dest: var NifBuilder; info: LineInfo) =
  dest.openTree("pragmas", info)
  dest.addIdent "closure"
  dest.closeTree()

proc hasClosurePragma(n: NifCursor): bool =
  result = false
  if n.kind == TagLit and n.tagText == "pragmas":
    var c = firstChild(n)
    while c.hasMore:
      if c.eqIdent("closure"):
        return true
      skip c

proc emitPragmas(dest: var NifBuilder; info: LineInfo; n: NifCursor;
                 injectClosure: bool) =
  ## Copy the proctype's pragmas slot, ensuring a `closure` entry when
  ## `injectClosure` says the slot proc type must be liftable.
  if not injectClosure or hasClosurePragma(n):
    var q = n
    dest.takeTree q
  elif n.kind == TagLit and n.tagText == "pragmas":
    dest.openTree("pragmas", info)
    var c = firstChild(n)
    while c.hasMore:
      var q = c
      dest.takeTree q
      skip c
    dest.addIdent "closure"
    dest.closeTree()
  else:                          # `.` placeholder or missing
    emitPragmasClosure(dest, info)

proc emitType(dest: var NifBuilder; n: NifCursor; injectClosure: bool)

proc emitProctype(dest: var NifBuilder; n: NifCursor; injectClosure: bool) =
  ## Copy a `(proctype ...)` type tree in canonical layout:
  ##   (proctype <nilTag> (params) <ret> <pragmas>)
  ## nifler's source form carries four leading placeholder dots before
  ## `(params)`; re-checking THAT form resolves an inline `void` return
  ## through the magic-type inliner and leaves a `(void)` tree in the
  ## return slot, which the back end rejects. Emitting the ret slot as a
  ## `(void)` type tag instead routes it through `semLocalTypeImpl`'s
  ## `of VoidT` branch, which normalizes a return-type void to `.` -- the
  ## same shape hand-written sources end up with.
  let info = n.info
  var c = firstChild(n)
  var slots: seq[NifCursor] = @[]
  while c.hasMore:
    slots.add c
    skip c
  var p = 0
  while p < slots.len and not slots[p].isParamsTree:
    inc p
  if p >= slots.len:
    var whole = n
    dest.takeTree whole            # unrecognized shape: copy verbatim
    return
  let canonical = p == 1           # (proctype <nil> (params) ret pragmas)
  dest.openTree("proctype", info)
  if canonical:
    var q = slots[0]
    if q.kind == TagLit:
      dest.takeTree q
    else:
      dest.addEmptyNode info       # placeholder; sem defaults it to notnil
  else:
    dest.openTree("notnil", info)  # source layout: non-nilable by default
    dest.closeTree()
  var q = slots[p]
  dest.takeTree q                  # the params tree
  if p + 1 < slots.len:
    let ret = slots[p + 1]
    if isVoidIdent(ret) or (ret.kind == TagLit and ret.tagText == "void"):
      dest.openTree("void", info)
      dest.closeTree()
    else:
      emitType(dest, ret, false)
  else:
    dest.addEmptyNode info
  if p + 2 < slots.len:
    q = slots[p + 2]
    emitPragmas(dest, info, q, injectClosure)
  elif injectClosure:
    emitPragmasClosure(dest, info)
  else:
    dest.addEmptyNode info
  dest.closeTree()

proc emitType(dest: var NifBuilder; n: NifCursor; injectClosure: bool) =
  ## Copy a declared parameter type, normalizing inline proc types.
  if n.kind == TagLit and n.tagText == "proctype":
    emitProctype(dest, n, injectClosure)
  else:
    var c = n
    dest.takeTree c

proc emitParam(dest: var NifBuilder; info: LineInfo; p: WidgetParam) =
  ## (param name . . TYPE [default]) -- typed parameter of the generated
  ## implementation proc; proc-typed slots get `{.closure.}` types and
  ## default to the `emptySlot` proc.
  dest.withTree ParamU, info:
    dest.addIdent p.name
    dest.addEmptyNode2 info          # exported, pragmas
    if p.injected.len > 0:
      dest.addIdent p.injected
    else:
      dest.emitType(p.typ, p.isSlot)
    if p.isSlot:
      dest.addIdent "emptySlot"      # value default: a no-op closure
    elif p.zeroDefault:
      dest.addIntLit 0
    else:
      dest.addEmptyNode info

proc emitSlotParam(dest: var NifBuilder; info: LineInfo; p: WidgetParam;
                   isBlockSlot: bool) =
  ## untyped parameter of the generated wrapper template. The block slot
  ## defaults to a *statement* (`emptySlot()`), since its argument lands
  ## in the closure proc's body; every other slot defaults to the bare
  ## `emptySlot` ident, a valid proc value. Non-slot parameters get
  ## `emptySlot()` so that omitting a required data argument fails with a
  ## type mismatch at the implementation call instead of silently
  ## binding the trailing block. The injected `tabIndex` defaults to `0`.
  dest.withTree ParamU, info:
    dest.addIdent p.name
    dest.addEmptyNode2 info          # exported, pragmas
    dest.addIdent "untyped"
    if p.zeroDefault:
      dest.addIntLit 0
    elif p.isSlot and not isBlockSlot:
      dest.addIdent "emptySlot"
    else:
      dest.addEmptyCall(info, "emptySlot")

proc parseParams(head: NifCursor): seq[WidgetParam] =
  result = @[]
  var c = firstChild(head)
  skip c                        # the widget name
  while c.hasMore:
    if c.kind != TagLit or c.tagText != "kv":
      result.add WidgetParam(name: "")   # validation below rejects it
    else:
      var kv = firstChild(c)
      let pname = kv.atomText
      skip kv
      var p = WidgetParam(name: pname, typ: kv, isSlot: isSlotType(kv))
      result.add p
    skip c


proc hasParam(params: seq[WidgetParam]; name: string): bool =
  for p in params:
    if p.name == name:
      return true
  return false

proc headName(n: NifCursor): string =
  if n.kind == TagLit:
    result = firstChild(n).atomText
  else:
    result = n.atomText

proc transform(n: NifCursor): NifBuilder =
  result = createTree()
  let info = n.info
  var args = callArgs(n)

  if not args.hasMore:
    return errorTree("widget: expected `widget Name(params): body`", n)

  var head = args
  var focusable = false
  if head.kind == TagLit and head.tagText == "cmd":
    # `widget focusable Name(...)`: the modifier, then the real head
    var mc = firstChild(head)
    if not mc.eqIdent("focusable"):
      return errorTree("widget: unknown modifier `" & mc.atomText &
        "` (supported: focusable)", mc)
    focusable = true
    skip mc
    if not mc.hasMore:
      return errorTree("widget: expected `widget focusable Name(params)`",
        head)
    head = mc
  let name = headName(head)
  if name.len == 0:
    return errorTree("widget: expected `widget Name(params): body`", head)

  var params: seq[WidgetParam] = @[]
  if head.kind == TagLit:
    if head.tagText != "oconstr" and head.tagText != "call":
      return errorTree("widget: expected `Name` or `Name(params)`, got `" &
        head.tagText & "`", head)
    params = parseParams(head)
    for p in params:
      if p.name.len == 0 or not p.typ.hasMore or p.typ.kind == DotToken:
        return errorTree("widget `" & name & "`: every parameter needs a " &
          "type: `name: Type`", head)
  skip args                     # -> the implementation (stmts ...)

  if not args.hasMore or args.kind != TagLit or args.tagText != "stmts":
    return errorTree("widget `" & name & "`: expected an implementation body",
      args)
  let impl = args               # cursor into the (refcounted) input tree

  # the trailing block fills the last declared parameter when it is a slot
  var blockSlot = ""
  if params.len > 0 and params[^1].isSlot:
    blockSlot = params[^1].name

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

  # --- (proc NameImpl* <params> = impl) ---------------------------------
  result.withTree StmtsS, info:
    result.withTree ProcS, info:
      result.addIdent name & "Impl"
      result.addIdent "x"                 # exported
      result.addEmptyNode2 info           # pattern, typevars
      result.withTree ParamsU, info:
        for p in params:
          emitParam(result, info, p)
      result.addEmptyNode3 info           # result, pragmas, effects
      var ci = impl
      if focusable:
        # registerFocus(id, tabIndex) ahead of the body
        result.withTree StmtsS, info:
          result.withTree CallS, info:
            result.addIdent "registerFocus"
            result.addIdent "id"
            result.addIdent "tabIndex"
          result.takeTree ci
      else:
        result.takeTree ci

    # --- (template Name* <untyped params> = ...closure wrapper...) ------
    result.withTree TemplateS, info:
      result.addIdent name
      result.addIdent "x"                 # exported
      result.addEmptyNode2 info           # pattern, typevars
      result.withTree ParamsU, info:
        for p in params:
          emitSlotParam(result, info, p, p.name == blockSlot)
      result.addEmptyNode3 info           # result, pragmas, effects
      var slotSym = default(SymId)
      if blockSlot.len > 0:
        slotSym = genSym()
      result.withTree StmtsS, info:
        if blockSlot.len == 0:
          result.withTree CallS, info:
            result.addIdent name & "Impl"
            for p in params:
              result.addIdent p.name      # positional pass-through
        else:
          # block:
          #   proc slot(): void {.closure.} = <block stmts>
          #   NameImpl(args..., slot)
          result.withTree BlockS, info:
            result.addEmptyNode info      # unnamed block
            result.withTree StmtsS, info:
              result.withTree ProcS, info:
                result.addSymDef slotSym, info
                result.addEmptyNode3 info         # export, pattern, typevars
                result.withTree ParamsU, info:    # ()
                  discard
                result.addEmptyNode info          # result (void)
                emitPragmasClosure(result, info)  # {.closure.}
                result.addEmptyNode info          # effects
                result.withTree StmtsS, info:     # body = the block param
                  result.addIdent blockSlot
              result.withTree CallS, info:
                result.addIdent name & "Impl"
                for p in params:
                  if p.name != blockSlot:
                    result.addIdent p.name
                result.addSymUse slotSym, info

  if getEnv("WIDGET_DSL_DEBUG") != "":
    try:
      writeFile("/tmp/opencode/mwidget-" & name & ".nif", renderTree(result))
    except ErrorCode:
      discard

var inp = loadPluginInput()
saveTree transform(inp)
