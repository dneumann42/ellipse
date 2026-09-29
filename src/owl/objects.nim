import std/[tables, hashes, options, strutils]

type
  Environment* = object
    up: nil ref Environment
    bindings: Table[Object, Object]

  ObjectKind = enum
    Nothing
    Number
    Symbol
    Boolean
    List
    Pair
    Record
    Command

  Object* = object
    case kind: ObjectKind
    of Nothing:
      discard
    of Number:
      number: float64
    of Symbol:
      symbol: string
    of Boolean:
      isTrue: bool
    of List:
      items: seq[Object]
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
      call: CommandProc

  CommandProc* = nil proc (env: ref Environment, args: seq[Object], body: seq[Object]): Object {.raises.}

func nothing*(): Object =
  Object(kind: Nothing)

func number*(n: float64): Object =
  Object(kind: Number, number: n)

func symbol*(name: string): Object =
  Object(kind: Symbol, symbol: name)

func boolean*(b: bool): Object =
  Object(kind: Boolean, isTrue: b)

func list*(items: seq[Object], bodyStart: int = -1): Object =
  Object(kind: List, items: items, bodyStart: bodyStart)

func box(o: Object): ref Object =
  result = (ref Object)(kind: Nothing)
  result[] = o

func pair*(key, val: Object): Object =
  Object(kind: Pair, a: box(key), b: box(val))

func record*(fields: seq[Object]): Object =
  Object(kind: Record, fields: fields)

func newCommand*(name: string, params, body: seq[Object], env: nil ref Environment,
    isFun: bool): Object =
  Object(kind: Command, name: name, params: params, body: body, env: env, isFun: isFun,
    call: nil)

func newBuiltin*(name: string, call: CommandProc, isFun: bool): Object =
  Object(kind: Command, name: name, isFun: isFun, call: call)

func isNothing*(o: Object): bool = o.kind == Nothing
func isNumber*(o: Object): bool = o.kind == Number
func isSymbol*(o: Object): bool = o.kind == Symbol
func isBoolean*(o: Object): bool = o.kind == Boolean
func isList*(o: Object): bool = o.kind == List
func isPair*(o: Object): bool = o.kind == Pair
func isRecord*(o: Object): bool = o.kind == Record
func isCommand*(o: Object): bool = o.kind == Command

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

func toSeq*(o: Object): seq[Object] =
  result = @[]
  case o.kind
  of List:
    result = o.items
  else:
    discard

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
    result = a.name == b.name and a.isFun == b.isFun and a.env == b.env and
      (a.call == b.call or (a.call != nil and b.call != nil))
  of Number:
    result = a.number == b.number
  of Symbol:
    result = a.symbol == b.symbol
  of Boolean:
    result = a.isTrue == b.isTrue
  of List:
    if a.items.len != b.items.len:
      return false
    for i in 0 ..< a.items.len:
      if a.items[i] != b.items[i]:
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
  of Symbol:
    result = result !& hash(o.symbol)
  of Boolean:
    result = result !& hash(o.isTrue)
  of List:
    result = result !& hash(o.items)
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
  result = !$result

func `$`*(o: Object): string =
  result = "(kind: " & $o.kind
  case o.kind
  of Nothing:
    discard
  of Command:
    result.add ", name: " & o.name
  of Number:
    result.add ", number: " & $o.number
  of Symbol:
    result.add ", symbol: " & o.symbol.escape
  of Boolean:
    result.add ", isTrue: " & $o.isTrue
  of List:
    result.add ", items: @["
    for i in 0 ..< o.items.len:
      if i > 0:
        result.add ", "
      result.add $o.items[i]
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
  of Symbol:
    result = o.symbol
  of Boolean:
    result = if o.isTrue: "true" else: "false"
  of List:
    if o.items.len > 0 and isSymbol(o.items[0]):
      result = stringifyArg(o.items[0])
      for i in 1 ..< o.items.len:
        result.add " "
        result.add stringifyArg(o.items[i])
    else:
      result = "[]"
      for i in 0 ..< o.items.len:
        result.add " "
        result.add stringifyArg(o.items[i])
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
    let kw = if o.isFun: "fun" else: "command"
    result = "<" & kw & " " & o.name & ">"

proc newEnvironment*(up: nil ref Environment = nil): ref Environment =
  (ref Environment)(up: up, bindings: initTable[Object, Object]())

proc define*(env: ref Environment, name, value: Object) =
  env.bindings[name] = value

func allBindings*(env: ref Environment): Table[Object, Object] =
  result = env.bindings

proc has*(env: nil ref Environment, name: Object): bool =
  var cur: nil ref Environment = env
  while cur != nil:
    if cur.bindings.hasKey(name):
      return true
    cur = cur.up
  return false

proc hasOwn*(env: nil ref Environment, name: Object): bool =
  result = false
  if env != nil:
    result = env.bindings.hasKey(name)

proc lookup*(env: nil ref Environment, name: Object): Option[Object] =
  var cur: nil ref Environment = env
  while cur != nil:
    if cur.bindings.hasKey(name):
      return some(cur.bindings.getOrDefault(name, nothing()))
    cur = cur.up
  return none[Object]()
