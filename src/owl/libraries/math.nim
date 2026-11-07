import std/math
import owl/[objects, evaluator, modules]

proc nums(env: ref Environment, args: seq[Object]): seq[float64] =
  numbersIn(env, args, "arithmetic")

proc plusBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object =
  var total = 0.0
  for a in args:
    total += numberIn(env, a, "arithmetic")
  number(total)

proc subBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object =
  if args.len == 0:
    err("- needs at least one argument")
  var total = numberIn(env, args[0], "arithmetic")
  for i in 1 ..< args.len:
    total -= numberIn(env, args[i], "arithmetic")
  number(total)

proc mulBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object =
  var total = 1.0
  for a in args:
    total *= numberIn(env, a, "arithmetic")
  number(total)

proc divBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object =
  let ns = nums(env, args)
  if ns.len == 0:
    err("/ needs at least one argument")
  var total = ns[0]
  for i in 1 ..< ns.len:
    if ns[i] == 0.0:
      err("division by zero")
    total = total / ns[i]
  number(total)

proc floorBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object =
  let ns = numbersIn(env, args, "floor")
  if ns.len != 1:
    err("floor needs one number")
  number(floor(ns[0]))

proc installMath*(env: ref Environment) =
  define(env, symbol("+"), newBuiltin("+", plusBuiltin, true))
  define(env, symbol("-"), newBuiltin("-", subBuiltin, true))
  define(env, symbol("*"), newBuiltin("*", mulBuiltin, true))
  define(env, symbol("/"), newBuiltin("/", divBuiltin, true))
  define(env, symbol("floor"), newBuiltin("floor", floorBuiltin, true))

proc mathModule*(): Module =
  result = newModule("math")
  installMath(result.env)
  exportAllBindings(result)
