## Serialization between Nim data and owl data.
##
## `encode` turns a Nim value into an owl `Object` -- the value an owl program
## would hold -- and `decode` reads an owl `Object` back into a Nim type.
## `owlText` writes an encoded value as owl source, which is what a settings
## file looks like on disk; `owl/settings` reads one back by evaluating that
## source in a restricted environment and decoding the value it produces.
##
## Nearly every Nim type needs no code: bools, numbers, enums, chars, strings,
## distinct types, `Option`, `set`, `seq`, arrays, tuples, tables, refs and
## objects convert by themselves. Objects and named tuples become records
## (`{}:` with `name = value` fields), sequences, sets and unnamed tuples
## become lists, options become their value or `nothing`, refs become what they
## point at or `nothing`, and tables become records keyed by their stringified
## keys -- or, once a key cannot be spelled as an owl name, a list of
## `[key value]` pairs. Fields the data leaves out keep the value the Nim type
## already had, so a file written by an older version of a type still loads.
## Numbers owl cannot spell back -- a huge integer, `1.0e20`, `nan` -- are
## written as strings, and read from them. Enums and characters are quoted: in
## owl a bare name is a *variable*, so names stand only as the keys of a
## record, and that is where they are read from.
##
## A value a settings file holds is always *data*, never a call: an enum or a
## character is written quoted, because a list whose first item is a bare name
## would read back as that name called with the rest. Hand-written files still
## load, since a name reads into any field that holds text.
##
## A type that wants a different shape defines the two hooks, the way jsony
## uses `objectToJson`/`jsonToObject` and std/json `objectToJobject`:
##
##   proc asOwl*(t: Theme): Object =
##     record(@[pair(symbol("color"), str(t.colorHex))])
##
##   proc asNim*(o: Object, t: var Theme) =
##     t.colorHex = wantText(o.field("color"))
##
## The hooks are looked up where `encode`/`decode` are *called*, so they have to
## be in scope there: define them next to the type, and import the module that
## holds them before a value of it is converted. Two field-level hooks trim the
## default code instead of replacing it: `fieldName*(obj, name)` renames a
## field in the file, `ignoreField*(obj, name)` leaves it out.
##
## A failure raises through the owl error machinery, carrying the place of the
## value that failed, so `errorText()` points at file, line and column.

import std/[tables, options, strutils, math, typetraits, macros]
import owl/[objects, reader, evaluator]
export objects

var trail: seq[string] = @[]

proc trailPush(part: string) =
  trail.add part

proc trailPop() =
  if trail.len > 0:
    trail.setLen(trail.len - 1)

proc trailReset() =
  trail.setLen(0)

proc trailText(): string =
  result = ""
  for part in trail:
    if result.len > 0:
      result.add "/"
    result.add part

proc fail*(msg: string) =
  ## Give up without a value to point at: while encoding, or over a value
  ## built by hand.
  let where = trailText()
  err(if where.len > 0: where & ": " & msg else: msg)

proc failAt(o: Object, msg: string) =
  ## Give up on a value that came out of a file: its place comes along.
  let where = trailText()
  errAt(o, if where.len > 0: where & ": " & msg else: msg)

proc typeLabel(T: typedesc): string =
  name(T)

template at*(part: string, body: untyped) =
  ## Run `body` with `part` added to the path errors report against.
  bind trailPush, trailPop
  trailPush(part)
  body
  trailPop()

proc showValue(o: Object): string =
  case objectKind(o)
  of String: "the string \"" & toStr(o) & "\""
  of Symbol: "the symbol " & toSymbol(o)
  of Number: "the number " & stringify(o)
  of Boolean: "the boolean " & stringify(o)
  of Nothing: "nothing"
  of List: "a list"
  of Record: "a record"
  else: "a " & kindName(o)

const nameDelims = {' ', '\t', '\r', '\n', '(', ')', ';', ':', '=', '"', '.'}
  ## What breaks a word in owl's reader: the lexer's delimiters, a line break,
  ## and the dot that spells an index.

func isName(text: string): bool =
  ## Whether `text` stands alone in an owl file as a name. Names read back as
  ## symbols, so anything the reader splits, quotes or turns into another kind
  ## of value -- a number, a run with a space in it -- has to be written
  ## quoted instead.
  if text.len == 0:
    return false
  for c in text:
    if c in nameDelims:
      return false
  let read = atom(text)
  result = objectKind(read) == Symbol and toSymbol(read) == text

func keyText*(o: Object): string =
  ## The name of a record key, however it was written.
  case objectKind(o)
  of Symbol: toSymbol(o)
  of String: toStr(o)
  else: stringify(o)

func spells(n: float64): bool =
  ## Whether the text `toCode` would write for `n` reads back as `n`.
  let value = atom(stringify(number(n)))
  result = objectKind(value) == Number and toNumber(value) == n

func whole(n: float64): bool =
  ## Whether `n` holds a count, with nothing after the point. owl writes
  ## counts without one, and a value past what it can spell comes out as a
  ## string instead.
  n >= -9.0e15 and n <= 9.0e15 and n == float64(int64(n))

# Reading atoms ----------------------------------------------------------------

proc wantNumber*(o: Object): float64 =
  case objectKind(o)
  of Number, Boolean:
    result = toNumber(o)
  of String:
    try:
      result = parseFloat(toStr(o))
    except:
      failAt(o, "expected a number, got " & showValue(o))
  else:
    failAt(o, "expected a number, got " & showValue(o))

proc wantText*(o: Object): string =
  case objectKind(o)
  of String:
    result = toStr(o)
  of Symbol:
    result = toSymbol(o)
  of Number, Boolean:
    result = stringify(o)
  else:
    failAt(o, "expected a string, got " & showValue(o))

proc wantBool*(o: Object): bool =
  case objectKind(o)
  of Boolean:
    result = toBool(o)
  of Number:
    result = toNumber(o) != 0.0
  of Nothing:
    result = false
  of String:
    case toStr(o)
    of "true", "yes", "on": result = true
    of "false", "no", "off": result = false
    else: failAt(o, "expected a boolean, got " & showValue(o))
  else:
    failAt(o, "expected a boolean, got " & showValue(o))

proc wantRecord(o: Object, what: string): bool =
  ## Whether `o` holds the fields of `what`. `nothing` counts: the value keeps
  ## what it has, which for a fresh one is its defaults.
  case objectKind(o)
  of Record:
    result = true
  of Nothing:
    result = false
  else:
    failAt(o, what & " needs a record, got " & showValue(o))

proc digits[T](text: string, x: var T): bool =
  ## Whole decimal digits into an integer, exactly -- past what a float64 would
  ## keep. False when the text is not a plain integer or does not fit.
  var i = 0
  var neg {.used.} = false
  when T is SomeUnsignedInt:
    discard
  else:
    if i < text.len and text[i] == '-':
      neg = true
      inc i
  if i >= text.len:
    return false
  var acc: T
  while i < text.len:
    if text[i] notin {'0' .. '9'}:
      return false
    let d = T(ord(text[i]) - ord('0'))
    if neg:
      if acc < (low(T) + d) div 10:
        return false
      acc = acc * 10 - d
    else:
      if acc > (high(T) - d) div 10:
        return false
      acc = acc * 10 + d
    inc i
  x = acc
  result = true

proc readNumber[T](o: Object, x: var T) =
  when T is SomeFloat:
    x = T(wantNumber(o))
  else:
    var exact = false
    when T is SomeInteger:
      # a count written as text -- one too big for a float to hold -- is read
      # digit by digit rather than through one
      if objectKind(o) == String or objectKind(o) == Symbol:
        exact = digits(wantText(o), x)
    if not exact:
      let rounded = round(wantNumber(o))
      if rounded < float64(low(T)) or rounded > float64(high(T)):
        failAt(o, "the number " & showValue(o) & " does not fit in " & name(T))
      x = T(rounded)

proc readEnum[T: enum](o: Object, x: var T) =
  let text = wantText(o)
  try:
    x = parseEnum[T](text)
  except:
    failAt(o, "\"" & text & "\" is not a " & name(T))

proc readChar(o: Object, x: var char) =
  let text = wantText(o)
  if text.len != 1:
    failAt(o, "expected one character, got " & showValue(o))
  x = text[0]

template decodeValue*(o: Object, T: typedesc): auto =
  ## Owl data as a fresh value of `T`.
  var value: T
  decodeInto(o, value)
  value

# Field hooks ------------------------------------------------------------------

template fieldKey*(x: auto, name: string): string =
  ## The name the field `name` is written under in the file.
  when compiles(fieldName(x, name)):
    fieldName(x, name)
  else:
    name

template skippedField*(x: auto, name: string): bool =
  ## Whether the field `name` stays out of the file.
  when compiles(ignoreField(x, name)):
    ignoreField(x, name)
  else:
    false

# Encoding ---------------------------------------------------------------------

template encodeKey*(k: auto): Object =
  ## A table key as the file holds it: a name where the text is one.
  bind objectKind, toStr, symbol, String, isName
  let value = encode(k)
  if objectKind(value) == String and isName(toStr(value)):
    symbol(toStr(value))
  else:
    value

template encodeFields*(x: auto): Object =
  ## An object or named tuple as a record of its fields.
  bind fieldPairs, skippedField, fieldKey, isName, fail, at, pair, symbol,
    record
  var parts: seq[Object] = @[]
  for field, value in fieldPairs(x):
    if not skippedField(x, field):
      let key = fieldKey(x, field)
      if not isName(key):
        fail("\"" & key & "\" cannot name a field in an owl file")
      var item: Object
      at field:
        item = encode(value)
      parts.add pair(symbol(key), item)
  record(parts)

template encodeItems*(x: auto): Object =
  ## A sequence or array as a list.
  bind at, list
  var parts: seq[Object] = @[]
  var i = 0
  for value in x.items:
    var item: Object
    at $i:
      item = encode(value)
    parts.add item
    inc i
  list(parts)

template encodeTupleItems*(x: auto): Object =
  ## An unnamed tuple as a list, in field order.
  bind fieldPairs, at, list
  var parts: seq[Object] = @[]
  for field, value in fieldPairs(x):
    var item: Object
    at field:
      item = encode(value)
    parts.add item
  list(parts)

template encodeSetItems*(x: auto): Object =
  ## A set as a list of its members, in order.
  bind list
  var parts: seq[Object] = @[]
  for value in x.items:
    parts.add encode(value)
  list(parts)

template encodePairs*(x: auto): Object =
  ## A table: a record while every key spells a name, a list of pairs after
  ## one that does not.
  bind pairs, encodeKey, objectKind, keyText, at, pair, list, record, Symbol
  var fields: seq[Object] = @[]
  var items: seq[Object] = @[]
  var named = true
  for key, value in x.pairs:
    let k = encodeKey(key)
    if objectKind(k) != Symbol:
      named = false
    var item: Object
    at keyText(k):
      item = encode(value)
    fields.add pair(k, item)
    items.add list(@[k, item])
  if named:
    record(fields)
  else:
    list(items)

template encode*(x: auto): Object =
  ## A Nim value as owl data.
  bind boolean, str, number, nothing, float64, whole, spells, distinctBase,
    isSome, get, isNil, isNamedTuple, typeof, typeLabel, encodeFields,
    encodeItems, encodeTupleItems, encodeSetItems, encodePairs
  when compiles(asOwl(x)):
    asOwl(x)
  else:
    when x is bool:
      boolean(x)
    elif x is enum:
      str($x)
    elif x is char:
      str($x)
    elif x is SomeInteger:
      let n = float64(x)
      if whole(n) and spells(n):
        number(n)
      else:
        str($x)
    elif x is SomeFloat:
      let n = float64(x)
      if spells(n):
        number(n)
      else:
        str($x)
    elif x is string:
      str(x)
    elif x is distinct:
      encode(distinctBase(x))
    elif x is Option[auto]:
      if x.isSome:
        encode(x.get)
      else:
        nothing()
    elif x is set:
      encodeSetItems(x)
    elif x is seq[auto] or x is array:
      encodeItems(x)
    elif x is Table or x is OrderedTable:
      encodePairs(x)
    elif x is tuple:
      when isNamedTuple(typeof(x)):
        encodeFields(x)
      else:
        encodeTupleItems(x)
    elif x is ref object:
      if isNil(x):
        nothing()
      else:
        encodeFields(x[])
    elif x is object:
      encodeFields(x)
    else:
      static:
        error "owl/serde: no way to encode a value of type " & typeLabel(typeof(x))

template owlText*(x: auto, width: static[int] = 80): string =
  ## A Nim value as owl source: what a settings file holds.
  bind toCode
  toCode(encode(x), width)

# Case objects -----------------------------------------------------------------

proc objectType(T: NimNode): NimNode =
  ## The object definition of a type, seen through any generic instantiation
  ## or ref layer. Runs while the macros below are building their code.
  result = T
  while result.kind notin {nnkObjectTy, nnkEmpty}:
    case result.kind
    of nnkType:
      if result.len == 0:
        break
      result = result[^1]
    of nnkBracketExpr, nnkRefTy, nnkPtrTy:
      result = result[0].getTypeImpl()
    of nnkSym:
      result = result.getTypeImpl()
    else:
      # a tuple, an enum, any other shape: there is no object beneath it
      break

proc fieldsOf(impl: NimNode): NimNode =
  ## The field list of an object definition, empty when there is none.
  if impl.kind == nnkObjectTy and impl.len > 2 and impl[2].kind == nnkRecList:
    result = impl[2]
  else:
    result = newNimNode(nnkRecList)

proc discriminantOf(part: NimNode): string =
  ## The name of a switch's discriminant field. An object definition pulled
  ## from a type symbol heads its switches with the field's definition, while
  ## one resolved for a value may hold the field's symbol directly.
  var head = part[0]
  if head.kind == nnkIdentDefs:
    head = head[0]
  while head.kind == nnkPostfix:
    head = head[0]
  result = head.strVal

macro discriminantNames(x: typed): seq[string] =
  ## The fields `x`'s type switches its branches on.
  let impl = objectType(x.getType())
  result = newTree(nnkBracket)
  for part in fieldsOf(impl):
    if part.kind == nnkRecCase:
      result.add newLit(discriminantOf(part))
  result = if result.len > 0:
    quote do: @`result`
  else:
    quote do: (seq[string]).default

proc holdsField(obj: auto, key: string): bool =
  ## Whether the object can reach `key`: one of the fields it holds open now,
  ## which for a variant is the active branch alone.
  for name, value in fieldPairs(obj):
    if name == key:
      return true
  return false

macro nameOf(obj: typed, key: static string): untyped =
  ## `obj.key`, for a key known while the code is being written.
  newDotExpr(obj, ident(key))

proc caseOf*(data: Object, key: string, T: typedesc, previous: auto): T =
  ## The value the record holds for `key`, or `previous` when it holds none.
  if data.hasField(key):
    result = decodeValue(data.field(key), T)
  else:
    result = T(previous)

macro freshFrom(data: untyped, prev: typed): untyped =
  ## A `T` built with the branches the record asks for. A discriminant cannot
  ## be assigned across branches, so the object is constructed the way the file
  ## says instead of being changed into it.
  # the object *definition* would build an anonymous object: a constructor names
  # the type by its symbol, which `getTypeInst` hands back
  let T = prev.getTypeInst()
  result = newTree(nnkObjConstr)
  result.add T
  for part in fieldsOf(objectType(T)):
    if part.kind == nnkRecCase:
      let key = ident(discriminantOf(part))
      let name = newLit(key.strVal)
      let held = newDotExpr(prev, key)
      result.add newTree(nnkExprColonExpr, key, quote do:
        caseOf(`data`, `name`, typeof(`held`), `held`))

macro branchesMatch(data: untyped, x: typed,
    keys: static seq[string]): untyped =
  ## Whether the discriminants the record asks for are the ones `x` already
  ## holds -- and so whether `x` can be filled where it stands.
  result = newLit(true)
  for key in keys:
    let name = newLit(key)
    let held = newDotExpr(x, ident(key))
    result = quote do:
      caseOf(`data`, `name`, typeof(`held`), `held`) == `held` and `result`

# Decoding ---------------------------------------------------------------------

template decodeInto*(o: Object, x: var auto) =
  ## Owl data into a Nim value. What the data does not hold keeps its value.
  ## The container templates it leans on are defined below and found the same
  ## way the hooks are: where the conversion is called.
  bind wantBool, wantText, readEnum, readChar, readNumber, objectKind, Nothing,
    distinctBase, typeof, isNamedTuple, isNil
  let data = o
  when compiles(asNim(data, x)):
    asNim(data, x)
  else:
    when x is bool:
      x = wantBool(data)
    elif x is enum:
      readEnum(data, x)
    elif x is char:
      readChar(data, x)
    elif x is SomeFloat or x is SomeInteger or x is range:
      readNumber(data, x)
    elif x is string:
      x = wantText(data)
    elif x is distinct:
      decodeInto(data, distinctBase(x))
    elif x is Option[auto]:
      decodeOption(data, x)
    elif x is set:
      decodeSet(data, x)
    elif x is seq[auto]:
      decodeSeq(data, x)
    elif x is array:
      decodeArray(data, x)
    elif x is Table:
      decodeTable(data, x)
    elif x is OrderedTable:
      decodeOrdered(data, x)
    elif x is tuple:
      when isNamedTuple(typeof(x)):
        decodeFields(data, x)
      else:
        decodeItems(data, x)
    elif x is ref object:
      if objectKind(data) == Nothing:
        x = nil
      else:
        if isNil(x):
          x = typeof(x)()
        decodeFields(data, x[])
    elif x is object:
      decodeFields(data, x)
    else:
      static:
        error "owl/serde: no way to decode into a value of type " &
          typeLabel(typeof(x))

template decodeOption*[T](o: Object, x: var Option[T]) =
  bind objectKind, Nothing, none, some
  let data = o
  if objectKind(data) == Nothing:
    x = none(T)
  else:
    var value: T
    decodeInto(data, value)
    x = some(value)

template decodeSet*[T](o: Object, x: var set[T]) =
  bind objectKind, List, itemCount, itemAt, at, showValue, failAt
  let data = o
  if objectKind(data) != List:
    failAt(data, "a set needs a list, got " & showValue(data))
  x = {}
  for i in 0 ..< itemCount(data):
    let item = itemAt(data, i)
    var value: T
    at $i:
      decodeInto(item, value)
    x.incl value

template decodeSeq*[T](o: Object, x: var seq[T]) =
  bind objectKind, List, itemCount, itemAt, at, showValue, failAt
  let data = o
  if objectKind(data) != List:
    failAt(data, "a sequence needs a list, got " & showValue(data))
  let n = itemCount(data)
  x.setLen(n)
  for i in 0 ..< n:
    let item = itemAt(data, i)
    at $i:
      decodeInto(item, x[i])

template decodeItems*[T](o: Object, x: var T) =
  ## An unnamed tuple, filled in order from a list.
  bind fieldPairs, at, itemCount, itemAt, objectKind, List, showValue, failAt
  let data = o
  if objectKind(data) != List:
    failAt(data, "a tuple needs a list, got " & showValue(data))
  let n = itemCount(data)
  var i = 0
  for field, value in fieldPairs(x):
    let item = itemAt(data, i)
    at field:
      if i < n:
        decodeInto(item, value)
    inc i
  if n > i:
    failAt(data, "the list holds more items than this tuple has fields")

template decodeArray*[N, T](o: Object, x: var array[N, T]) =
  bind objectKind, List, itemCount, itemAt, at, showValue, failAt
  let data = o
  if objectKind(data) != List:
    failAt(data, "an array needs a list, got " & showValue(data))
  if itemCount(data) != x.len:
    failAt(data, "expected " & $x.len & " items, got " & $itemCount(data))
  for i in 0 ..< x.len:
    let item = itemAt(data, i)
    at $i:
      decodeInto(item, x[i])

template decodePairsInto[K, V](o: Object, x: var auto) =
  ## A record of names, or a list of `[key value]` pairs, into a table.
  bind objectKind, Record, List, Pair, clear, recordFields, at, keyText, car,
    cdr, itemCount, itemAt, showValue, failAt
  let data = o
  x.clear()
  case objectKind(data)
  of Record:
    for f in recordFields(data):
      if objectKind(f) != Pair:
        failAt(f, "a record field needs (name = value), got " & showValue(f))
      let name = car(f)
      let value = cdr(f)
      var key: K
      var held: V
      at keyText(name):
        decodeInto(name, key)
        decodeInto(value, held)
      x[key] = held
  of List:
    for i in 0 ..< itemCount(data):
      let item = itemAt(data, i)
      if objectKind(item) != List or itemCount(item) != 2:
        failAt(item, "a table item needs [key value], got " & showValue(item))
      var key: K
      var held: V
      at $i:
        decodeInto(itemAt(item, 0), key)
        decodeInto(itemAt(item, 1), held)
      x[key] = held
  else:
    failAt(data, "a table needs a record or a list, got " & showValue(data))

template decodeTable*[K, V](o: Object, x: var Table[K, V]) =
  bind decodePairsInto
  decodePairsInto[K, V](o, x)

template decodeOrdered*[K, V](o: Object, x: var OrderedTable[K, V]) =
  bind decodePairsInto
  decodePairsInto[K, V](o, x)

template decodeIntoFields*(data: Object, x: var auto, prev: untyped,
    carry: static bool) =
  ## A record into an object's fields. Fields the record leaves out take what
  ## `prev` held: the same object while it stands, the object being replaced
  ## when the file moved it to another branch.
  bind fieldKey, skippedField, at, field, recordFields, objectKind, Pair,
    Nothing, car, keyText, showValue, failAt, typeLabel, typeof, decodeInto,
    holdsField, nameOf, discriminantNames
  const keys = discriminantNames(x)
  var seen: seq[string] = @[]
  for name, value in fieldPairs(x):
    when name in keys:
      seen.add fieldKey(x, name)   # the caller that built `x` read these already
    else:
      # a field `ignoreField` drops is not part of the shape: a file that
      # mentions it is wrong in the way any unknown name is. The drop is asked
      # at run time, as the hook reads the value to decide.
      if not skippedField(x, name):
        let key = fieldKey(x, name)
        seen.add key
        let held = data.field(key)
        at key:
          if objectKind(held) != Nothing:
            decodeInto(held, value)
          elif carry and prev.holdsField(name):
            # a rebuilt object starts from the branch alone: take the rest of
            # what the file does not mention from the object it replaces
            value = nameOf(prev, name)
  for f in recordFields(data):
    if objectKind(f) != Pair:
      failAt(f, "a record field needs (name = value), got " & showValue(f))
    let key = keyText(car(f))
    if key notin seen:
      failAt(f, "\"" & key & "\" is not a field of " & typeLabel(typeof(x)))

template decodeFields*(o: Object, x: var auto) =
  ## A record into an object or named tuple's fields. An object that switches
  ## branches is rebuilt, because a discriminant will not carry that over.
  bind wantRecord, typeLabel, typeof, decodeIntoFields, discriminantNames,
    branchesMatch, freshFrom
  let data = o
  if wantRecord(data, typeLabel(typeof(x))):
    const keys = discriminantNames(x)
    when keys.len == 0:
      decodeIntoFields(data, x, x, false)
    else:
      if branchesMatch(data, x, keys):
        # the file holds the branch `x` already stands in
        decodeIntoFields(data, x, x, false)
      else:
        # the file asks for another branch: build that object, carry what both
        # branches share, and put it in place of this one
        var moved = freshFrom(data, x)
        decodeIntoFields(data, moved, x, true)
        x = moved

template decode*(o: Object, x: var auto) =
  ## Owl data into a Nim value; `x` keeps its own values for the fields the
  ## data leaves out. `o` is read once, however often the conversion needs it.
  bind trailReset
  let data = o
  trailReset()
  try:
    decodeInto(data, x)
  finally:
    trailReset()

template decode*(o: Object, T: typedesc): auto =
  ## Owl data as a fresh value of `T`.
  decodeValue(o, T)
