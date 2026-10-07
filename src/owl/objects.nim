import std/[tables, hashes, options, strutils]

type
  Environment* = object
    up: nil ref Environment
    bindings: Table[Object, Object]
    # Set on a hygienic command's frame: the scope it was called from.
    caller: nil ref Environment
    # Set on a `do` scope inside a command: while it runs, syntax written in
    # redirectFrom evaluates in redirectTo, a fresh child of the caller's scope.
    redirectFrom: nil ref Environment
    redirectTo: nil ref Environment
    # The export tables of the modules this scope uses. They are views, not
    # copies: a name is looked up in its module on every access, so a patched
    # definition reaches every importer.
    imports: seq[ref Exports]

  # What a module shows to its users: public name -> the name of a binding in
  # the module's own env (usually the same name; `export: shown = secret`
  # renames).
  Exports* = object
    env: ref Environment
    names: Table[Object, Object]
    # `export all`: every binding of the module's own scope is public too,
    # including ones made after the use (a repl document grows).
    all: bool

  ObjectKind = enum
    Nothing
    Number
    String
    Symbol
    Boolean
    List
    Pair
    Record
    Command
    Syntax
    Scope

  Object* = object
    case kind: ObjectKind
    of Nothing:
      discard
    of Number:
      number: float64
    of String:
      str: string
    of Symbol:
      symbol: string
    of Boolean:
      isTrue: bool
    of List:
      items: ref ItemsBox
      bodyStart: int
    of Pair:
      a, b: nil ref Object
    of Record:
      fields: seq[Object]
    of Command:
      name: string
      params: seq[Object]
      body: seq[Object]
      env: nil ref Environment
      isFun: bool
      dynamic: bool
      call: CommandProc
    of Syntax:
      # An unevaluated argument of a command together with the scope it was
      # written in, so evaluating it never sees the command's own names.
      form: nil ref Object
      scope: nil ref Environment
    of Scope:
      # A scope as a value, from new-scope, for eval-in.
      scopeRef: nil ref Environment

  # A list's items live behind a shared ref: lists are never changed in place
  # (append and friends build a new list), so copying a list value, which
  # every variable read does, costs a reference count instead of the items.
  ItemsBox = object
    xs: seq[Object]

  CommandProc* = nil proc (env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.}

func nothing*(): Object =
  Object(kind: Nothing)

func number*(n: float64): Object =
  Object(kind: Number, number: n)

func str*(s: string): Object =
  Object(kind: String, str: s)

func symbol*(name: string): Object =
  Object(kind: Symbol, symbol: name)

func boolean*(b: bool): Object =
  Object(kind: Boolean, isTrue: b)

func list*(items: seq[Object], bodyStart: int = -1): Object =
  Object(kind: List, items: (ref ItemsBox)(xs: items), bodyStart: bodyStart)

func box(o: Object): ref Object =
  result = (ref Object)(kind: Nothing)
  result[] = o

func pair*(key, val: Object): Object =
  Object(kind: Pair, a: box(key), b: box(val))

func record*(fields: seq[Object]): Object =
  Object(kind: Record, fields: fields)

func newCommand*(name: string, params, body: seq[Object], env: nil ref Environment,
    isFun: bool, dynamic: bool = false): Object =
  Object(kind: Command, name: name, params: params, body: body, env: env, isFun: isFun,
    dynamic: dynamic, call: nil)

func syntax*(form: Object, scope: ref Environment): Object =
  Object(kind: Syntax, form: box(form), scope: scope)

func scopeValue*(env: ref Environment): Object =
  Object(kind: Scope, scopeRef: env)

func newBuiltin*(name: string, call: CommandProc, isFun: bool): Object =
  Object(kind: Command, name: name, isFun: isFun, call: call)

func isNothing*(o: Object): bool = o.kind == Nothing
func isNumber*(o: Object): bool = o.kind == Number
func isString*(o: Object): bool = o.kind == String
func isSymbol*(o: Object): bool = o.kind == Symbol
func isBoolean*(o: Object): bool = o.kind == Boolean
func isList*(o: Object): bool = o.kind == List
func isPair*(o: Object): bool = o.kind == Pair
func isRecord*(o: Object): bool = o.kind == Record
func isCommand*(o: Object): bool = o.kind == Command
func isSyntax*(o: Object): bool = o.kind == Syntax

func kindName*(o: Object): string =
  case o.kind
  of Nothing: "nothing"
  of Number: "number"
  of String: "string"
  of Symbol: "symbol"
  of Boolean: "boolean"
  of List: "list"
  of Pair: "pair"
  of Record: "record"
  of Command: "command"
  of Syntax: "syntax"
  of Scope: "scope"

func scopeEnv*(o: Object): nil ref Environment =
  result = nil
  if o.kind == Scope:
    result = o.scopeRef

func syntaxForm*(o: Object): Object =
  result = nothing()
  if o.kind == Syntax:
    let f = o.form
    if f != nil:
      result = f[]

func syntaxScope*(o: Object): nil ref Environment =
  result = nil
  if o.kind == Syntax:
    result = o.scope

func isDynamic*(o: Object): bool =
  result = false
  if o.kind == Command:
    result = o.dynamic

func bodyStart*(o: Object): int =
  result = -1
  if o.kind == List:
    result = o.bodyStart

func setBodyStart*(o: var Object, at: int) =
  if o.kind == List:
    o.bodyStart = at

func cmdName*(o: Object): string =
  result = ""
  if o.kind == Command:
    result = o.name

func cmdParams*(o: Object): seq[Object] =
  result = @[]
  if o.kind == Command:
    result = o.params

func cmdBody*(o: Object): seq[Object] =
  result = @[]
  if o.kind == Command:
    result = o.body

func cmdEnv*(o: Object): nil ref Environment =
  result = nil
  if o.kind == Command:
    result = o.env

func isFun*(o: Object): bool =
  result = false
  if o.kind == Command:
    result = o.isFun

func isBuiltin*(o: Object): bool =
  result = false
  if o.kind == Command:
    result = o.call != nil

func builtinCall*(o: Object): CommandProc =
  result = nil
  if o.kind == Command:
    result = o.call

func toNumber*(o: Object): float64 =
  result = 0.0
  case o.kind
  of Number:
    result = o.number
  of Boolean:
    if o.isTrue:
      result = 1.0
  else:
    discard

func toBool*(o: Object): bool =
  result = true
  case o.kind
  of Nothing:
    result = false
  of Boolean:
    result = o.isTrue
  else:
    discard

func toSymbol*(o: Object): string =
  result = ""
  case o.kind
  of Symbol:
    result = o.symbol
  else:
    discard

func toStr*(o: Object): string =
  result = ""
  case o.kind
  of String:
    result = o.str
  else:
    discard

func toSeq*(o: Object): seq[Object] =
  result = @[]
  case o.kind
  of List:
    result = o.items.xs
  else:
    discard

# itemCount and itemAt read a list without copying its items, unlike toSeq.
func itemCount*(o: Object): int =
  result = 0
  if o.kind == List:
    result = o.items.xs.len

func itemAt*(o: Object, i: int): Object =
  result = nothing()
  if o.kind == List and i >= 0 and i < o.items.xs.len:
    result = o.items.xs[i]

func car*(o: Object): Object =
  result = nothing()
  case o.kind
  of Pair:
    let key = o.a
    if key != nil:
      result = key[]
  else:
    discard

func cdr*(o: Object): Object =
  result = nothing()
  case o.kind
  of Pair:
    let value = o.b
    if value != nil:
      result = value[]
  else:
    discard

func recordFields*(o: Object): seq[Object] =
  result = @[]
  if o.kind == Record:
    result = o.fields

func fieldNames*(o: Object): seq[string] =
  result = @[]
  if o.kind == Record:
    for f in o.fields:
      result.add toSymbol(car(f))

func hasField*(o: Object, name: string): bool =
  result = false
  if o.kind == Record:
    for f in o.fields:
      if toSymbol(car(f)) == name:
        return true

func field*(o: Object, name: string): Object =
  result = nothing()
  if o.kind == Record:
    for f in o.fields:
      if toSymbol(car(f)) == name:
        return cdr(f)

func `==`*(a, b: Object): bool =
  if a.kind != b.kind:
    return false
  case a.kind:
  of Nothing:
    result = true
  of Command:
    result = a.name == b.name and a.isFun == b.isFun and a.dynamic == b.dynamic and
      a.env == b.env and (a.call == b.call or (a.call != nil and b.call != nil))
  of Syntax:
    result = a.scope == b.scope and syntaxForm(a) == syntaxForm(b)
  of Scope:
    result = a.scopeRef == b.scopeRef
  of Number:
    result = a.number == b.number
  of String:
    result = a.str == b.str
  of Symbol:
    result = a.symbol == b.symbol
  of Boolean:
    result = a.isTrue == b.isTrue
  of List:
    if a.items.xs.len != b.items.xs.len:
      return false
    for i in 0 ..< a.items.xs.len:
      if a.items.xs[i] != b.items.xs[i]:
        return false
    result = true
  of Pair:
    let aHead = a.a
    let bHead = b.a
    let aTail = a.b
    let bTail = b.b
    if (aHead == nil) != (bHead == nil) or (aTail == nil) != (bTail == nil):
      return false
    if aHead != nil and bHead != nil:
      if not (aHead[] == bHead[]):
        return false
    if aTail != nil and bTail != nil:
      if not (aTail[] == bTail[]):
        return false
    result = true
  of Record:
    if a.fields.len != b.fields.len:
      return false
    for i in 0 ..< a.fields.len:
      if a.fields[i] != b.fields[i]:
        return false
    result = true

func hash*(o: Object): Hash =
  result = hash(o.kind)
  case o.kind:
  of Nothing:
    discard
  of Number:
    result = result !& hash(o.number)
  of String:
    result = result !& hash(o.str)
  of Symbol:
    result = result !& hash(o.symbol)
  of Boolean:
    result = result !& hash(o.isTrue)
  of List:
    result = result !& hash(o.items.xs)
  of Pair:
    let head = o.a
    let tail = o.b
    if head != nil:
      result = result !& hash(head[])
    if tail != nil:
      result = result !& hash(tail[])
  of Record:
    result = result !& hash(o.fields)
  of Command:
    result = result !& hash(o.name)
    result = result !& hash(o.isFun)
  of Syntax:
    result = result !& hash(syntaxForm(o))
  of Scope:
    discard
  result = !$result

func `$`*(o: Object): string =
  result = "(kind: " & $o.kind
  case o.kind
  of Nothing:
    discard
  of Command:
    result.add ", name: " & o.name
  of Syntax:
    result.add ", form: " & $syntaxForm(o)
  of Scope:
    discard
  of Number:
    result.add ", number: " & $o.number
  of String:
    result.add ", str: " & o.str.escape
  of Symbol:
    result.add ", symbol: " & o.symbol.escape
  of Boolean:
    result.add ", isTrue: " & $o.isTrue
  of List:
    result.add ", items: @["
    for i in 0 ..< o.items.xs.len:
      if i > 0:
        result.add ", "
      result.add $o.items.xs[i]
    result.add "]"
  of Pair:
    let head = o.a
    let tail = o.b
    result.add ", a: "
    if head != nil:
      result.add $head[]
    else:
      result.add "nil"
    result.add ", b: "
    if tail != nil:
      result.add $tail[]
    else:
      result.add "nil"
  of Record:
    result.add ", fields: @["
    for i in 0 ..< o.fields.len:
      if i > 0:
        result.add ", "
      result.add $o.fields[i]
    result.add "]"
  result.add ")"

func stringifyNumber(n: float64): string =
  if n > -9.0e15 and n < 9.0e15 and n == float64(int64(n)):
    result = $int64(n)
  else:
    result = $n

func stringify*(o: Object): string

func stringifyArg(o: Object): string =
  if o.kind == List or o.kind == Record:
    result = "(" & stringify(o) & ")"
  else:
    result = stringify(o)

func stringify*(o: Object): string =
  case o.kind
  of Nothing:
    result = "()"
  of Number:
    result = stringifyNumber(o.number)
  of String:
    result = o.str
  of Symbol:
    result = o.symbol
  of Boolean:
    result = if o.isTrue: "true" else: "false"
  of List:
    if o.items.xs.len > 0 and isSymbol(o.items.xs[0]):
      result = stringifyArg(o.items.xs[0])
      for i in 1 ..< o.items.xs.len:
        result.add " "
        result.add stringifyArg(o.items.xs[i])
    else:
      result = "[]"
      for i in 0 ..< o.items.xs.len:
        result.add " "
        result.add stringifyArg(o.items.xs[i])
  of Pair:
    let head = o.a
    let tail = o.b
    result = "("
    if head != nil:
      result.add stringify(head[])
    else:
      result.add "()"
    result.add " = "
    if tail != nil:
      result.add stringify(tail[])
    else:
      result.add "()"
    result.add ")"
  of Record:
    result = "{}"
    for i in 0 ..< o.fields.len:
      result.add " "
      result.add stringifyArg(o.fields[i])
  of Command:
    let kw = if o.isFun: "fun" elif o.dynamic: "dynamic-command" else: "command"
    result = "<" & kw & " " & o.name & ">"
  of Syntax:
    result = stringify(syntaxForm(o))
  of Scope:
    result = "<scope>"

# --- printing values as owl code -------------------------------------------
#
# toCode renders a value as owl source that reads back as that value, laid
# out like hand-written owl: on one line when it fits the width, otherwise
# broken into blocks (`[]:`, `{}:`, `name = value` lines, a command's
# `:` body). stringify stays the plain text that echo and concat use.
#
# Owl cannot continue a parenthesized line, so only a value standing at the
# start of a line, or after `name =`, can break; arguments stay inline.
# A list headed by a symbol is code, as in stringify, and keeps its `:` body.
# Strings are quoted; quotes and control characters, which owl string
# literals cannot hold, become (concat "a" (char 34) "b").

func quoteString(s: string): string =
  var parts: seq[string] = @[]
  var cur = ""
  var hasRun = false
  for c in s:
    if c == '"' or (c < ' ' and c != '\t'):
      if hasRun:
        parts.add "\"" & cur & "\""
        cur = ""
        hasRun = false
      parts.add "(char " & $ord(c) & ")"
    else:
      cur.add c
      hasRun = true
  if hasRun or parts.len == 0:
    parts.add "\"" & cur & "\""
  if parts.len == 1:
    result = parts[0]
  else:
    result = "(concat"
    for p in parts:
      result.add " "
      result.add p
    result.add ")"

func isCodeList(o: Object): bool =
  o.kind == List and o.items.xs.len > 0 and o.items.xs[0].kind == Symbol

func bodyAt(o: Object): int =
  # where a code list's `:` body starts, or -1
  result = -1
  if isCodeList(o) and o.bodyStart >= 1 and o.bodyStart < o.items.xs.len:
    result = o.bodyStart

func inlineCode(o: Object, asArg: bool): string =
  case o.kind
  of Nothing:
    result = "nothing"
  of Number:
    result = stringifyNumber(o.number)
  of String:
    result = quoteString(o.str)
  of Symbol:
    result = o.symbol
  of Boolean:
    result = if o.isTrue: "true" else: "false"
  of List:
    if o.items.xs.len == 0:
      result = "([])"
    elif isCodeList(o):
      if o.items.xs.len == 1:
        return "(" & o.items.xs[0].symbol & ")"
      result = o.items.xs[0].symbol
      for i in 1 ..< o.items.xs.len:
        result.add " "
        result.add inlineCode(o.items.xs[i], true)
      if asArg:
        result = "(" & result & ")"
    else:
      result = "[]"
      for i in 0 ..< o.items.xs.len:
        result.add " "
        result.add inlineCode(o.items.xs[i], true)
      if asArg:
        result = "(" & result & ")"
  of Pair:
    result = "(" & inlineCode(car(o), false) & " = " & inlineCode(cdr(o), false) & ")"
  of Record:
    if o.fields.len == 0:
      return "({})"
    result = "{}"
    for f in o.fields:
      result.add " "
      result.add inlineCode(f, true)
    if asArg:
      result = "(" & result & ")"
  of Command:
    result = stringify(o)
  of Syntax:
    result = inlineCode(syntaxForm(o), asArg)
  of Scope:
    result = "<scope>"

func needsBlock(o: Object): bool =
  # a `:` body cannot be written on one line
  result = false
  if bodyAt(o) >= 0:
    return true
  case o.kind
  of List:
    for x in o.items.xs:
      if needsBlock(x):
        return true
  of Record:
    for f in o.fields:
      if needsBlock(cdr(f)):
        return true
  of Pair:
    result = needsBlock(cdr(o))
  else:
    discard

func indentText(n: int): string =
  result = ""
  for i in 0 ..< n:
    result.add ' '

func textWidth(s: string): int =
  # characters, not bytes: UTF-8 continuation bytes add nothing
  result = 0
  for c in s:
    if ord(c) < 0x80 or ord(c) >= 0xC0:
      inc result

func lineCode(o: Object, indent, col, width: int): string

func blockItems(items: seq[Object], indent, width: int): string =
  result = ""
  for x in items:
    result.add "\n"
    result.add indentText(indent)
    result.add lineCode(x, indent, indent, width)

# o as it reads at the start of a line indented by indent, its first line
# beginning at column col; blocks under it are indented 4 deeper.
func isAtom(o: Object): bool =
  o.kind in {Nothing, Number, String, Symbol, Boolean}

func filledRows(items: seq[Object], indent, width: int): string =
  # a long list of atoms as `concat:` over rows of `[] ...` that fill the
  # width, instead of one item per line
  result = "concat:"
  var row = ""
  for x in items:
    let piece = inlineCode(x, true)
    if row.len > 0 and indent + textWidth(row) + 1 + textWidth(piece) > width:
      result.add "\n" & indentText(indent) & row
      row = ""
    if row.len == 0:
      row = "[] " & piece
    else:
      row.add " " & piece
  if row.len > 0:
    result.add "\n" & indentText(indent) & row

func lineCode(o: Object, indent, col, width: int): string =
  if o.kind == Pair:
    # at the start of a line a pair is a binding: no parentheses
    let key = inlineCode(car(o), false) & " = "
    return key & lineCode(cdr(o), indent, col + textWidth(key), width)
  let flat = inlineCode(o, false)
  if not needsBlock(o) and col + textWidth(flat) <= width:
    return flat
  let inner = indent + 4
  case o.kind
  of List:
    let b = bodyAt(o)
    if b >= 0:
      result = o.items.xs[0].symbol
      for i in 1 ..< b:
        result.add " "
        result.add inlineCode(o.items.xs[i], true)
      result.add ":"
      result.add blockItems(o.items.xs[b ..< o.items.xs.len], inner, width)
    elif isCodeList(o) or o.items.xs.len == 0:
      result = flat
    else:
      var atoms = true
      for x in o.items.xs:
        if not isAtom(x):
          atoms = false
      if atoms:
        result = filledRows(o.items.xs, inner, width)
      else:
        result = "[]:" & blockItems(o.items.xs, inner, width)
  of Record:
    if o.fields.len == 0:
      return flat
    result = "{}:"
    for f in o.fields:
      result.add "\n"
      result.add indentText(inner)
      result.add lineCode(f, inner, inner, width)
  of Syntax:
    result = lineCode(syntaxForm(o), indent, col, width)
  else:
    result = flat

func definitionCode(o: Object, width: int): string =
  # a command made in owl, written out as its definition
  let kw = if o.name.len == 0: "lambda" elif o.isFun: "fun"
    elif o.dynamic: "dynamic-command" else: "command"
  result = kw
  if o.name.len > 0:
    result.add " "
    result.add o.name
  for p in o.params:
    result.add " "
    result.add inlineCode(p, true)
  result.add ":"
  result.add blockItems(o.body, 4, width)

# toCode o width: o as owl code, at most width columns where owl allows a
# break. A command defined in owl is written out as its definition.
func toCode*(o: Object, width: int = 80): string =
  if o.kind == Command and o.call == nil and o.body.len > 0:
    result = definitionCode(o, width)
  else:
    result = lineCode(o, 0, 0, width)

proc newEnvironment*(up: nil ref Environment = nil): ref Environment =
  (ref Environment)(up: up, bindings: initTable[Object, Object](), caller: nil,
    redirectFrom: nil, redirectTo: nil, imports: @[])

proc newExports*(env: ref Environment): ref Exports =
  (ref Exports)(env: env, names: initTable[Object, Object](), all: false)

proc setExportAll*(x: ref Exports, on: bool) =
  x.all = on

proc exportsAll*(x: ref Exports): bool = x.all

proc exportName*(x: ref Exports, public, internal: Object) =
  x.names[public] = internal

proc exportedNames*(x: ref Exports): seq[Object] =
  result = @[]
  for name in x.names.keys:
    result.add name
  if x.all:
    for name in x.env.bindings.keys:
      if not x.names.hasKey(name):
        result.add name

proc exportsEnv*(x: ref Exports): ref Environment =
  x.env

proc addImport*(env: ref Environment, x: ref Exports) =
  for i in 0 ..< env.imports.len:
    if env.imports[i] == x:
      return
  env.imports.add x

proc clearImports*(env: ref Environment) =
  env.imports = @[]

proc clearExportNames*(x: ref Exports) =
  x.names = initTable[Object, Object]()

proc setCaller*(frame: ref Environment, caller: ref Environment) =
  frame.caller = caller

proc setRedirect*(env: ref Environment, source, target: ref Environment) =
  env.redirectFrom = source
  env.redirectTo = target

# The scope the nearest enclosing hygienic command was called from, or nil
# outside of any command.
proc commandCaller*(env: ref Environment): nil ref Environment =
  result = nil
  var cur: nil ref Environment = env
  while cur != nil:
    let c = cur.caller
    if c != nil:
      return c
    cur = cur.up

# Where syntax written in scope should evaluate when seen from env: the
# nearest `do` redirect for that scope, or the scope itself.
proc resolveScope*(env: ref Environment, scope: ref Environment): ref Environment =
  result = scope
  var cur: nil ref Environment = env
  while cur != nil:
    let target = cur.redirectTo
    if cur.redirectFrom == scope and target != nil:
      return target
    cur = cur.up

proc define*(env: ref Environment, name, value: Object) =
  env.bindings[name] = value

proc undefine*(env: ref Environment, name: Object) =
  env.bindings.del(name)

func allBindings*(env: ref Environment): Table[Object, Object] =
  result = env.bindings

# Re-exports chain through modules; a cycle of exports that never reaches a
# binding stops here instead of recursing forever.
const MaxImportDepth = 32

proc findCell(env: nil ref Environment, name: Object, depth: int,
    key: var Object): nil ref Environment =
  # The scope that holds name's binding, and the name it has there (in key),
  # seen from env: own bindings first, then the scope's imports (the last
  # `use` wins), then the enclosing scope. nil when name is unbound.
  var cur: nil ref Environment = env
  while cur != nil:
    if cur.bindings.hasKey(name):
      key = name
      return cur
    if depth < MaxImportDepth:
      var i = cur.imports.len - 1
      while i >= 0:
        let x = cur.imports[i]
        if x.names.hasKey(name):
          let found = findCell(x.env, x.names.getOrDefault(name, name), depth + 1, key)
          if found != nil:
            return found
        elif x.all and x.env.bindings.hasKey(name):
          key = name
          return x.env
        dec i
    cur = cur.up
  return nil

proc has*(env: nil ref Environment, name: Object): bool =
  var key = name
  findCell(env, name, 0, key) != nil

proc hasOwn*(env: nil ref Environment, name: Object): bool =
  result = false
  if env != nil:
    result = env.bindings.hasKey(name)

proc lookup*(env: nil ref Environment, name: Object): Option[Object] =
  var key = name
  let found = findCell(env, name, 0, key)
  if found != nil:
    return some(found.bindings.getOrDefault(key, nothing()))
  return none[Object]()

# set reaches the binding a name stands for, which for an imported name is
# the binding in the exporting module: `use` shares bindings, it never copies.
proc assign*(env: ref Environment, name, value: Object): bool =
  var key = name
  let found = findCell(env, name, 0, key)
  result = false
  if found != nil:
    found.bindings[key] = value
    result = true

# The value a module exports under name, or none when it does not export it.
proc lookupExport*(x: ref Exports, name: Object): Option[Object] =
  if x.names.hasKey(name):
    result = lookup(x.env, x.names.getOrDefault(name, name))
  elif x.all and x.env.bindings.hasKey(name):
    result = some(x.env.bindings.getOrDefault(name, nothing()))
  else:
    result = none[Object]()
