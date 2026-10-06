## Shared code generation for widget events (`ellipse_ui/events`), used by
## the `widget` plugin (`mwidget`) and the `handleEvents` / `defineEvent`
## plugin (`mevents`).
##
## Input shapes (verified against nifler output):
##
##   emits Toggled(on: bool)   (cmd emits (oconstr Toggled (kv on bool)))
##   emits Saved()             (cmd emits (call Saved))     declares, no fields
##   emits Saved               (cmd emits Saved)            references
##   event Toggled(e): ...     (cmd event (call Toggled e) (stmts ...))
##   event Saved: ...          (cmd event Saved (stmts ...))
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
##     elif ...
##   pushEventFrame("Name", uint32(<hash>), <id>, evHandler, @[ToggledKind, ...])
##   defer: popEventFrame()
##   <remaining statements>
##   discard                   # see `emitStmts`
##
## The payload reaches the handler as a `var` parameter: Nimony does not
## auto-dereference `ptr` on field access, and `e.field = x` must write
## through to the payload a `reemit` passes on. A `return` in a handler
## ends just that handler. `defer` closes the frame however the body exits.
##
## Generated names (`evHandler`, `evOn<Name>`, `evKindArg`, `evPayloadArg`)
## are plain identifiers no widget would pick, so a widget's own `kind` or
## `payload` stays visible inside its handler bodies. (Gensym'd parameters
## and locals trip Nimony's redeclaration check: they share one base name.)
##
## Build note: nifmake rebuilds a plugin executable when the plugin's own
## source changes, not when a module it imports does. After editing this
## file, touch `mwidget.nim` and `mevents.nim` (or clear `nimcache/`) or the
## old generator keeps running.

import plugins

type
  EventField* = object
    name*: NifCursor
    typ*: NifCursor

  EventDecl* = object
    name*: string
    declares*: bool            ## `emits Name(...)` / `Name()`: generate it
    fields*: seq[EventField]
    at*: NifCursor

  EventHandlerDecl* = object
    name*: string
    binding*: string           ## the payload name, "" for `event Name:`
    body*: NifCursor           ## the (stmts ...) of the handler
    at*: NifCursor

  EventSections* = object
    decls*: seq[EventDecl]
    handlers*: seq[EventHandlerDecl]
    rest*: seq[NifCursor]      ## every other top-level statement, in order
    error*: string             ## non-empty: report at `errorAt`
    errorAt*: NifCursor

proc nameOf(n: NifCursor): string =
  case n.kind
  of Ident: result = n.identText
  of Symbol, SymbolDef: result = n.symText
  else: result = ""

proc isTag(n: NifCursor; tag: string): bool =
  n.kind == TagLit and n.tagText == tag

proc isCommandOf(n: NifCursor; name: string): bool =
  ## `(cmd name ...)` or `(call name ...)`.
  if n.isTag("cmd") or n.isTag("call"):
    result = firstChild(n).eqIdent(name)
  else:
    result = false

proc fnv1a*(s: string): uint32 =
  result = 2166136261'u32
  for ch in s:
    result = (result xor uint32(ord(ch))) * 16777619'u32

proc moduleName*(info: LineInfo): string =
  ## The base name of the source file at `info`, "" when unknown.
  let path = info.filePath
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

proc fail(s: var EventSections; msg: string; at: NifCursor) =
  if s.error.len == 0:
    s.error = msg
    s.errorAt = at

proc parseEventHead*(s: var EventSections; owner: string; head: NifCursor;
                     n: NifCursor) =
  ## Parse `Name`, `Name()` or `Name(field: T, ...)` at `head` (and nothing
  ## after it) into a declaration; `n` is the whole statement.
  var c = head
  if not c.hasMore:
    s.fail(owner & ": expected `Name` or `Name(field: T, ...)`", n)
    return
  var d = EventDecl(name: "", declares: false, fields: @[], at: n)
  if c.kind == Ident or c.kind == Symbol:
    d.name = c.nameOf                       # bare: declared elsewhere
  elif c.isTag("oconstr") or c.isTag("call"):
    var f = firstChild(c)
    d.name = f.nameOf
    d.declares = true
    skip f
    while f.hasMore:
      if not f.isTag("kv"):
        s.fail(owner & ": event `" & d.name & "` fields need types: " &
          "`emits " & d.name & "(field: T)`", f)
        return
      var kv = firstChild(f)
      let fname = kv
      skip kv
      if fname.nameOf.len == 0 or not kv.hasMore:
        s.fail(owner & ": malformed field in event `" & d.name & "`", f)
        return
      d.fields.add EventField(name: fname, typ: kv)
      skip f
  if d.name.len == 0:
    s.fail(owner & ": expected `Name` or `Name(field: T, ...)`", n)
    return
  skip c
  if c.hasMore:
    s.fail(owner & ": one event per line", n)
    return
  for e in s.decls:
    if e.name == d.name:
      s.fail(owner & ": `emits " & d.name & "` appears twice", n)
      return
  s.decls.add d

proc parseEmits(s: var EventSections; owner: string; n: NifCursor) =
  var c = firstChild(n)
  skip c                                    # `emits`
  parseEventHead(s, owner, c, n)

proc parseHandler(s: var EventSections; owner: string; n: NifCursor) =
  var c = firstChild(n)
  skip c                                    # `event`
  var h = EventHandlerDecl(name: "", binding: "", at: n)
  if c.hasMore and (c.kind == Ident or c.kind == Symbol):
    h.name = c.nameOf
  elif c.hasMore and c.isTag("call"):
    var a = firstChild(c)
    h.name = a.nameOf
    skip a
    if not a.hasMore or a.kind != Ident:
      s.fail(owner & ": expected `event " & h.name & "(e):` -- one payload name", n)
      return
    h.binding = a.identText
    skip a
    if a.hasMore:
      s.fail(owner & ": expected `event " & h.name & "(e):` -- one payload name", n)
      return
  if h.name.len == 0:
    s.fail(owner & ": expected `event Name(e):` or `event Name:`", n)
    return
  skip c
  if not c.hasMore or not c.isTag("stmts"):
    s.fail(owner & ": `event " & h.name & "` needs a handler body", n)
    return
  h.body = c
  for e in s.handlers:
    if e.name == h.name:
      s.fail(owner & ": two `event " & h.name & "` handlers", n)
      return
  s.handlers.add h

proc collectEventSections*(body: NifCursor; owner: string;
                           allowEmits: bool): EventSections =
  ## Split a (stmts ...) body into its `emits` declarations, its `event`
  ## handlers and everything else.
  result = EventSections(decls: @[], handlers: @[], rest: @[], error: "")
  var c = firstChild(body)
  while c.hasMore:
    if c.isCommandOf("emits"):
      if allowEmits:
        result.parseEmits(owner, c)
      else:
        result.fail(owner & ": `emits` belongs in a widget definition", c)
    elif c.isCommandOf("event") and c.isTag("cmd"):
      result.parseHandler(owner, c)
    else:
      result.rest.add c
    skip c

proc findStrayEvent(n: NifCursor; found: var NifCursor): bool =
  ## An `event` section anywhere below the top level of a body.
  if n.kind != TagLit:
    return false
  if n.isTag("cmd") and firstChild(n).eqIdent("event"):
    var c = firstChild(n)
    skip c
    if c.hasMore:
      skip c
      if c.hasMore and c.isTag("stmts"):
        found = n
        return true
  var c = firstChild(n)
  while c.hasMore:
    if findStrayEvent(c, found):
      return true
    skip c
  return false

proc emittedName(n: NifCursor): string =
  ## `emit Name(...)` / `emit(Name(...))`: the constructed event's name.
  result = ""
  if n.isCommandOf("emit"):
    var c = firstChild(n)
    skip c
    if c.hasMore and (c.isTag("oconstr") or c.isTag("call")):
      result = firstChild(c).nameOf

proc findUndeclaredEmit(n: NifCursor; decls: seq[EventDecl];
                        found: var NifCursor; name: var string): bool =
  if n.kind != TagLit:
    return false
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
  var c = firstChild(n)
  while c.hasMore:
    if findUndeclaredEmit(c, decls, found, name):
      return true
    skip c
  return false

proc checkSections*(s: var EventSections; owner: string; checkEmits: bool) =
  ## Reject `event` sections below the top level and -- for widgets --
  ## emits of events the widget did not declare.
  var found = default(NifCursor)
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

proc addU32(dest: var NifBuilder; info: LineInfo; v: uint32) =
  ## `uint32(<v>)`
  dest.openTree("call", info)
  dest.addIdent "uint32"
  dest.addIntLit int64(v)
  dest.closeTree()

proc kindIdent*(name: string): string = name & "Kind"

const
  handlerName = "evHandler"
  kindParam = "evKindArg"
  payloadParam = "evPayloadArg"

proc emitEventType*(dest: var NifBuilder; d: EventDecl; module: string) =
  ## The type, kind constant, registration and `emit` overload of `d`.
  let info = d.at.info
  let qualified = if module.len > 0: module & "." & d.name else: d.name
  # type Name* = object (fld f x . T .)...
  dest.openTree("type", info)
  dest.addIdent d.name
  dest.addIdent "x"
  dest.addEmptyNode2 info
  dest.openTree("object", info)
  dest.addEmptyNode info
  for f in d.fields:
    dest.openTree("fld", info)
    var fn = f.name
    dest.takeTree fn
    dest.addIdent "x"
    dest.addEmptyNode info
    var ft = f.typ
    dest.takeTree ft
    dest.addEmptyNode info
    dest.closeTree()
  dest.closeTree()
  dest.closeTree()
  # const NameKind* = EventKind(uint32(hash))
  dest.openTree("const", info)
  dest.addIdent kindIdent(d.name)
  dest.addIdent "x"
  dest.addEmptyNode2 info
  dest.openTree("call", info)
  dest.addIdent "EventKind"
  dest.addU32(info, fnv1a(qualified))
  dest.closeTree()
  dest.closeTree()
  # registerEventKind(NameKind, "module.Name")
  dest.openTree("call", info)
  dest.addIdent "registerEventKind"
  dest.addIdent kindIdent(d.name)
  dest.addStrLit qualified
  dest.closeTree()
  # proc emit*(e: Name): bool {.discardable.} = ...
  dest.openTree("proc", info)
  dest.addIdent "emit"
  dest.addIdent "x"
  dest.addEmptyNode2 info
  dest.openTree("params", info)
  dest.openTree("param", info)
  dest.addIdent "ev"
  dest.addEmptyNode2 info
  dest.addIdent d.name
  dest.addEmptyNode info
  dest.closeTree()
  dest.closeTree()
  dest.addIdent "bool"
  dest.openTree("pragmas", info)
  dest.addIdent "discardable"
  dest.closeTree()
  dest.addEmptyNode info
  dest.openTree("stmts", info)
  dest.openTree("var", info)
  dest.addIdent "evPayload"
  dest.addEmptyNode3 info
  dest.addIdent "ev"
  dest.closeTree()
  dest.openTree("asgn", info)
  dest.addIdent "result"
  dest.openTree("call", info)
  dest.addIdent "dispatchEvent"
  dest.addIdent kindIdent(d.name)
  dest.addStrLit d.name
  dest.openTree("cmd", info)
  dest.addIdent "addr"
  dest.addIdent "evPayload"
  dest.closeTree()
  dest.closeTree()
  dest.closeTree()
  dest.closeTree()
  dest.closeTree()

proc copyBody(dest: var NifBuilder; n: NifCursor) =
  ## Copy statements, turning a bare `reemit` statement into the call
  ## `reemit()`.
  if n.kind != TagLit:
    var q = n
    dest.takeTree q
    return
  let inStmts = n.tagText == "stmts"
  dest.openTree(n.tagText, n.info)
  var c = firstChild(n)
  while c.hasMore:
    if inStmts and c.kind == Ident and c.identText == "reemit":
      dest.openTree("call", c.info)
      dest.addIdent "reemit"
      dest.closeTree()
    else:
      copyBody(dest, c)
    skip c
  dest.closeTree()

proc emitStmts(dest: var NifBuilder; info: LineInfo; stmts: seq[NifCursor]) =
  ## The statements plus a closing `discard`: Nimony types the block a
  ## `defer` guards by its last statement, so a trailing discardable call
  ## -- `emit ...` -- would otherwise be a value that must be used.
  for s in stmts:
    copyBody(dest, s)
  dest.openTree("discard", info)
  dest.addEmptyNode info
  dest.closeTree()

proc emitEventFrame*(dest: var NifBuilder; info: LineInfo;
                     s: EventSections; frameName: string;
                     idIdent: string) =
  ## The handler closure (when there are handlers), `pushEventFrame`, a
  ## `defer: popEventFrame()`, then the remaining statements. `idIdent`
  ## names an `ElementId` in scope keying the frame, "" for none.
  if s.handlers.len > 0:
    dest.openTree("proc", info)
    dest.addIdent handlerName
    dest.addEmptyNode3 info                 # export, pattern, typevars
    dest.openTree("params", info)
    dest.openTree("param", info)
    dest.addIdent kindParam
    dest.addEmptyNode2 info
    dest.addIdent "EventKind"
    dest.addEmptyNode info
    dest.closeTree()
    dest.openTree("param", info)
    dest.addIdent payloadParam
    dest.addEmptyNode2 info
    dest.addIdent "pointer"
    dest.addEmptyNode info
    dest.closeTree()
    dest.closeTree()
    dest.addIdent "EventFlow"
    dest.openTree("pragmas", info)
    dest.addIdent "closure"
    dest.closeTree()
    dest.addEmptyNode info                  # effects
    dest.openTree("stmts", info)
    dest.openTree("asgn", info)
    dest.addIdent "result"
    dest.addIdent "efPass"
    dest.closeTree()
    dest.openTree("if", info)
    for h in s.handlers:
      let hinfo = h.at.info
      let onName = "evOn" & h.name
      dest.openTree("elif", hinfo)
      dest.openTree("infix", hinfo)
      dest.addIdent "=="
      dest.addIdent kindParam
      dest.addIdent kindIdent(h.name)
      dest.closeTree()
      dest.openTree("stmts", hinfo)
      dest.openTree("asgn", hinfo)
      dest.addIdent "result"
      dest.addIdent "efConsumed"
      dest.closeTree()
      # proc evOnName(e: var Name) {.closure.} = <body>
      dest.openTree("proc", hinfo)
      dest.addIdent onName
      dest.addEmptyNode3 hinfo
      dest.openTree("params", hinfo)
      dest.openTree("param", hinfo)
      dest.addIdent(if h.binding.len > 0: h.binding else: "evUnusedArg")
      dest.addEmptyNode2 hinfo
      dest.openTree("mut", hinfo)
      dest.addIdent h.name
      dest.closeTree()
      dest.addEmptyNode hinfo
      dest.closeTree()
      dest.closeTree()
      dest.addEmptyNode hinfo                # returns nothing
      dest.openTree("pragmas", hinfo)
      dest.addIdent "closure"
      dest.closeTree()
      dest.addEmptyNode hinfo
      copyBody(dest, h.body)
      dest.closeTree()
      # evOnName(cast[ptr Name](payload)[])
      dest.openTree("call", hinfo)
      dest.addIdent onName
      dest.openTree("at", hinfo)
      dest.openTree("cast", hinfo)
      dest.openTree("ptr", hinfo)
      dest.addIdent h.name
      dest.closeTree()
      dest.addIdent payloadParam
      dest.closeTree()
      dest.closeTree()
      dest.closeTree()
      dest.closeTree()                       # stmts
      dest.closeTree()                       # elif
    dest.closeTree()                         # if
    dest.closeTree()                         # stmts
    dest.closeTree()                         # proc

  # pushEventFrame("Name", uint32(hash), id, handler, @[kinds])
  dest.openTree("call", info)
  dest.addIdent "pushEventFrame"
  dest.addStrLit frameName
  dest.addU32(info, fnv1a(frameName))
  if idIdent.len > 0:
    dest.openTree("dot", info)
    dest.addIdent idIdent
    dest.addIdent "id"
    dest.closeTree()
  else:
    dest.addU32(info, 0'u32)
  if s.handlers.len > 0:
    dest.addIdent handlerName
    dest.openTree("prefix", info)
    dest.addIdent "@"
    dest.openTree("bracket", info)
    for h in s.handlers:
      dest.addIdent kindIdent(h.name)
    dest.closeTree()
    dest.closeTree()
  dest.closeTree()

  # defer: popEventFrame()
  dest.openTree("defer", info)
  dest.openTree("stmts", info)
  dest.openTree("call", info)
  dest.addIdent "popEventFrame"
  dest.closeTree()
  dest.closeTree()
  dest.closeTree()
  emitStmts(dest, info, s.rest)
