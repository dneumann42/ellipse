import std/[options, syncio]
import owl/objects

proc err*(msg: string) {.raises.} =
  writeLine(stderr, "owl error: " & msg)
  raise ValueError

proc argsOf(o: Object): seq[Object] =
  let it = toSeq(o)
  let bs = bodyStart(o)
  result = @[]
  if it.len > 1:
    let stop = if bs >= 0 and bs < it.len: bs else: it.len
    for i in 1 ..< stop:
      result.add it[i]

proc bodyOf(o: Object): seq[Object] =
  result = @[]
  let it = toSeq(o)
  let bs = bodyStart(o)
  if bs >= 0 and bs < it.len:
    for i in bs ..< it.len:
      result.add it[i]

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

proc bindParams(cmd: Object, argObjs: seq[Object], callerEnv: ref Environment,
    child: ref Environment) {.raises.} =
  let params = cmdParams(cmd)
  var pos = 0
  for a in argObjs:
    var name = a
    var value = a
    if isPair(a) and isSymbol(car(a)):
      name = car(a)
      value = cdr(a)
      if isFun(cmd):
        value = eval(value, callerEnv)
    else:
      if pos >= params.len:
        err("too many arguments for " & cmdName(cmd))
      name = paramName(params[pos])
      inc pos
      if isFun(cmd):
        value = eval(value, callerEnv)
    define(child, name, value)
  for p in params:
    if isPair(p):
      let name = car(p)
      if not hasOwn(child, name):
        var value = cdr(p)
        if isFun(cmd):
          value = eval(value, child)
        define(child, name, value)

proc apply(cmd: Object, callerEnv: ref Environment, args, body: seq[Object]): Object {.raises.} =
  if isBuiltin(cmd):
    let call = builtinCall(cmd)
    if call == nil:
      err("builtin " & cmdName(cmd) & " has no implementation")
    return call(callerEnv, args, body)
  var allArgs = args
  for b in body:
    allArgs.add b
  let upEnv = if isFun(cmd): cmdEnv(cmd) else: callerEnv
  let child = newEnvironment(upEnv)
  bindParams(cmd, allArgs, callerEnv, child)
  evalForms(child, cmdBody(cmd))

proc evalForms*(env: ref Environment, forms: seq[Object]): Object {.raises.} =
  result = nothing()
  for f in forms:
    result = eval(f, env)

proc eval*(obj: Object, env: ref Environment): Object {.raises.} =
  if isNumber(obj) or isBoolean(obj) or isNothing(obj):
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
    return apply(cmd, env, argsOf(obj), bodyOf(obj))
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
