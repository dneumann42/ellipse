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

proc bodyStartOf(o: Object): int =
  let n = itemCount(o)
  let bs = bodyStart(o)
  result = if bs >= 1 and bs < n: bs - 1 else: max(n - 1, 0)

# numberIn env form what: the value of form as a number, as numbersIn
# checks it, for the builtins that fold numbers without gathering them.
proc numberIn*(env: ref Environment, form: Object, what: string): float64 {.raises.} =
  let v = eval(form, env)
  if not isNumber(v) and not isBoolean(v):
    err(what & " needs numbers, got " & stringify(v))
  toNumber(v)

proc numbersIn*(env: ref Environment, args: seq[Object], what: string): seq[float64] {.raises.} =
  result = @[]
  for a in args:
    let v = eval(a, env)
    if not isNumber(v) and not isBoolean(v):
      err(what & " needs numbers, got " & stringify(v))
    result.add toNumber(v)

proc headSymbol(o: Object): string =
  result = ""
  if itemCount(o) > 0:
    result = toSymbol(headOf(o))

proc paramNameOrNothing(p: Object): Object =
  result = p
  if isPair(p):
    result = car(p)
  if not isSymbol(result):
    result = nothing()

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

proc makeShape(cmd: Object, withBlock: bool): CallShape =
  # What bindParams binds for a call of cmd with or without a `:` block.
  var params = cmdParams(cmd)
  result = CallShape(names: @[], defaults: @[], fixed: 0,
    rest: nothing(), blockAt: blockParam(params), blockSym: nothing(), emptyBlock: false)
  if result.blockAt >= 0:
    let blockAt = result.blockAt
    result.blockSym = blockName(params[blockAt])
    let blockDefault = params[blockAt]
    var kept: seq[Object] = @[]
    for i in 0 ..< params.len:
      if i != blockAt:
        kept.add params[i]
    params = kept
    if not withBlock:
      if isPair(blockDefault):
        params.add pair(result.blockSym, cdr(blockDefault))
      elif isFun(cmd):
        params.add pair(result.blockSym, symbol("nothing"))
      else:
        result.emptyBlock = true
  result.fixed = params.len
  if not isFun(cmd) and params.len > 0:
    result.rest = restName(params[^1])
    if not result.rest.isNothing:
      result.fixed = params.len - 1
  for p in params:
    result.names.add paramNameOrNothing(p)
    if isPair(p):
      result.defaults.add p

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
  if not hasShapes(cmd):
    setShapes(cmd, makeShape(cmd, true), makeShape(cmd, false))
  let hasBlock = bodyStart >= 0 and bodyStart < allArgs.len
  let shape = shapeOf(cmd, hasBlock)
  var argEnd = allArgs.len
  if shape.blockAt >= 0:
    if hasBlock:
      argEnd = bodyStart
      if isFun(cmd):
        let forms = allArgs[bodyStart ..< allArgs.len]
        define(child, shape.blockSym, newCommand("", newSeq[Object](), forms, callerEnv, true))
      elif not isDynamic(cmd):
        var wrapped: seq[Object] = @[]
        for i in bodyStart ..< allArgs.len:
          wrapped.add syntax(allArgs[i], callerEnv)
        define(child, shape.blockSym, list(wrapped))
      else:
        let forms = allArgs[bodyStart ..< allArgs.len]
        define(child, shape.blockSym, list(forms))
    elif shape.emptyBlock:
      define(child, shape.blockSym, list(newSeq[Object]()))
  let hygienic = not isFun(cmd) and not isDynamic(cmd)
  let fun = isFun(cmd)
  let hasRest = not shape.rest.isNothing
  var pos = 0
  var extras: seq[Object] = @[]
  for ai in 0 ..< argEnd:
    let a = allArgs[ai]
    if hasRest and pos >= shape.fixed:
      extras.add a
      continue
    if isPair(a) and isSymbol(carOf(a)):
      if fun:
        define(child, carOf(a), eval(cdrOf(a), callerEnv))
      elif hygienic:
        define(child, carOf(a), syntax(cdrOf(a), callerEnv))
      else:
        define(child, carOf(a), cdrOf(a))
    else:
      if pos < shape.fixed:
        let name = shape.names[pos]
        if isNothing(name):
          err("a parameter must be a symbol or a (name = default) pair")
        inc pos
        if fun:
          define(child, name, eval(a, callerEnv))
        elif hygienic:
          define(child, name, syntax(a, callerEnv))
        else:
          define(child, name, a)
      elif not hasRest:
        err("too many arguments for " & cmdName(cmd))
      else:
        extras.add a
  if hasRest:
    if hygienic:
      var wrapped: seq[Object] = @[]
      for x in extras:
        wrapped.add syntax(x, callerEnv)
      define(child, shape.rest, list(wrapped))
    else:
      define(child, shape.rest, list(extras))
  for p in shape.defaults:
    let name = car(p)
    if not hasOwn(child, name):
      var value = cdr(p)
      if fun:
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
  result = nothing()
  for f in bodyOf(cmd):
    result = eval(f, child)

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

# evalRange env forms a b is evalForms env forms[a ..< b], without the copy.
proc evalRange*(env: ref Environment, forms: seq[Object], a, b: int): Object {.raises.} =
  result = nothing()
  for i in a ..< b:
    result = eval(forms[i], env)

proc eval*(obj: Object, env: ref Environment): Object {.raises.} =
  case objectKind(obj)
  of List:
    if itemCount(obj) == 0:
      return nothing()
    var cmd = nothing()
    if isSymbol(headOf(obj)):
      var found = false
      cmd = getVar(env, headOf(obj), found)
      if not found:
        err("unbound symbol: " & toSymbol(headOf(obj)))
    else:
      cmd = eval(headOf(obj), env)
    if not isCommand(cmd):
      err("the head of a call must be a command, got " & stringify(cmd))
    result = apply(cmd, env, operands(obj), bodyStartOf(obj))
  of Symbol:
    var found = false
    result = getVar(env, obj, found)
    if not found:
      err("unbound symbol: " & toSymbol(obj))
  of Number, Boolean, Nothing, Record, String:
    result = obj
  of Syntax:
    let scope = syntaxScope(obj)
    if scope == nil:
      err("syntax without a scope: " & stringify(obj))
      result = nothing()
    else:
      result = eval(formOf(obj), resolveScope(env, scope))
  of Pair:
    result = eval(cdrOf(obj), env)
    # A name that came in as syntax binds in the scope it was written in.
    if isSyntax(carOf(obj)):
      let scope = syntaxScope(carOf(obj))
      if scope != nil:
        if isSymbol(formOf(carOf(obj))):
          define(resolveScope(env, scope), formOf(carOf(obj)), result)
          return
    if not isSymbol(carOf(obj)):
      err("a binding needs a symbol on the left of '='")
    define(env, carOf(obj), result)
  of Command:
    err("cannot evaluate command " & cmdName(obj) & " directly, call it")
    result = nothing()
  of Scope:
    result = nothing()

proc isDefinition*(f: Object, kw: string): bool =
  isList(f) and bodyStart(f) >= 2 and itemCount(f) >= 3 and headSymbol(f) == kw and
    isSymbol(itemAt(f, 1))

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
