import owl/[objects, evaluator, modules]

proc listBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  var xs: seq[Object] = @[]
  for a in args:
    xs.add eval(a, env)
  list(xs)

proc installList*(env: ref Environment) =
  define(env, symbol("list"), newBuiltin("list", listBuiltin, true))

proc listModule*(): Module =
  result = newModule("list")
  installList(result.env)
  exportAllBindings(result)
