import std/[options, syncio, strutils]
import owl/objects

proc defaultErrorReport*(msg: string) =
  writeLine(stderr, "owl error: " & msg)

var errorReport*: proc(msg: string) = defaultErrorReport

# The message of the most recent err(); bare raises carry no exception object,
# so this is how a handler (the `try` builtin) learns why evaluation failed.
var lastErrorMessage* = ""

proc err*(msg: string) {.raises.} =
  lastErrorMessage = msg
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

proc blockParam(params: seq[Object]): int =
  # The position of the parameter written `&name`, which takes the call's
  # `:` block, or -1.
  result = -1
  for i in 0 ..< params.len:
    var name = params[i]
    if isPair(name):
      name = car(name)
    let text = toSymbol(name)
    if text.len > 1 and text[0] == '&':
      return i

proc blockName(p: Object): Object =
  var name = p
  if isPair(p):
    name = car(p)
  symbol(toSymbol(name)[1 ..< toSymbol(name).len])

proc bindParams(cmd: Object, allArgs: seq[Object], callerEnv: ref Environment,
    child: ref Environment, bodyStart: int) {.raises.} =
  # A fun gets its arguments' values. A command gets them unevaluated: as
  # syntax that remembers the caller's scope, or, for a dynamic-command, as
  # bare forms that its body evaluates in its own (the caller's) scope.
  #
  # A parameter written `&name` takes the forms of the call's `:` block. A
  # fun gets them as a closure over the caller's scope, (name) runs them;
  # a command gets the list of forms (syntax, for a hygienic one). Without
  # a block it can still be passed by name, or keeps its default.
  var params = cmdParams(cmd)
  var argObjs = allArgs
  let blockAt = blockParam(params)
  if blockAt >= 0:
    let blockSym = blockName(params[blockAt])
    let blockDefault = params[blockAt]
    var kept: seq[Object] = @[]
    for i in 0 ..< params.len:
      if i != blockAt:
        kept.add params[i]
    params = kept
    if bodyStart >= 0 and bodyStart < allArgs.len:
      argObjs = allArgs[0 ..< bodyStart]
      let forms = allArgs[bodyStart ..< allArgs.len]
      if isFun(cmd):
        define(child, blockSym, newCommand("", @[], forms, callerEnv, true))
      elif not isDynamic(cmd):
        var wrapped: seq[Object] = @[]
        for x in forms:
          wrapped.add syntax(x, callerEnv)
        define(child, blockSym, list(wrapped))
      else:
        define(child, blockSym, list(forms))
    elif isPair(blockDefault):
      params.add pair(blockSym, cdr(blockDefault))
    elif isFun(cmd):
      params.add pair(blockSym, symbol("nothing"))
    else:
      define(child, blockSym, list(@[]))
  let hygienic = not isFun(cmd) and not isDynamic(cmd)
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
      elif hygienic:
        value = syntax(value, callerEnv)
    else:
      if pos < fixed:
        name = paramName(params[pos])
        inc pos
        if isFun(cmd):
          value = eval(value, callerEnv)
        elif hygienic:
          value = syntax(value, callerEnv)
      elif rest.isNothing:
        err("too many arguments for " & cmdName(cmd))
      else:
        extras.add a
        continue
    define(child, name, value)
  if not rest.isNothing:
    if hygienic:
      var wrapped: seq[Object] = @[]
      for x in extras:
        wrapped.add syntax(x, callerEnv)
      define(child, rest, list(wrapped))
    else:
      define(child, rest, list(extras))
  for p in params:
    if isPair(p):
      let name = car(p)
      if not hasOwn(child, name):
        var value = cdr(p)
        if isFun(cmd):
          value = eval(value, child)
        elif hygienic:
          # a default is written in the definition, so it belongs to it
          value = syntax(value, child)
        define(child, name, value)

proc apply(cmd: Object, callerEnv: ref Environment, args: seq[Object],
    bodyStart: int): Object {.raises.} =
  if isBuiltin(cmd):
    let call = builtinCall(cmd)
    if call == nil:
      err("builtin " & cmdName(cmd) & " has no implementation")
    return call(callerEnv, args, bodyStart)
  # Only a dynamic-command runs inside the caller's scope; funs and commands
  # run in the scope they were defined in, so their names never meet the
  # caller's.
  var upEnv: nil ref Environment = cmdEnv(cmd)
  if isDynamic(cmd):
    upEnv = callerEnv
  let child = newEnvironment(upEnv)
  if not isFun(cmd) and not isDynamic(cmd):
    setCaller(child, callerEnv)
  bindParams(cmd, args, callerEnv, child, bodyStart)
  evalForms(child, cmdBody(cmd))

proc invoke*(cmd: Object, values: seq[Object]): Object {.raises.} =
  ## Call a command value from Nim with already evaluated arguments: each
  ## one is reached through a name in a scratch scope, so a fun sees the
  ## values as they are (a list is not run as a call).
  if not isCommand(cmd):
    err("cannot call " & stringify(cmd) & ", it is not a command")
  let scratch = newEnvironment()
  var args: seq[Object] = @[]
  for i in 0 ..< values.len:
    let name = symbol("arg" & $i)
    define(scratch, name, values[i])
    args.add name
  apply(cmd, scratch, args, args.len)

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
  if isSyntax(obj):
    let scope = syntaxScope(obj)
    if scope == nil:
      err("syntax without a scope: " & stringify(obj))
    else:
      return eval(syntaxForm(obj), resolveScope(env, scope))
  if isPair(obj):
    let name = car(obj)
    let value = eval(cdr(obj), env)
    # A name that came in as syntax binds in the scope it was written in.
    let scope = syntaxScope(name)
    if scope != nil:
      if isSymbol(syntaxForm(name)):
        define(resolveScope(env, scope), syntaxForm(name), value)
        return value
    if not isSymbol(name):
      err("a binding needs a symbol on the left of '='")
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

proc makeDefinition*(env: ref Environment, f: Object, isFun: bool,
    dynamic: bool = false) =
  let it = toSeq(f)
  let bs = bodyStart(f)
  var params: seq[Object] = @[]
  for i in 2 ..< bs:
    params.add it[i]
  var body: seq[Object] = @[]
  for i in bs ..< it.len:
    body.add it[i]
  define(env, it[1], newCommand(toSymbol(it[1]), params, body, env, isFun, dynamic))

proc isCommandDefinition*(f: Object): bool =
  isDefinition(f, "command") or isDefinition(f, "dynamic-command")

proc isAnyDefinition*(f: Object): bool =
  isCommandDefinition(f) or isDefinition(f, "fun")

proc makeCommandDefinition*(env: ref Environment, f: Object) =
  makeDefinition(env, f, false, isDefinition(f, "dynamic-command"))

proc runProgram*(env: ref Environment, forms: seq[Object]) {.raises.} =
  for f in forms:
    if isCommandDefinition(f):
      makeCommandDefinition(env, f)
  for f in forms:
    if isDefinition(f, "fun"):
      makeDefinition(env, f, true)
  var rest: seq[Object] = @[]
  for f in forms:
    if not isAnyDefinition(f):
      rest.add f
  discard evalForms(env, rest)
