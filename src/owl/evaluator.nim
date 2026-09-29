import std/[options, syncio, strutils]
import owl/objects

proc defaultErrorReport*(msg: string) =
  writeLine(stderr, "owl error: " & msg)

var errorReport*: proc(msg: string) = defaultErrorReport

proc err*(msg: string) {.raises.} =
  errorReport(msg)
  raise ValueError

proc operandsOf(o: Object): seq[Object] =
  let it = toSeq(o)
  result = @[]
  for i in 1 ..< it.len:
    result.add it[i]

proc bodyStartOf(o: Object): int =
  let it = toSeq(o)
  let bs = bodyStart(o)
  result = if bs >= 1 and bs < it.len: bs - 1 else: max(it.len - 1, 0)

proc numbersIn*(env: ref Environment, args: seq[Object], what: string): seq[float64] {.raises.} =
  result = @[]
  for a in args:
    let v = eval(a, env)
    if not isNumber(v) and not isBoolean(v):
      err(what & " needs numbers, got " & stringify(v))
    result.add toNumber(v)

proc headSymbol(o: Object): string =
  result = ""
  if isList(o):
    let it = toSeq(o)
    if it.len > 0:
      result = toSymbol(it[0])

proc paramName(p: Object): Object {.raises.} =
  result = p
  if isPair(p):
    result = car(p)
  if not isSymbol(result):
    err("a parameter must be a symbol or a (name = default) pair")

proc restName(p: Object): Object =
  # A command's last parameter ending in '+' collects the caller's block.
  result = nothing()
  var name = p
  if isPair(p):
    name = car(p)
  if isSymbol(name):
    let text = toSymbol(name)
    if text.len > 1 and text.endsWith("+"):
      result = symbol(text[0 ..< text.len - 1])

proc bindParams(cmd: Object, argObjs: seq[Object], callerEnv: ref Environment,
    child: ref Environment) {.raises.} =
  let params = cmdParams(cmd)
  var fixed = params.len
  var rest = nothing()
  if not isFun(cmd) and params.len > 0:
    rest = restName(params[^1])
    if not rest.isNothing:
      fixed = params.len - 1
  var pos = 0
  var extras: seq[Object] = @[]
  for a in argObjs:
    var name = a
    var value = a
    if not rest.isNothing and pos >= fixed:
      extras.add a
      continue
    if isPair(a) and isSymbol(car(a)):
      name = car(a)
      value = cdr(a)
      if isFun(cmd):
        value = eval(value, callerEnv)
    else:
      if pos < fixed:
        name = paramName(params[pos])
        inc pos
        if isFun(cmd):
          value = eval(value, callerEnv)
      elif rest.isNothing:
        err("too many arguments for " & cmdName(cmd))
      else:
        extras.add a
        continue
    define(child, name, value)
  if not rest.isNothing:
    define(child, rest, list(extras))
  for p in params:
    if isPair(p):
      let name = car(p)
      if not hasOwn(child, name):
        var value = cdr(p)
        if isFun(cmd):
          value = eval(value, child)
        define(child, name, value)

proc apply(cmd: Object, callerEnv: ref Environment, args: seq[Object],
    bodyStart: int): Object {.raises.} =
  if isBuiltin(cmd):
    let call = builtinCall(cmd)
    if call == nil:
      err("builtin " & cmdName(cmd) & " has no implementation")
    return call(callerEnv, args, bodyStart)
  let upEnv = if isFun(cmd): cmdEnv(cmd) else: callerEnv
  let child = newEnvironment(upEnv)
  bindParams(cmd, args, callerEnv, child)
  evalForms(child, cmdBody(cmd))

proc evalForms*(env: ref Environment, forms: seq[Object]): Object {.raises.} =
  result = nothing()
  for f in forms:
    result = eval(f, env)

proc eval*(obj: Object, env: ref Environment): Object {.raises.} =
  if isNumber(obj) or isBoolean(obj) or isNothing(obj) or isRecord(obj) or isString(obj):
    return obj
  if isSymbol(obj):
    let found = lookup(env, obj)
    if found.isSome:
      return found.get()
    err("unbound symbol: " & toSymbol(obj))
  if isPair(obj):
    let name = car(obj)
    if not isSymbol(name):
      err("a binding needs a symbol on the left of '='")
    let value = eval(cdr(obj), env)
    define(env, name, value)
    return value
  if isList(obj):
    let it = toSeq(obj)
    if it.len == 0:
      return nothing()
    var cmd = it[0]
    if isSymbol(cmd):
      let found = lookup(env, cmd)
      if found.isSome:
        cmd = found.get()
      else:
        err("unbound symbol: " & toSymbol(it[0]))
    else:
      cmd = eval(cmd, env)
    if not isCommand(cmd):
      err("the head of a call must be a command, got " & stringify(cmd))
    return apply(cmd, env, operandsOf(obj), bodyStartOf(obj))
  if isCommand(obj):
    err("cannot evaluate command " & cmdName(obj) & " directly, call it")
  result = nothing()

proc isDefinition*(f: Object, kw: string): bool =
  isList(f) and bodyStart(f) >= 2 and toSeq(f).len >= 3 and headSymbol(f) == kw and
    isSymbol(toSeq(f)[1])

proc makeDefinition*(env: ref Environment, f: Object, isFun: bool) =
  let it = toSeq(f)
  let bs = bodyStart(f)
  var params: seq[Object] = @[]
  for i in 2 ..< bs:
    params.add it[i]
  var body: seq[Object] = @[]
  for i in bs ..< it.len:
    body.add it[i]
  define(env, it[1], newCommand(toSymbol(it[1]), params, body, env, isFun))

proc runProgram*(env: ref Environment, forms: seq[Object]) {.raises.} =
  for f in forms:
    if isDefinition(f, "command"):
      makeDefinition(env, f, false)
  for f in forms:
    if isDefinition(f, "fun"):
      makeDefinition(env, f, true)
  var rest: seq[Object] = @[]
  for f in forms:
    if not isDefinition(f, "command") and not isDefinition(f, "fun"):
      rest.add f
  discard evalForms(env, rest)
