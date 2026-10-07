import owl/[objects, evaluator, modules]

proc nums(env: ref Environment, args: seq[Object]): seq[float64] {.raises.} =
  numbersIn(env, args, "arithmetic")

proc plusBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  var total = 0.0
  for v in nums(env, args):
    total += v
  number(total)

proc subBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  let ns = nums(env, args)
  if ns.len == 0:
    err("- needs at least one argument")
  var total = ns[0]
  for i in 1 ..< ns.len:
    total -= ns[i]
  number(total)

proc mulBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  var total = 1.0
  for v in nums(env, args):
    total *= v
  number(total)

proc divBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  let ns = nums(env, args)
  if ns.len == 0:
    err("/ needs at least one argument")
  var total = ns[0]
  for i in 1 ..< ns.len:
    if ns[i] == 0.0:
      err("division by zero")
    total = total / ns[i]
  number(total)

proc floorBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # floor x: the largest whole number not above x.
  let ns = numbersIn(env, args, "floor")
  if ns.len != 1:
    err("floor needs one number")
  let x = ns[0]
  var f = float64(int64(x))
  if f > x:
    f -= 1.0
  number(f)

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
