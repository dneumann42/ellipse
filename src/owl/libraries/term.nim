import std/syncio
import owl/[objects, evaluator, modules]
import ./io

# The terminal primitives owl cannot express itself. Key decoding, editing and
# drawing live in owl (see editor.owl); this is only the system boundary.

{.compile: "owl_term.c".}

proc owl_term_is_tty(): int32 {.importc: "owl_term_is_tty".}
proc owl_term_stderr_is_tty(): int32 {.importc: "owl_term_stderr_is_tty".}

# Whether stderr is a terminal: owl colors its error reports there.
proc stderrIsTerminal*(): bool =
  owl_term_stderr_is_tty() != 0
proc owl_term_raw(on: int32): int32 {.importc: "owl_term_raw".}
proc owl_term_read_byte(timeoutMs: int32): int32 {.importc: "owl_term_read_byte".}
proc owl_term_size(rows, cols: var int32) {.importc: "owl_term_size".}
proc owl_term_write(s: cstring; len: int32) {.importc: "owl_term_write".}

proc isTerminalBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  boolean(owl_term_is_tty() != 0)

proc rawModeBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  if args.len != 1:
    err("raw-mode needs true or false")
  let on = toBool(eval(args[0], env))
  # buffered output must reach the terminal under the mode it was written in
  flushFile(stdout)
  if owl_term_raw(if on: 1'i32 else: 0'i32) != 0:
    err("raw-mode: the terminal refused the change")
  nothing()

proc readByteBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # read-byte waits for one input byte; read-byte ms gives up after ms
  # milliseconds and returns nothing. At end of input it returns -1.
  var timeout = -1'i32
  if args.len > 0:
    let t = eval(args[0], env)
    if not isNumber(t):
      err("read-byte needs a timeout in milliseconds, got " & stringify(t))
    timeout = int32(toNumber(t))
  let b = owl_term_read_byte(timeout)
  if b == -2:
    result = nothing()
  else:
    result = number(float64(b))

proc terminalSizeBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  var rows = 0'i32
  var cols = 0'i32
  owl_term_size(rows, cols)
  record(@[pair(symbol("rows"), number(float64(rows))),
    pair(symbol("cols"), number(float64(cols)))])

proc writeBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # write sends its strings to the terminal as they are: no separator, no
  # newline, no buffering.
  var text = ""
  for a in args:
    text.add stringify(eval(a, env))
  if capturing():
    captureText(text)
    return nothing()
  # echo goes through stdout's buffer; flush it so output stays in order
  flushFile(stdout)
  if text.len > 0:
    owl_term_write(text.toCString, int32(text.len))
  nothing()

proc installTerm*(env: ref Environment) =
  define(env, symbol("is-terminal"), newBuiltin("is-terminal", isTerminalBuiltin, true))
  define(env, symbol("raw-mode"), newBuiltin("raw-mode", rawModeBuiltin, true))
  define(env, symbol("read-byte"), newBuiltin("read-byte", readByteBuiltin, true))
  define(env, symbol("terminal-size"), newBuiltin("terminal-size", terminalSizeBuiltin, true))
  define(env, symbol("write"), newBuiltin("write", writeBuiltin, true))

proc termModule*(): Module =
  result = newModule("term")
  installTerm(result.env)
  exportAllBindings(result)
