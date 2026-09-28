import std/[syncio, strutils]
import owl/[objects, evaluator, modules]

proc printBuiltin(env: ref Environment, args, body: seq[Object]): Object {.raises.} =
  var parts: seq[string] = @[]
  for a in args:
    parts.add stringify(eval(a, env))
  echo parts.join(" ")
  nothing()

proc installIo*(env: ref Environment) =
  define(env, symbol("print"), newBuiltin("print", printBuiltin, true))
  define(env, symbol("echo"), newBuiltin("echo", printBuiltin, true))

proc ioModule*(): Module =
  result = newModule("io")
  installIo(result.env)
  exportAllBindings(result)
