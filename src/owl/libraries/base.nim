import std/[syncio, cmdline]
import owl/[objects, evaluator, modules]

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

proc argvValue(): Object =
  var xs: seq[Object] = @[]
  for i in 1 .. paramCount():
    xs.add str(paramStr(i))
  list(xs)

proc installBase*(env: ref Environment) =
  define(env, symbol("argv"), argvValue())
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

proc baseModule*(): Module =
  result = newModule("base")
  installBase(result.env)
  exportAllBindings(result)
