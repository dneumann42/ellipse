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
## Values and defaults: `widget Name(params) -> T:` gives the proc a
## return type and the template an `untyped` one, so `x = Name(...)` reads
## the widget's `result` (head shape `(infix -> <head> T)`). A parameter
## written `name = value` -- `(vv name value)` -- gets an inferred type and
## that default in both the proc and the template. A valued widget with a
## block slot leaves its slot proc in the caller's scope instead of a
## `block:`, which Nimony cannot prove initializes a `let`.
##
## Events (`ellipse_ui/events`): the body's top-level `emits Name(...)`
## lines and `event Name(e): ...` sections are lifted out (`meventgen`).
## Declared event types are generated ahead of the proc; every widget body
## opens an event frame -- keyed by `id` when the widget has an
## `id: ElementId` -- that holds its handlers while the rest of the body
## runs:
##
##   widget focusable Toggle(label: string, on: bool):
##     emits Toggled(on: bool)
##     event Toggled(e):
##       reemit
##     if keyActivated(id):
##       emit Toggled(on: not on)
##
## A direct `emit Name(...)` of an event the widget does not declare is a
## compile error.
##
## Hot widgets: a `hot` modifier (with or without `focusable`)
##
##   widget hot StatusPill(label: string):
##     ...
##
## keeps the source exactly this small and generates the rest: a packed
## `NameParams` object, a library entry exported as
## `(exportc "ellipseHot_Name")` -- the record the module's NIF carries
## and the running app dlsyms -- and three `when defined(...)` shapes:
## the plain app compiles the body as usual; the hot app
## (`-d:ellipseHotApp`) turns `NameImpl` into pack-and-dispatch through
## `hotWidget` (`ellipse_ui/widgets`, `ellipse/hotload`); the library
## (`-d:ellipseHotLib`) compiles the body plus its entry. The body never
## lands in the hot app, so the library's fresh copy can never be
## interposed by the executable's stale one. See `ellipse/hotload`.
##
## Input shape (verified against nifler output):
##   (stmts widget (oconstr Name (kv pname ptype)...) (stmts impl...))
## or, for `widget Name():`, the head is `(call Name)`; for `widget Name:`
## it is a bare atom. A modifier wraps the head in a command:
##   (cmd focusable (oconstr Name ...))
## (A `{.focusable.}` pragma would read better, but Nimony sem-checks a
## `pragmax` argument even for an `untyped` parameter and asserts on it.)

import plugins
import std/[syncio, strutils, envvars]
import ./meventgen

type
  WidgetParam = object
    name: string
    typ: NifCursor  ## the declared type, a value in the input tree
    isSlot: bool    ## declared type is a proc type
    injected: string  ## non-empty: a macro-added param of this type ident
    zeroDefault: bool ## defaults to `0` (the injected `tabIndex`)
    default: NifCursor ## `name = value`: the default (type inferred)
    hasDefault: bool

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
    elif p.hasDefault:
      dest.addEmptyNode info         # `name = value`: inferred from it
    else:
      dest.emitType(p.typ, p.isSlot)
    if p.isSlot:
      dest.addIdent "emptySlot"      # value default: a no-op closure
    elif p.zeroDefault:
      dest.addIntLit 0
    elif p.hasDefault:
      var d = p.default
      dest.takeTree d
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
  ## binding the trailing block. The injected `tabIndex` defaults to `0`;
  ## a `name = value` parameter repeats its default here, so an omitted
  ## argument reaches the implementation as that value (evaluated at the
  ## call site -- defaults should name things every caller can see).
  dest.withTree ParamU, info:
    dest.addIdent p.name
    dest.addEmptyNode2 info          # exported, pragmas
    dest.addIdent "untyped"
    if p.zeroDefault:
      dest.addIntLit 0
    elif p.hasDefault:
      var d = p.default
      dest.takeTree d
    elif p.isSlot and not isBlockSlot:
      dest.addIdent "emptySlot"
    else:
      dest.addEmptyCall(info, "emptySlot")

proc emitSlotProcAndCall(dest: var NifBuilder; info: LineInfo; name: string;
                         params: seq[WidgetParam]; blockSlot: string;
                         slotSym: SymId) =
  ## `proc slot() {.closure.} = <block param>` then `NameImpl(..., slot)`.
  dest.withTree ProcS, info:
    dest.addSymDef slotSym, info
    dest.addEmptyNode3 info         # export, pattern, typevars
    dest.withTree ParamsU, info:    # ()
      discard
    dest.addEmptyNode info          # result (void)
    emitPragmasClosure(dest, info)  # {.closure.}
    dest.addEmptyNode info          # effects
    dest.withTree StmtsS, info:     # body = the block param
      dest.addIdent blockSlot
  dest.withTree CallS, info:
    dest.addIdent name & "Impl"
    for p in params:
      if p.name != blockSlot:
        dest.addIdent p.name
    dest.addSymUse slotSym, info

proc lcFirst(s: string): string =
  if s.len == 0: s else: toLowerAscii(s[0]) & substr(s, 1)

proc emitArgsObject(dest: var NifBuilder; info: LineInfo; name: string;
                    params: seq[WidgetParam]) =
  ## `type NameParams = object`, one field per (final) parameter. App and
  ## library compile this from the same source identically, so the packed
  ## layout agrees without a second definition anywhere.
  dest.openTree("type", info)
  dest.addIdent name & "Params"
  dest.addEmptyNode3 info
  dest.openTree("object", info)
  dest.addEmptyNode info             # no inheritance
  for p in params:
    dest.openTree("fld", info)
    dest.addIdent p.name
    dest.addEmptyNode2 info          # exported, pragmas
    if p.injected.len > 0:
      dest.addIdent p.injected
    else:
      dest.emitType(p.typ, true)
    dest.addEmptyNode info           # no default
    dest.closeTree()
  dest.closeTree()                   # object
  dest.closeTree()                   # type

proc emitPackVar(dest: var NifBuilder; info: LineInfo; name: string;
                 params: seq[WidgetParam]): SymId =
  ## `var packed = NameParams(p = p, ...)` from the in-scope parameters;
  ## returns the local's symbol.
  result = genSym()
  dest.openTree("var", info)
  dest.addSymDef result, info
  dest.addEmptyNode3 info
  dest.openTree("oconstr", info)
  dest.addIdent name & "Params"
  for p in params:
    dest.openTree("kv", info)
    dest.addIdent p.name
    dest.addIdent p.name
    dest.closeTree()
  dest.closeTree()
  dest.closeTree()

proc emitAddrOf(dest: var NifBuilder; info: LineInfo; arg: SymId) =
  dest.openTree("cmd", info)
  dest.addIdent "addr"
  dest.addSymUse arg, info
  dest.closeTree()

proc emitImplShape(dest: var NifBuilder; info: LineInfo; name: string;
                   params: seq[WidgetParam]; hasRet: bool; callee: string;
                   viaWidget: bool) =
  ## `proc NameImpl*(params...) [-> bool]` for one of the two app shapes:
  ## pack the arguments, then either hand the block to `hotWidget` (the
  ## dispatcher, which paints a placeholder itself while no library is
  ## loaded) or call the in-binary draw proc directly (plain builds).
  dest.openTree("proc", info)
  dest.addIdent name & "Impl"
  dest.addIdent "x"
  dest.addEmptyNode2 info
  dest.openTree("params", info)
  for p in params:
    emitParam(dest, info, p)
  dest.closeTree()
  if hasRet:
    dest.addIdent "bool"
    dest.addEmptyNode2 info
  else:
    dest.addEmptyNode3 info
  dest.openTree("stmts", info)
  let packed = emitPackVar(dest, info, name, params)
  if hasRet:
    dest.openTree("asgn", info)
    dest.addIdent "result"
    if viaWidget:
      dest.openTree("infix", info)
      dest.addIdent ">"
      dest.openTree("call", info)
      dest.addIdent "hotWidget"
      dest.addStrLit "ellipseHot_" & name
      dest.addStrLit name
      emitAddrOf(dest, info, packed)
      dest.closeTree()
      dest.addIntLit 0
      dest.closeTree()                # infix
    else:
      dest.openTree("call", info)
      dest.addIdent callee
      emitAddrOf(dest, info, packed)
      dest.closeTree()
    dest.closeTree()                  # asgn
  else:
    # plain builds: the draw call is a void statement (discarding a void
    # expression is illegal); the dispatcher returns cint, so discard it
    if viaWidget:
      dest.openTree("discard", info)
      dest.openTree("call", info)
      dest.addIdent "hotWidget"
      dest.addStrLit "ellipseHot_" & name
      dest.addStrLit name
      emitAddrOf(dest, info, packed)
      dest.closeTree()
      dest.closeTree()                  # discard
    else:
      dest.openTree("call", info)
      dest.addIdent callee
      emitAddrOf(dest, info, packed)
      dest.closeTree()
  dest.closeTree()                    # stmts
  dest.closeTree()                    # proc

proc emitHotDrawProc(dest: var NifBuilder; info: LineInfo; name: string;
                     params: seq[WidgetParam]; hasRet: bool;
                     focusable: bool; sections: EventSections;
                     idIdent: string) =
  ## The body proper in packed form: `proc nameDraw(a: ptr NameParams)`
  ## unpacks every field to a local of its source name, so the author's
  ## body runs verbatim -- event frame included.
  dest.openTree("proc", info)
  dest.addIdent lcFirst(name) & "Draw"
  dest.addEmptyNode info
  dest.addEmptyNode2 info
  dest.openTree("params", info)
  dest.openTree("param", info)
  dest.addIdent "a"
  dest.addEmptyNode2 info
  dest.openTree("ptr", info)
  dest.addIdent name & "Params"
  dest.closeTree()
  dest.addEmptyNode info
  dest.closeTree()                    # param a
  dest.closeTree()                    # params
  if hasRet:
    dest.addIdent "bool"
    dest.addEmptyNode2 info
  else:
    dest.addEmptyNode3 info
  dest.openTree("stmts", info)
  for p in params:
    dest.openTree("let", info)
    dest.addIdent p.name
    dest.addEmptyNode3 info
    dest.openTree("dot", info)
    dest.addIdent "a"
    dest.addIdent p.name
    dest.closeTree()
    dest.closeTree()                  # let
  if focusable:
    dest.withTree CallS, info:
      dest.addIdent "registerFocus"
      dest.addIdent "id"
      dest.addIdent "tabIndex"
  emitEventFrame(dest, info, sections, name, idIdent)
  dest.closeTree()                    # stmts
  dest.closeTree()                    # proc

proc emitHotEntry(dest: var NifBuilder; info: LineInfo; name: string;
                  hasRet: bool) =
  ## The exported library entry -- `(exportc "ellipseHot_Name")` is exactly
  ## the record the module's NIF carries, and the name the running app
  ## scans for and dlsyms.
  dest.openTree("proc", info)
  dest.addIdent lcFirst(name) & "HotEntry"
  dest.addEmptyNode info
  dest.addEmptyNode2 info
  dest.openTree("params", info)
  dest.openTree("param", info)
  dest.addIdent "args"
  dest.addEmptyNode2 info
  dest.addIdent "pointer"
  dest.addEmptyNode info
  dest.closeTree()                    # param args
  dest.closeTree()                    # params
  dest.addIdent "cint"
  dest.openTree("pragmas", info)
  dest.addIdent "cdecl"
  dest.openTree("kv", info)
  dest.addIdent "exportc"
  dest.addStrLit "ellipseHot_" & name
  dest.closeTree()
  dest.closeTree()                    # pragmas
  dest.addEmptyNode info              # effects
  dest.openTree("stmts", info)
  dest.openTree("let", info)
  dest.addIdent "a"
  dest.addEmptyNode3 info
  dest.openTree("cast", info)
  dest.openTree("ptr", info)
  dest.addIdent name & "Params"
  dest.closeTree()
  dest.addIdent "args"
  dest.closeTree()                    # cast
  dest.closeTree()                    # let a
  if hasRet:
    # result = cint(ord(nameDraw(a)))
    dest.openTree("asgn", info)
    dest.addIdent "result"
    dest.openTree("call", info)
    dest.addIdent "cint"
    dest.openTree("call", info)
    dest.addIdent "ord"
    dest.openTree("call", info)
    dest.addIdent lcFirst(name) & "Draw"
    dest.addIdent "a"
    dest.closeTree()                  # draw
    dest.closeTree()                  # ord
    dest.closeTree()                  # cint
    dest.closeTree()                  # asgn
  else:
    dest.openTree("call", info)
    dest.addIdent lcFirst(name) & "Draw"
    dest.addIdent "a"
    dest.closeTree()
    dest.openTree("asgn", info)
    dest.addIdent "result"
    dest.addIntLit 0
    dest.closeTree()
  dest.closeTree()                    # stmts
  dest.closeTree()                    # proc

proc emitHotScaffolding(dest: var NifBuilder; info: LineInfo; name: string;
                        params: seq[WidgetParam]; hasRet: bool;
                        retType: NifCursor; focusable: bool;
                        sections: EventSections; idIdent: string) =
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
  emitArgsObject(dest, info, name, params)

  dest.openTree("when", info)
  dest.openTree("elif", info)
  dest.openTree("call", info)
  dest.addIdent "defined"
  dest.addIdent "ellipseHotApp"
  dest.closeTree()                    # defined(ellipseHotApp)
  dest.openTree("stmts", info)
  emitImplShape(dest, info, name, params, hasRet, "", true)
  dest.closeTree()                    # stmts
  dest.closeTree()                    # elif

  dest.openTree("else", info)
  dest.openTree("stmts", info)
  emitHotDrawProc(dest, info, name, params, hasRet, focusable, sections,
                  idIdent)
  dest.openTree("when", info)
  dest.openTree("elif", info)
  dest.openTree("call", info)
  dest.addIdent "defined"
  dest.addIdent "ellipseHotLib"
  dest.closeTree()
  dest.openTree("stmts", info)
  emitHotEntry(dest, info, name, hasRet)
  dest.closeTree()                    # stmts
  dest.closeTree()                    # elif
  dest.closeTree()                    # inner when
  emitImplShape(dest, info, name, params, hasRet,
                lcFirst(name) & "Draw", false)
  dest.closeTree()                    # stmts
  dest.closeTree()                    # else
  dest.closeTree()                    # outer when

proc parseParams(head: NifCursor): seq[WidgetParam] =
  result = @[]
  var c = firstChild(head)
  skip c                        # the widget name
  while c.hasMore:
    if c.kind == TagLit and c.tagText == "kv":         # name: Type
      var kv = firstChild(c)
      let pname = kv.atomText
      skip kv
      var p = WidgetParam(name: pname, typ: kv, isSlot: isSlotType(kv))
      result.add p
    elif c.kind == TagLit and c.tagText == "vv":       # name = default
      var vv = firstChild(c)
      let pname = vv.atomText
      skip vv
      result.add WidgetParam(name: pname, typ: vv, default: vv,
                             hasDefault: true)
    else:
      result.add WidgetParam(name: "")   # validation below rejects it
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
  var hot = false
  # modifiers nest: `widget hot focusable Name(...)` arrives as
  # (cmd hot (cmd focusable <head>)); accept either order
  while head.kind == TagLit and head.tagText == "cmd":
    var mc = firstChild(head)
    if mc.eqIdent("focusable"):
      focusable = true
    elif mc.eqIdent("hot"):
      hot = true
    else:
      return errorTree("widget: unknown modifier `" & mc.atomText &
        "` (supported: focusable, hot)", mc)
    skip mc
    if not mc.hasMore:
      return errorTree("widget: expected `widget [modifiers] Name(params)`",
        head)
    head = mc
  # `Name(params) -> T`: a widget with a value, returned by both the
  # implementation proc and the wrapper template
  var retType = default(NifCursor)
  var hasRet = false
  if head.kind == TagLit and head.tagText == "infix":
    var ic = firstChild(head)
    if not ic.eqIdent("->"):
      return errorTree("widget: expected `Name(params)` or " &
        "`Name(params) -> T`", head)
    skip ic
    let h = ic
    skip ic
    if not ic.hasMore:
      return errorTree("widget: expected a type after `->`", head)
    retType = ic
    hasRet = true
    head = h
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
          "type or a default: `name: Type` / `name = value`", head)
  skip args                     # -> the implementation (stmts ...)

  if not args.hasMore or args.kind != TagLit or args.tagText != "stmts":
    return errorTree("widget `" & name & "`: expected an implementation body",
      args)
  let impl = args               # cursor into the (refcounted) input tree

  # events: lift `emits` / `event` sections out of the body
  let owner = "widget `" & name & "`"
  var sections = collectEventSections(impl, owner, allowEmits = true)
  if sections.error.len == 0:
    checkSections(sections, owner, checkEmits = true)
  if sections.error.len > 0:
    return errorTree(sections.error, sections.errorAt)

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

  # the frame is keyed by the widget's element id when it has one
  var idIdent = ""
  for p in params:
    if p.name == "id" and (p.injected == "ElementId" or
        (p.typ.kind == Ident and p.typ.identText == "ElementId")):
      idIdent = "id"

  if hot and hasRet and not (retType.kind == Ident and
      retType.identText == "bool"):
    return errorTree("widget `" & name & "`: hot widgets return nothing, " &
      "or `bool` through `focusable` (packed returns cross the library " &
      "boundary by value)", head)

  # --- (proc NameImpl* <params> = impl) ---------------------------------
  result.withTree StmtsS, info:
    # --- event types this widget declares ---------------------------------
    for d in sections.decls:
      if d.declares:
        emitEventType(result, d, moduleName(info))

    if hot:
      emitHotScaffolding(result, info, name, params, hasRet, retType,
                         focusable, sections, idIdent)
    else:
      result.withTree ProcS, info:
        result.addIdent name & "Impl"
        result.addIdent "x"                 # exported
        result.addEmptyNode2 info           # pattern, typevars
        result.withTree ParamsU, info:
          for p in params:
            emitParam(result, info, p)
        if hasRet:
          result.emitType(retType, false)
          result.addEmptyNode2 info         # pragmas, effects
        else:
          result.addEmptyNode3 info         # result, pragmas, effects
        result.withTree StmtsS, info:
          if focusable:
            # registerFocus(id, tabIndex) ahead of the body
            result.withTree CallS, info:
              result.addIdent "registerFocus"
              result.addIdent "id"
              result.addIdent "tabIndex"
          # handlers + pushEventFrame + try: body finally: popEventFrame()
          emitEventFrame(result, info, sections, name, idIdent)

    # --- (template Name* <untyped params> = ...closure wrapper...) ------
    result.withTree TemplateS, info:
      result.addIdent name
      result.addIdent "x"                 # exported
      result.addEmptyNode2 info           # pattern, typevars
      result.withTree ParamsU, info:
        for p in params:
          emitSlotParam(result, info, p, p.name == blockSlot)
      if hasRet:
        result.addIdent "untyped"         # the call's value
        result.addEmptyNode2 info         # pragmas, effects
      else:
        result.addEmptyNode3 info         # result, pragmas, effects
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
          # A valued widget drops the `block:` -- Nimony cannot prove a
          # `let x = block: ...` initialized -- and leaves the slot proc
          # in the caller's scope; its gensym name cannot collide.
          if hasRet:
            emitSlotProcAndCall(result, info, name, params, blockSlot,
                                slotSym)
          else:
            result.withTree BlockS, info:
              result.addEmptyNode info      # unnamed block
              result.withTree StmtsS, info:
                emitSlotProcAndCall(result, info, name, params, blockSlot,
                                    slotSym)

  # WIDGET_DSL_DEBUG=1 dumps to /tmp/opencode, =<dir> into that directory
  let debugDir = getEnv("WIDGET_DSL_DEBUG")
  if debugDir != "":
    let dir = if debugDir == "1": "/tmp/opencode" else: debugDir
    try:
      writeFile(dir & "/mwidget-" & name & ".nif", renderTree(result))
    except ErrorCode:
      discard

var inp = loadPluginInput()
saveTree transform(inp)
