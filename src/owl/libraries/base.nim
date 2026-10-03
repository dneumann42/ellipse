import std/[cmdline, options, strutils]
import owl/[objects, evaluator, reader, modules]

# Compile-time file embedding via a Nimony template plugin (see deps/embedFile.nim).
template embedFile(path: string): string {.plugin: "deps/embedFile".}

proc quoteBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  if args.len == 0:
    err("quote needs one argument")
  args[0]

proc evalBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  if args.len == 0:
    err("eval needs one argument")
  let syntax = eval(args[0], env)
  eval(syntax, env)

proc ifBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  if args.len == 0:
    err("if needs a condition")
  if bodyStart >= args.len:
    err("if needs at least one body form")
  if toBool(eval(args[0], env)):
    eval(args[bodyStart], env)
  else:
    evalForms(env, args[bodyStart + 1 ..< args.len])

proc doBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  result = nothing()
  for form in args:
    result = eval(form, env)

proc whileBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  if args.len == 0:
    err("while needs a condition")
  if bodyStart >= args.len:
    err("while needs at least one body form")
  while toBool(eval(args[0], env)):
    discard evalForms(env, args[bodyStart ..< args.len])
  nothing()

proc whenBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  if args.len == 0:
    err("when needs a condition")
  if bodyStart >= args.len:
    err("when needs at least one body form")
  if toBool(eval(args[0], env)):
    evalForms(env, args[bodyStart ..< args.len])
  else:
    nothing()

proc condBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # Each argument is an unevaluated pair (test = body). The test is either a raw
  # symbol (evaluated as a value, e.g. 'true' for the else branch) or a grouped
  # call kept syntactically by the reader. The first truthy test runs its body.
  result = nothing()
  for form in args:
    if not isPair(form):
      err("cond needs (test = body) pairs")
    if toBool(eval(car(form), env)):
      return eval(cdr(form), env)

proc concatBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  if args.len == 0:
    err("concat needs at least one argument")
  let first = eval(args[0], env)
  if isString(first):
    var joined = toStr(first)
    for i in 1 ..< args.len:
      let v = eval(args[i], env)
      if not isString(v):
        err("concat mixes a string with " & stringify(v))
      joined.add toStr(v)
    result = str(joined)
  elif isList(first):
    var joined = toSeq(first)
    for i in 1 ..< args.len:
      let v = eval(args[i], env)
      if not isList(v):
        err("concat mixes a list with " & stringify(v))
      for x in toSeq(v):
        joined.add x
    result = list(joined)
  elif isRecord(first):
    var joined = recordFields(first)
    for i in 1 ..< args.len:
      let v = eval(args[i], env)
      if not isRecord(v):
        err("concat mixes a record with " & stringify(v))
      for x in recordFields(v):
        joined.add x
    result = record(joined)
  else:
    err("concat needs strings, lists or records, got " & stringify(first))
    result = nothing()

proc errorBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  var parts: seq[string] = @[]
  for a in args:
    parts.add stringify(eval(a, env))
  err(parts.join(" "))

proc setBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  if args.len != 2:
    err("set needs a name and a value")
  var key = args[0]
  if not isSymbol(key):
    key = eval(key, env)
  if not isSymbol(key):
    err("set needs a symbol name, got " & stringify(key))
  let value = eval(args[1], env)
  if not assign(env, key, value):
    err("set on an unbound symbol: " & toSymbol(key))
  value

proc pairBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  if args.len != 2:
    err("pair needs a name and a value")
  var key = args[0]
  if not isSymbol(key):
    key = eval(key, env)
  if not isSymbol(key):
    err("pair needs a symbol name, got " & stringify(key))
  pair(key, eval(args[1], env))

proc nums(env: ref Environment, args: seq[Object]): seq[float64] {.raises.} =
  numbersIn(env, args, "comparison")

proc ordered(env: ref Environment, args: seq[Object], ascending: bool): Object {.raises.} =
  let ns = nums(env, args)
  if ns.len < 2:
    err("comparisons need at least two arguments")
  result = boolean(true)
  for i in 1 ..< ns.len:
    if ascending:
      if not (ns[i - 1] < ns[i]):
        result = boolean(false)
        return
    else:
      if not (ns[i - 1] > ns[i]):
        result = boolean(false)
        return

proc ltBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  ordered(env, args, true)

proc gtBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  ordered(env, args, false)

proc equality(env: ref Environment, args: seq[Object], wantSame: bool): Object {.raises.} =
  if args.len < 2:
    err("comparisons need at least two arguments")
  result = boolean(true)
  var previous = eval(args[0], env)
  for i in 1 ..< args.len:
    let current = eval(args[i], env)
    if (current == previous) != wantSame:
      result = boolean(false)
      return
    previous = current

proc eqBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  equality(env, args, true)

proc neBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  equality(env, args, false)

proc notBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  if args.len != 1:
    err("not needs exactly one argument")
  boolean(not toBool(eval(args[0], env)))

proc defineInEnv(env: ref Environment, args: seq[Object], bodyStart: int,
    isFun: bool): Object {.raises.} =
  if args.len < 1 or not isSymbol(args[0]):
    let kw = if isFun: "fun" else: "command"
    err(kw & " needs a name")
  define(env, args[0], newCommand(toSymbol(args[0]), args[1 ..< bodyStart],
    args[bodyStart ..< args.len], env, isFun))
  nothing()

proc funBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  defineInEnv(env, args, bodyStart, true)

proc commandBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  defineInEnv(env, args, bodyStart, false)

proc lambdaBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  result = newCommand("", args[0 ..< bodyStart], args[bodyStart ..< args.len], env, true)

proc recordBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  var fields: seq[Object] = @[]
  for form in args:
    if not isPair(form):
      err("{} needs (name = value) forms")
    if not isSymbol(car(form)):
      err("{} needs a symbol before '='")
    fields.add pair(car(form), eval(cdr(form), env))
  record(fields)

proc listBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  var xs: seq[Object] = @[]
  for form in args:
    xs.add eval(form, env)
  list(xs)

proc hasLength(o: Object): bool =
  isList(o) or isRecord(o) or isString(o) or isPair(o)

proc lengthOf(o: Object): int =
  result = 0
  if isList(o):
    result = toSeq(o).len
  elif isRecord(o):
    result = recordFields(o).len
  elif isString(o):
    result = toStr(o).len
  elif isPair(o):
    result = 2

proc lengthBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  if args.len != 1:
    err("length needs one argument")
  let o = eval(args[0], env)
  if not hasLength(o):
    err("length needs something with a length, got " & stringify(o))
  number(float64(lengthOf(o)))

proc nameOf(key: Object): string =
  result = ""
  if isSymbol(key):
    result = toSymbol(key)
  elif isString(key):
    result = toStr(key)

proc positionOf(key: Object): int =
  result = -1
  if isNumber(key):
    let n = toNumber(key)
    if n >= 0.0 and n == float64(int64(n)):
      result = int(n)

proc keyOf(env: ref Environment, form: Object): Object {.raises.} =
  result = form
  if not isSymbol(form):
    result = eval(form, env)

proc indexAt(o: Object, key: Object): Object {.raises.} =
  let name = nameOf(key)
  if name.len > 0:
    if isRecord(o):
      return field(o, name)
    err("index needs a record for a name, got " & stringify(o))
  let at = positionOf(key)
  if at < 0:
    if isNumber(key):
      err("index needs a whole number position, got " & stringify(key))
    err("index needs a number or a name key, got " & stringify(key))
  if not hasLength(o):
    err("index needs something with a length, got " & stringify(o))
  if at >= lengthOf(o):
    err("index out of range: " & stringify(key) & " for " & stringify(o))
  if isPair(o):
    result = if at == 0: car(o) else: cdr(o)
  elif isString(o):
    result = str(toStr(o)[at .. at])
  elif isRecord(o):
    result = recordFields(o)[at]
  else:
    result = toSeq(o)[at]

proc indexBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  if args.len < 2:
    err("index needs a value and a key")
  result = eval(args[0], env)
  for i in 1 ..< args.len:
    result = indexAt(result, keyOf(env, args[i]))

proc fieldBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  if args.len != 2:
    err("field needs a record and a name")
  let o = eval(args[0], env)
  let key = keyOf(env, args[1])
  if not isRecord(o):
    err("field needs a record, got " & stringify(o))
  if nameOf(key).len == 0:
    err("field needs a name, got " & stringify(key))
  field(o, nameOf(key))

proc listVar(env: ref Environment, form: Object, what: string): Object {.raises.} =
  if not isSymbol(form):
    err(what & " needs a variable name")
  let found = lookup(env, form)
  if found.isNone:
    err(what & " needs a defined variable: " & toSymbol(form))
  result = found.get()
  if not isList(result):
    err(what & " needs a list variable, got " & stringify(result))

proc storeList(env: ref Environment, name: Object, items: seq[Object]) =
  discard assign(env, name, list(items))

proc appendBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  if args.len < 1:
    err("append needs a variable")
  var items = toSeq(listVar(env, args[0], "append"))
  for i in 1 ..< args.len:
    items.add eval(args[i], env)
  storeList(env, args[0], items)
  list(items)

proc prependBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  if args.len < 1:
    err("prepend needs a variable")
  var items: seq[Object] = @[]
  for i in 1 ..< args.len:
    items.add eval(args[i], env)
  for x in toSeq(listVar(env, args[0], "prepend")):
    items.add x
  storeList(env, args[0], items)
  list(items)

proc insertBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  if args.len < 2:
    err("insert needs a variable and a position")
  let items = toSeq(listVar(env, args[0], "insert"))
  let key = eval(args[1], env)
  let at = positionOf(key)
  if at < 0:
    err("insert needs a whole number position, got " & stringify(key))
  if at > items.len:
    err("insert position out of range: " & stringify(key))
  var grown: seq[Object] = @[]
  for i in 0 ..< at:
    grown.add items[i]
  for i in 2 ..< args.len:
    grown.add eval(args[i], env)
  for i in at ..< items.len:
    grown.add items[i]
  storeList(env, args[0], grown)
  list(grown)

proc popBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  if args.len != 1:
    err("pop needs one variable")
  let items = toSeq(listVar(env, args[0], "pop"))
  if items.len == 0:
    err("pop from an empty list")
  result = items[^1]
  var rest: seq[Object] = @[]
  for i in 0 ..< items.len - 1:
    rest.add items[i]
  storeList(env, args[0], rest)

proc popFrontBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  if args.len != 1:
    err("pop-front needs one variable")
  let items = toSeq(listVar(env, args[0], "pop-front"))
  if items.len == 0:
    err("pop-front from an empty list")
  result = items[0]
  var rest: seq[Object] = @[]
  for i in 1 ..< items.len:
    rest.add items[i]
  storeList(env, args[0], rest)

proc argvValue(): Object =
  var xs: seq[Object] = @[]
  for i in 1 .. paramCount():
    xs.add str(paramStr(i))
  list(xs)

proc installBaseOwl*(env: ref Environment)

proc installBase*(env: ref Environment) =
  define(env, symbol("argv"), argvValue())
  define(env, symbol("nothing"), nothing())
  define(env, symbol("true"), boolean(true))
  define(env, symbol("false"), boolean(false))
  define(env, symbol("concat"), newBuiltin("concat", concatBuiltin, true))
  define(env, symbol("error"), newBuiltin("error", errorBuiltin, false))
  define(env, symbol("do"), newBuiltin("do", doBuiltin, false))
  define(env, symbol("while"), newBuiltin("while", whileBuiltin, false))
  define(env, symbol("when"), newBuiltin("when", whenBuiltin, false))
  define(env, symbol("cond"), newBuiltin("cond", condBuiltin, false))
  define(env, symbol("pair"), newBuiltin("pair", pairBuiltin, false))
  define(env, symbol("set"), newBuiltin("set", setBuiltin, false))
  define(env, symbol("quote"), newBuiltin("quote", quoteBuiltin, false))
  define(env, symbol("eval"), newBuiltin("eval", evalBuiltin, false))
  define(env, symbol("if"), newBuiltin("if", ifBuiltin, false))
  define(env, symbol("<"), newBuiltin("<", ltBuiltin, true))
  define(env, symbol(">"), newBuiltin(">", gtBuiltin, true))
  define(env, symbol("="), newBuiltin("=", eqBuiltin, true))
  define(env, symbol("<>"), newBuiltin("<>", neBuiltin, true))
  define(env, symbol("not"), newBuiltin("not", notBuiltin, true))
  define(env, symbol("fun"), newBuiltin("fun", funBuiltin, true))
  define(env, symbol("command"), newBuiltin("command", commandBuiltin, false))
  define(env, symbol("lambda"), newBuiltin("lambda", lambdaBuiltin, true))
  define(env, symbol("λ"), newBuiltin("λ", lambdaBuiltin, true))
  define(env, symbol("{}"), newBuiltin("{}", recordBuiltin, true))
  define(env, symbol("[]"), newBuiltin("[]", listBuiltin, true))
  define(env, symbol("length"), newBuiltin("length", lengthBuiltin, true))
  define(env, symbol("index"), newBuiltin("index", indexBuiltin, true))
  define(env, symbol("field"), newBuiltin("field", fieldBuiltin, true))
  define(env, symbol("append"), newBuiltin("append", appendBuiltin, false))
  define(env, symbol("prepend"), newBuiltin("prepend", prependBuiltin, false))
  define(env, symbol("insert"), newBuiltin("insert", insertBuiltin, false))
  define(env, symbol("pop"), newBuiltin("pop", popBuiltin, false))
  define(env, symbol("pop-front"), newBuiltin("pop-front", popFrontBuiltin, false))
  installBaseOwl(env)

proc installBaseOwl*(env: ref Environment) =
  # Merge the owl half of base into the same env as the Nim builtins, so that
  # `use base` exports both. base.owl uses only base primitives and never a
  # number from another module; base is the bottom of the stack.
  # embedFile is a compile-time template plugin: the source is read at build
  # time and baked in as a literal (Nimony has no staticRead). The path is
  # resolved relative to this file, so the build is independent of the cwd.
  const source: string = embedFile("base.owl")
  let parsed = parseOwl(source)
  if parsed.isOk:
    for f in parsed.get(@[]):
      if isDefinition(f, "command"):
        makeDefinition(env, f, false)
      elif isDefinition(f, "fun"):
        makeDefinition(env, f, true)

proc baseModule*(): Module =
  result = newModule("base")
  installBase(result.env)
  exportAllBindings(result)
