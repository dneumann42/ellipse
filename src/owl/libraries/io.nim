import std/[syncio, strutils]
import owl/[objects, evaluator, modules]

proc defaultOutput*(s: string) =
  writeLine(stdout, s)

var outputWriter*: proc(s: string) = defaultOutput

proc printBuiltin(env: ref Environment, args, body: seq[Object]): Object {.raises.} =
  var parts: seq[string] = @[]
  for a in args:
    parts.add stringify(eval(a, env))
  outputWriter(parts.join(" "))
  nothing()

proc readlineBuiltin(env: ref Environment, args, body: seq[Object]): Object {.raises.} =
  var prompt = "> "
  if args.len > 0:
    prompt = stringify(eval(args[0], env))
  stdout.write prompt
  var line = ""
  discard stdin.readLine(line)
  str(line)

proc installIo*(env: ref Environment) =
  define(env, symbol("print"), newBuiltin("print", printBuiltin, true))
  define(env, symbol("echo"), newBuiltin("echo", printBuiltin, true))
  define(env, symbol("readline"), newBuiltin("readline", readlineBuiltin, true))

proc ioModule*(): Module =
  result = newModule("io")
  installIo(result.env)
  exportAllBindings(result)
