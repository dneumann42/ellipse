import std/[syncio, strutils]
import owl/[objects, evaluator, modules]

proc defaultOutput*(s: string) =
  writeLine(stdout, s)

var outputWriter*: proc(s: string) = defaultOutput

proc printBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  var parts: seq[string] = @[]
  for a in args:
    parts.add stringify(eval(a, env))
  outputWriter(parts.join(" "))
  nothing()

proc readlineBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  var prompt = "> "
  if args.len > 0:
    prompt = stringify(eval(args[0], env))
  stdout.write prompt
  flushFile(stdout)
  var line = ""
  # At end of input readline gives nothing, so loops can stop on it.
  if not stdin.readLine(line) and line.len == 0:
    return nothing()
  str(line)

proc installIo*(env: ref Environment) =
  # Owl strings have no escapes, so the line break is provided as a value.
  define(env, symbol("newline"), str("\n"))
  define(env, symbol("print"), newBuiltin("print", printBuiltin, true))
  define(env, symbol("echo"), newBuiltin("echo", printBuiltin, true))
  define(env, symbol("readline"), newBuiltin("readline", readlineBuiltin, true))

proc ioModule*(): Module =
  result = newModule("io")
  installIo(result.env)
  exportAllBindings(result)
