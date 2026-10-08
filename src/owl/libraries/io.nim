import std/[syncio, strutils]
import owl/[objects, evaluator, modules]

proc defaultOutput*(s: string) =
  writeLine(stdout, s)

var outputWriter*: proc(s: string) = defaultOutput

# capture-output: while it runs, echo and term's write go into a buffer
# instead of the terminal. The attach server answers a remote repl so.
var captures*: seq[string] = @[]

proc capturing*(): bool = captures.len > 0

proc captureText*(s: string) =
  if captures.len > 0:
    captures[^1].add s

proc captureLine(s: string) =
  captureText(s & "\n")

proc captureOutputBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # capture-output f: calls f and gives what it printed, as one string.
  if args.len != 1:
    err("capture-output needs a fun")
  let f = eval(args[0], env)
  let saved = outputWriter
  outputWriter = captureLine
  captures.add ""
  var text = ""
  try:
    discard invoke(f, @[])
  finally:
    outputWriter = saved
    text = captures[^1]
    captures.setLen(captures.len - 1)
  result = str(text)

proc takeCapturedBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # take-captured: what the innermost capture-output has collected so far,
  # handed over and cleared ("" outside a capture), so a caller can keep
  # printed output in order with what it records itself.
  if captures.len == 0:
    return str("")
  let last = captures.len - 1
  result = str(captures[last])
  captures[last] = ""

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
  define(env, symbol("capture-output"), newBuiltin("capture-output", captureOutputBuiltin, true))
  define(env, symbol("take-captured"), newBuiltin("take-captured", takeCapturedBuiltin, true))
  define(env, symbol("readline"), newBuiltin("readline", readlineBuiltin, true))

proc ioModule*(): Module =
  result = newModule("io")
  installIo(result.env)
  exportAllBindings(result)
