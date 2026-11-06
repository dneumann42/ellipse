## Owl's values and scopes.
##
## Threading model: an interpreter -- its `Library`, its environments and the
## objects they hold -- belongs to the thread that made it. Objects are
## reference-counted without atomics, so a value is never shared between
## threads; it is copied across with `isolateValue` and unpacked with
## `extract`. Every thread may run its own interpreter: all interpreter state
## that is not reached through an environment is thread-local.

import std/[tables, hashes, options, strutils, isolation]
import owl/errors

type
  Binding = object
    key: Object
    val: Object
    hash: Hash

  Bindings = object
    entries: seq[Binding]
    index: seq[int]

  Environment* = object
    up: ref Environment
    bindings: Bindings
    caller: ref Environment
    redirectFrom: ref Environment
    redirectTo: ref Environment
    imports: seq[ref Exports]

  Exports* = object
    env: ref Environment
    names: Bindings
    all: bool

  ObjectKind* = enum
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
      symHash: Hash
    of Boolean:
      isTrue: bool
    of List:
      items: ref ItemsBox
      bodyStart: int
    of Pair:
      pr: ref PairBox
    of Record:
      rec: ref ItemsBox
    of Command:
      cmd: ref CommandBox
    of Syntax:
      form: ref SyntaxBox
      scope: ref Environment
    of Scope:
      scopeRef: ref Environment

  ItemsBox = object
    xs: seq[Object]
    ops: seq[Object]
    hasOps: bool
    src: ref SourceFile
    loc: Loc
    locs: seq[Loc]

  PairBox = object
    a, b: Object
    src: ref SourceFile
    keyLoc, valLoc: Loc

  SyntaxBox = object
    form: Object
    src: ref SourceFile
    loc: Loc

  CommandBox = object
    name: string
    params: seq[Object]
    body: seq[Object]
    env: ref Environment
    isFun: bool
    dynamic: bool
    call: CommandProc
    shapes: seq[ref CallShape]
    origin: Object
    originAt: int

  CallShape* = object
    names*: seq[Object]
    defaults*: seq[Object]
    fixed*: int
    rest*: Object
    blockAt*: int
    blockSym*: Object
    emptyBlock*: bool

  CommandProc* = proc (env: ref Environment, args: seq[Object], bodyStart: int): Object {.gcsafe.}
    ## A builtin. `gcsafe`, so a builtin can neither read nor write state
    ## shared between threads.

func nothing*(): Object =
  Object(kind: Nothing)

func number*(n: float64): Object =
  Object(kind: Number, number: n)

func str*(s: sink string): Object =
  Object(kind: String, str: s)

func symbol*(name: string): Object =
  Object(kind: Symbol, symbol: name, symHash: hash(name))

func boolean*(b: bool): Object =
  Object(kind: Boolean, isTrue: b)

func list*(items: sink seq[Object], bodyStart: int = -1): Object =
  Object(kind: List, items: (ref ItemsBox)(xs: items, ops: @[], hasOps: false,
    src: nil, loc: Loc(at: 0, len: 0), locs: @[]), bodyStart: bodyStart)

func listAt*(items: sink seq[Object], src: ref SourceFile, loc: Loc,
    locs: sink seq[Loc], bodyStart: int = -1): Object =
  Object(kind: List, items: (ref ItemsBox)(xs: items, ops: @[], hasOps: false,
    src: src, loc: loc, locs: locs), bodyStart: bodyStart)

func pair*(key, val: Object): Object =
  Object(kind: Pair, pr: (ref PairBox)(a: key, b: val, src: nil,
    keyLoc: Loc(at: 0, len: 0), valLoc: Loc(at: 0, len: 0)))

func pairAt*(key, val: Object, src: ref SourceFile, keyLoc, valLoc: Loc): Object =
  Object(kind: Pair, pr: (ref PairBox)(a: key, b: val, src: src,
    keyLoc: keyLoc, valLoc: valLoc))

func record*(fields: sink seq[Object]): Object =
  Object(kind: Record, rec: (ref ItemsBox)(xs: fields, ops: @[], hasOps: false,
    src: nil, loc: Loc(at: 0, len: 0), locs: @[]))

func newCommand*(name: string, params, body: sink seq[Object], env: ref Environment,
    isFun: bool, dynamic: bool = false): Object =
  Object(kind: Command, cmd: (ref CommandBox)(name: name, params: params, body: body,
    env: env, isFun: isFun, dynamic: dynamic, call: nil, shapes: @[],
    origin: Object(kind: Nothing), originAt: 0))

proc setOrigin*(o: Object, origin: Object, at: int) =
  if o.kind == Command:
    o.cmd.origin = origin
    o.cmd.originAt = at

func syntax*(form: Object, scope: ref Environment): Object =
  Object(kind: Syntax, form: (ref SyntaxBox)(form: form, src: nil,
    loc: Loc(at: 0, len: 0)), scope: scope)

func syntaxAt*(form: Object, scope: ref Environment, at: Place): Object =
  Object(kind: Syntax, form: (ref SyntaxBox)(form: form, src: at.src, loc: at.loc),
    scope: scope)

func scopeValue*(env: ref Environment): Object =
  Object(kind: Scope, scopeRef: env)

func newBuiltin*(name: string, call: CommandProc, isFun: bool): Object =
  Object(kind: Command, cmd: (ref CommandBox)(name: name, params: @[], body: @[],
    env: nil, isFun: isFun, dynamic: false, call: call, shapes: @[],
    origin: Object(kind: Nothing), originAt: 0))

func objectKind*(o: Object): ObjectKind = o.kind

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

func scopeEnv*(o: Object): ref Environment =
  result = nil
  if o.kind == Scope:
    result = o.scopeRef

func syntaxForm*(o: Object): Object =
  result = nothing()
  if o.kind == Syntax:
    result = o.form.form

func syntaxScope*(o: Object): ref Environment =
  result = nil
  if o.kind == Syntax:
    result = o.scope

func isDynamic*(o: Object): bool =
  result = false
  if o.kind == Command:
    result = o.cmd.dynamic

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
    result = o.cmd.name

func cmdParams*(o: Object): seq[Object] =
  result = @[]
  if o.kind == Command:
    result = o.cmd.params

func cmdBody*(o: Object): seq[Object] =
  result = @[]
  if o.kind == Command:
    result = o.cmd.body

func paramsOf*(o: Object): lent seq[Object] =
  o.cmd.params

func bodyOf*(o: Object): lent seq[Object] =
  o.cmd.body

proc hasShapes*(o: Object): bool =
  o.cmd.shapes.len > 0

proc setShapes*(o: Object, withBlock, withoutBlock: CallShape) =
  o.cmd.shapes = @[(ref CallShape)(), (ref CallShape)()]
  o.cmd.shapes[0][] = withBlock
  o.cmd.shapes[1][] = withoutBlock

proc shapeOf*(o: Object, withBlock: bool): ref CallShape =
  o.cmd.shapes[if withBlock: 0 else: 1]

func headOf*(o: Object): lent Object =
  o.items.xs[0]

func cmdEnv*(o: Object): ref Environment =
  result = nil
  if o.kind == Command:
    result = o.cmd.env

func isFun*(o: Object): bool =
  result = false
  if o.kind == Command:
    result = o.cmd.isFun

func isBuiltin*(o: Object): bool =
  result = false
  if o.kind == Command:
    result = o.cmd.call != nil

func builtinCall*(o: Object): CommandProc =
  result = nil
  if o.kind == Command:
    result = o.cmd.call

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

func itemCount*(o: Object): int =
  result = 0
  if o.kind == List:
    result = o.items.xs.len

func itemAt*(o: Object, i: int): Object =
  result = nothing()
  if o.kind == List and i >= 0 and i < o.items.xs.len:
    result = o.items.xs[i]

proc operands*(o: Object): lent seq[Object] =
  if not o.items.hasOps:
    o.items.ops = o.items.xs[1 ..< o.items.xs.len]
    o.items.hasOps = true
  result = o.items.ops

func carOf*(o: Object): lent Object =
  o.pr.a

func cdrOf*(o: Object): lent Object =
  o.pr.b

func formOf*(o: Object): lent Object =
  o.form.form

func car*(o: Object): Object =
  result = nothing()
  if o.kind == Pair:
    result = o.pr.a

func cdr*(o: Object): Object =
  result = nothing()
  if o.kind == Pair:
    result = o.pr.b

func recordFields*(o: Object): seq[Object] =
  result = @[]
  if o.kind == Record:
    result = o.rec.xs

func fieldNames*(o: Object): seq[string] =
  result = @[]
  if o.kind == Record:
    for f in o.rec.xs:
      result.add toSymbol(car(f))

func fieldNamed(f: Object, name: string): bool =
  if f.kind == Pair and f.pr.a.kind == Symbol:
    result = f.pr.a.symbol == name
  else:
    result = name.len == 0

func hasField*(o: Object, name: string): bool =
  result = false
  if o.kind == Record:
    for i in 0 ..< o.rec.xs.len:
      if fieldNamed(o.rec.xs[i], name):
        return true

func field*(o: Object, name: string): Object =
  result = nothing()
  if o.kind == Record:
    for i in 0 ..< o.rec.xs.len:
      if fieldNamed(o.rec.xs[i], name):
        return cdr(o.rec.xs[i])

func `==`*(a, b: Object): bool =
  if a.kind != b.kind:
    return false
  case a.kind:
  of Nothing:
    result = true
  of Command:
    # A command is its definition: the same box, or the same builtin proc
    # under the same name. Comparing name and scope alone made every two
    # lambdas made in one scope equal.
    let x = a.cmd
    let y = b.cmd
    result = x == y or (x.call != nil and x.call == y.call and x.name == y.name and
      x.isFun == y.isFun)
  of Syntax:
    result = a.scope == b.scope and a.form.form == b.form.form
  of Scope:
    result = a.scopeRef == b.scopeRef
  of Number:
    result = a.number == b.number
  of String:
    result = a.str == b.str
  of Symbol:
    result = a.symHash == b.symHash and a.symbol == b.symbol
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
    result = a.pr.a == b.pr.a and a.pr.b == b.pr.b
  of Record:
    if a.rec.xs.len != b.rec.xs.len:
      return false
    for i in 0 ..< a.rec.xs.len:
      if a.rec.xs[i] != b.rec.xs[i]:
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
    result = result !& o.symHash
  of Boolean:
    result = result !& hash(o.isTrue)
  of List:
    result = result !& hash(o.items.xs)
  of Pair:
    result = result !& hash(o.pr.a)
    result = result !& hash(o.pr.b)
  of Record:
    result = result !& hash(o.rec.xs)
  of Command:
    result = result !& hash(o.cmd.name)
    result = result !& hash(o.cmd.isFun)
  of Syntax:
    result = result !& hash(syntaxForm(o))
  of Scope:
    discard
  result = !$result


func placeOf*(o: Object): Place =
  result = noPlace()
  case o.kind
  of List:
    if o.items.src != nil:
      result = place(o.items.src, o.items.loc)
  of Pair:
    if o.pr.src != nil:
      result = place(o.pr.src, span(o.pr.keyLoc, o.pr.valLoc))
  of Syntax:
    if o.form.src != nil:
      result = place(o.form.src, o.form.loc)
    else:
      result = placeOf(o.form.form)
  else:
    discard

func itemPlace*(o: Object, i: int): Place =
  result = noPlace()
  if o.kind == List and o.items.src != nil and i >= 0 and i < o.items.locs.len:
    result = place(o.items.src, o.items.locs[i])

func itemLocs*(o: Object): seq[Loc] =
  result = @[]
  if o.kind == List:
    result = o.items.locs

func bodyPlace*(o: Object, i: int): Place =
  result = noPlace()
  if o.kind == Command:
    result = itemPlace(o.cmd.origin, o.cmd.originAt + i)

func valuePlace*(o: Object): Place =
  result = noPlace()
  if o.kind == Pair and o.pr.src != nil:
    result = place(o.pr.src, o.pr.valLoc)

func sameValue*(a, b: Object): bool =
  if a.kind != b.kind:
    return false
  case a.kind
  of List: result = a.items == b.items
  of Pair: result = a.pr == b.pr
  of Syntax: result = a.form == b.form
  of Record: result = a.rec == b.rec
  of Command: result = a.cmd == b.cmd
  of Scope: result = a.scopeRef == b.scopeRef
  else: result = a == b

func findItem*(o: Object, x: Object): int =
  result = -1
  if o.kind == List:
    for i in 0 ..< o.items.xs.len:
      if sameValue(o.items.xs[i], x):
        return i

func `$`*(o: Object): string =
  result = "(kind: " & $o.kind
  case o.kind
  of Nothing:
    discard
  of Command:
    result.add ", name: " & o.cmd.name
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
    result.add ", a: " & $o.pr.a
    result.add ", b: " & $o.pr.b
  of Record:
    result.add ", fields: @["
    for i in 0 ..< o.rec.xs.len:
      if i > 0:
        result.add ", "
      result.add $o.rec.xs[i]
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
    result = "(" & stringify(o.pr.a) & " = " & stringify(o.pr.b) & ")"
  of Record:
    result = "{}"
    for i in 0 ..< o.rec.xs.len:
      result.add " "
      result.add stringifyArg(o.rec.xs[i])
  of Command:
    let kw = if o.cmd.isFun: "fun" elif o.cmd.dynamic: "dynamic-command" else: "command"
    result = "<" & kw & " " & o.cmd.name & ">"
  of Syntax:
    result = stringify(syntaxForm(o))
  of Scope:
    result = "<scope>"


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
    if o.rec.xs.len == 0:
      return "({})"
    result = "{}"
    for f in o.rec.xs:
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
  result = false
  if bodyAt(o) >= 0:
    return true
  case o.kind
  of List:
    for x in o.items.xs:
      if needsBlock(x):
        return true
  of Record:
    for f in o.rec.xs:
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

func isAtom(o: Object): bool =
  o.kind in {Nothing, Number, String, Symbol, Boolean}

func filledRows(items: seq[Object], indent, width: int): string =
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
    if o.rec.xs.len == 0:
      return flat
    result = "{}:"
    for f in o.rec.xs:
      result.add "\n"
      result.add indentText(inner)
      result.add lineCode(f, inner, inner, width)
  of Syntax:
    result = lineCode(syntaxForm(o), indent, col, width)
  else:
    result = flat

func definitionCode(o: Object, width: int): string =
  let kw = if o.cmd.name.len == 0: "lambda" elif o.cmd.isFun: "fun"
    elif o.cmd.dynamic: "dynamic-command" else: "command"
  result = kw
  if o.cmd.name.len > 0:
    result.add " "
    result.add o.cmd.name
  for p in o.cmd.params:
    result.add " "
    result.add inlineCode(p, true)
  result.add ":"
  result.add blockItems(o.cmd.body, 4, width)

func toCode*(o: Object, width: int = 80): string =
  if o.kind == Command and o.cmd.call == nil and o.cmd.body.len > 0:
    result = definitionCode(o, width)
  else:
    result = lineCode(o, 0, 0, width)

func keyHash(o: Object): Hash {.inline.} =
  if o.kind == Symbol: o.symHash else: hash(o)

func emptyBindings(): Bindings =
  Bindings(entries: @[], index: @[])

const IndexFrom = 8

func find(b: Bindings, k: Object, h: Hash): int =
  if b.index.len == 0:
    for i in 0 ..< b.entries.len:
      if b.entries[i].hash == h and b.entries[i].key == k:
        return i
    return -1
  let mask = b.index.len - 1
  var at = int(h) and mask
  while b.index[at] != 0:
    let i = b.index[at] - 1
    if b.entries[i].hash == h and b.entries[i].key == k:
      return i
    at = (at + 1) and mask
  result = -1

func addToIndex(b: var Bindings, i: int) =
  let mask = b.index.len - 1
  var at = int(b.entries[i].hash) and mask
  while b.index[at] != 0:
    at = (at + 1) and mask
  b.index[at] = i + 1

func reindex(b: var Bindings) =
  if b.entries.len <= IndexFrom:
    b.index = @[]
    return
  var size = 16
  while size < b.entries.len * 2:
    size = size * 2
  b.index = newSeq[int](size)
  for i in 0 ..< b.entries.len:
    addToIndex(b, i)

func put(b: var Bindings, k, v: Object, h: Hash) =
  let i = find(b, k, h)
  if i >= 0:
    b.entries[i].val = v
    return
  if b.entries.len == 0:
    b.entries = newSeqOfCap[Binding](4)
  b.entries.add Binding(key: k, val: v, hash: h)
  if b.entries.len > IndexFrom:
    if b.index.len == 0 or b.entries.len * 2 > b.index.len:
      reindex(b)
    else:
      addToIndex(b, b.entries.len - 1)

func remove(b: var Bindings, k: Object) =
  let i = find(b, k, keyHash(k))
  if i < 0:
    return
  for j in i ..< b.entries.len - 1:
    let e = b.entries[j + 1]
    b.entries[j] = e
  b.entries.setLen(b.entries.len - 1)
  reindex(b)

func hasKey(b: Bindings, k: Object): bool =
  find(b, k, keyHash(k)) >= 0

iterator keys(b: Bindings): lent Object =
  for i in 0 ..< b.entries.len:
    yield b.entries[i].key

proc newEnvironment*(up: ref Environment = nil): ref Environment =
  (ref Environment)(up: up, bindings: emptyBindings(), caller: nil,
    redirectFrom: nil, redirectTo: nil, imports: @[])

proc newExports*(env: ref Environment): ref Exports =
  (ref Exports)(env: env, names: emptyBindings(), all: false)

proc setExportAll*(x: ref Exports, on: bool) =
  x.all = on

proc exportsAll*(x: ref Exports): bool = x.all

proc exportName*(x: ref Exports, public, internal: Object) =
  put(x.names, public, internal, keyHash(public))

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
  x.names = emptyBindings()

proc setCaller*(frame: ref Environment, caller: ref Environment) =
  frame.caller = caller

proc setRedirect*(env: ref Environment, source, target: ref Environment) =
  env.redirectFrom = source
  env.redirectTo = target

proc commandCaller*(env: ref Environment): ref Environment =
  result = nil
  var cur {.cursor.}: ref Environment = env
  while cur != nil:
    let c = cur.caller
    if c != nil:
      return c
    cur = cur.up

proc resolveScope*(env: ref Environment, scope: ref Environment): ref Environment =
  result = scope
  var cur {.cursor.}: ref Environment = env
  while cur != nil:
    let target = cur.redirectTo
    if cur.redirectFrom == scope and target != nil:
      return target
    cur = cur.up

proc define*(env: ref Environment, name, value: Object) =
  put(env.bindings, name, value, keyHash(name))

proc undefine*(env: ref Environment, name: Object) =
  remove(env.bindings, name)

func allBindings*(env: ref Environment): Table[Object, Object] =
  result = initTable[Object, Object]()
  for i in 0 ..< env.bindings.entries.len:
    result[env.bindings.entries[i].key] = env.bindings.entries[i].val

const MaxImportDepth = 32

proc findCell(env: ref Environment, name: Object, h: Hash, depth: int,
    pos: var int): ref Environment =
  var cur {.cursor.}: ref Environment = env
  while cur != nil:
    let at = find(cur.bindings, name, h)
    if at >= 0:
      pos = at
      return cur
    if depth < MaxImportDepth:
      var i = cur.imports.len - 1
      while i >= 0:
        let x {.cursor.} = cur.imports[i]
        let n = find(x.names, name, h)
        if n >= 0:
          let found = findCell(x.env, x.names.entries[n].val, keyHash(x.names.entries[n].val),
            depth + 1, pos)
          if found != nil:
            return found
        elif x.all:
          let own = find(x.env.bindings, name, h)
          if own >= 0:
            pos = own
            return x.env
        dec i
    cur = cur.up
  return nil

proc has*(env: ref Environment, name: Object): bool =
  var pos = 0
  findCell(env, name, keyHash(name), 0, pos) != nil

proc hasOwn*(env: ref Environment, name: Object): bool =
  result = false
  if env != nil:
    result = env.bindings.hasKey(name)

proc getVar*(env: ref Environment, name: Object, found: var bool): Object =
  var pos = 0
  let cell = findCell(env, name, keyHash(name), 0, pos)
  if cell != nil:
    found = true
    result = cell.bindings.entries[pos].val
  else:
    found = false
    result = nothing()

proc lookup*(env: ref Environment, name: Object): Option[Object] =
  var pos = 0
  let found = findCell(env, name, keyHash(name), 0, pos)
  if found != nil:
    return some(found.bindings.entries[pos].val)
  return none[Object]()

proc assign*(env: ref Environment, name, value: Object): bool =
  var pos = 0
  let found = findCell(env, name, keyHash(name), 0, pos)
  result = false
  if found != nil:
    found.bindings.entries[pos].val = value
    result = true

proc lookupExport*(x: ref Exports, name: Object): Option[Object] =
  let n = find(x.names, name, keyHash(name))
  if n >= 0:
    result = lookup(x.env, x.names.entries[n].val)
  else:
    let own = find(x.env.bindings, name, keyHash(name))
    if x.all and own >= 0:
      result = some(x.env.bindings.entries[own].val)
    else:
      result = none[Object]()


# --- crossing threads ------------------------------------------------------

type CopyMemo = object
  sources: Table[pointer, ref SourceFile]

proc copySource(m: var CopyMemo, src: ref SourceFile): ref SourceFile =
  ## One fresh copy per source file, however many values point into it.
  if src == nil:
    return nil
  let key = cast[pointer](src)
  result = m.sources.getOrDefault(key, nil)
  if result == nil:
    result = newSource(src.name, src.text, src.internal)
    m.sources[key] = result

proc copyData(m: var CopyMemo, o: Object): Object =
  case o.kind
  of Nothing, Number, String, Symbol, Boolean:
    result = o
  of List:
    var xs = newSeqOfCap[Object](o.items.xs.len)
    for x in o.items.xs:
      xs.add copyData(m, x)
    result = listAt(xs, copySource(m, o.items.src), o.items.loc, o.items.locs,
      o.bodyStart)
  of Pair:
    result = pairAt(copyData(m, o.pr.a), copyData(m, o.pr.b),
      copySource(m, o.pr.src), o.pr.keyLoc, o.pr.valLoc)
  of Record:
    var fields = newSeqOfCap[Object](o.rec.xs.len)
    for f in o.rec.xs:
      fields.add copyData(m, f)
    result = record(fields)
  of Command, Syntax, Scope:
    raise newException(ValueError,
      "a " & kindName(o) & " cannot leave its thread: it holds a scope")

func isData*(o: Object): bool =
  ## Whether `o` can be sent to another thread: atoms, and lists, pairs and
  ## records of them. Commands, syntax and scopes hold their environment.
  case o.kind
  of Nothing, Number, String, Symbol, Boolean:
    result = true
  of List:
    result = true
    for x in o.items.xs:
      if not isData(x):
        return false
  of Pair:
    result = isData(o.pr.a) and isData(o.pr.b)
  of Record:
    result = true
    for f in o.rec.xs:
      if not isData(f):
        return false
  of Command, Syntax, Scope:
    result = false

proc isolateValue*(o: Object): Isolated[Object] =
  ## A deep copy of `o` that no other reference reaches, ready to be moved
  ## to another thread (through a `Channel`, or as a thread's argument) and
  ## unpacked there with `extract`. Source places come along, so errors still
  ## point at file, line and column. Raises `ValueError` for anything that is
  ## not `isData`.
  var memo = CopyMemo(sources: initTable[pointer, ref SourceFile]())
  # Sound: every ref in the copy was allocated just now and is reached only
  # through it.
  result = unsafeIsolate(copyData(memo, o))
