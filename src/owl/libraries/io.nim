import std/[syncio, strutils]
import owl/[objects, evaluator, modules]

type OutputWriter* = proc (s: string) {.gcsafe.}

proc defaultOutput*(s: string) =
  writeLine(stdout, s)

# Per thread, like the interpreter that prints: one thread capturing output
# never swallows another's.
var outputWriter* {.threadvar.}: OutputWriter
  ## Where `print` and `echo` go; `nil` writes lines to stdout.

var captures* {.threadvar.}: seq[string]

proc output*(s: string) =
  ## Send a line to this thread's output writer.
  let w = outputWriter
  if w == nil:
    defaultOutput(s)
  else:
    w(s)

proc capturing*(): bool = captures.len > 0

proc captureText*(s: string) =
  if captures.len > 0:
    captures[^1].add s

proc captureLine(s: string) =
  captureText(s & "\n")

proc captureOutputBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object =
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

proc takeCapturedBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object =
  if captures.len == 0:
    return str("")
  let last = captures.len - 1
  result = str(captures[last])
  captures[last] = ""

proc printBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object =
  var parts: seq[string] = @[]
  for a in args:
    parts.add stringify(eval(a, env))
  output(parts.join(" "))
  nothing()

proc readlineBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object =
  var prompt = "> "
  if args.len > 0:
    prompt = stringify(eval(args[0], env))
  stdout.write prompt
  flushFile(stdout)
  var line = ""
  if not stdin.readLine(line) and line.len == 0:
    return nothing()
  str(line)

proc installIo*(env: ref Environment) =
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
