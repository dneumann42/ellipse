import owl/[objects, evaluator, modules]

proc nums(env: ref Environment, args: seq[Object]): seq[float64] {.raises.} =
  result = @[]
  for a in args:
    let v = eval(a, env)
    if not isNumber(v) and not isBoolean(v):
      err("arithmetic needs numbers, got " & stringify(v))
    result.add toNumber(v)

proc plusBuiltin(env: ref Environment, args, body: seq[Object]): Object {.raises.} =
  var total = 0.0
  for v in nums(env, args):
    total += v
  number(total)

proc subBuiltin(env: ref Environment, args, body: seq[Object]): Object {.raises.} =
  let ns = nums(env, args)
  if ns.len == 0:
    err("- needs at least one argument")
  var total = ns[0]
  for i in 1 ..< ns.len:
    total -= ns[i]
  number(total)

proc mulBuiltin(env: ref Environment, args, body: seq[Object]): Object {.raises.} =
  var total = 1.0
  for v in nums(env, args):
    total *= v
  number(total)

proc divBuiltin(env: ref Environment, args, body: seq[Object]): Object {.raises.} =
  let ns = nums(env, args)
  if ns.len == 0:
    err("/ needs at least one argument")
  var total = ns[0]
  for i in 1 ..< ns.len:
    if ns[i] == 0.0:
      err("division by zero")
    total = total / ns[i]
  number(total)

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

proc ltBuiltin(env: ref Environment, args, body: seq[Object]): Object {.raises.} =
  ordered(env, args, true)

proc gtBuiltin(env: ref Environment, args, body: seq[Object]): Object {.raises.} =
  ordered(env, args, false)

proc notBuiltin(env: ref Environment, args, body: seq[Object]): Object {.raises.} =
  if args.len != 1:
    err("not needs exactly one argument")
  boolean(not toBool(eval(args[0], env)))

proc installMath*(env: ref Environment) =
  define(env, symbol("+"), newBuiltin("+", plusBuiltin, true))
  define(env, symbol("-"), newBuiltin("-", subBuiltin, true))
  define(env, symbol("*"), newBuiltin("*", mulBuiltin, true))
  define(env, symbol("/"), newBuiltin("/", divBuiltin, true))
  define(env, symbol("<"), newBuiltin("<", ltBuiltin, true))
  define(env, symbol(">"), newBuiltin(">", gtBuiltin, true))
  define(env, symbol("not"), newBuiltin("not", notBuiltin, true))

proc mathModule*(): Module =
  result = newModule("math")
  installMath(result.env)
  exportAllBindings(result)
