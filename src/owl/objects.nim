import std/[tables, hashes, options]

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
    Fun

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
    of Pair:
      a, b: nil ref Object
    of Fun:
      discard

func nothing*(): Object =
  Object(kind: Nothing)

func number*(n: float64): Object =
  Object(kind: Number, number: n)

func symbol*(name: string): Object =
  Object(kind: Symbol, symbol: name)

func boolean*(b: bool): Object =
  Object(kind: Boolean, isTrue: b)

func list*(items: seq[Object]): Object =
  Object(kind: List, items: items)

func box(o: Object): ref Object =
  result = (ref Object)(kind: Nothing)
  result[] = o

func pair*(key, val: Object): Object =
  Object(kind: Pair, a: box(key), b: box(val))

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

func `==`*(a, b: Object): bool =
  if a.kind != b.kind:
    return false
  case a.kind:
  of Nothing, Fun:
    result = true
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
  of Fun:
    discard
  result = !$result

proc newEnvironment*(up: nil ref Environment = nil): ref Environment =
  (ref Environment)(up: up, bindings: initTable[Object, Object]())

proc define*(env: ref Environment, name, value: Object) =
  env.bindings[name] = value

proc has*(env: nil ref Environment, name: Object): bool =
  var cur: nil ref Environment = env
  while cur != nil:
    if cur.bindings.hasKey(name):
      return true
    cur = cur.up
  return false

proc lookup*(env: nil ref Environment, name: Object): Option[Object] =
  var cur: nil ref Environment = env
  while cur != nil:
    if cur.bindings.hasKey(name):
      return some(cur.bindings.getOrDefault(name, nothing()))
    cur = cur.up
  return none[Object]()
