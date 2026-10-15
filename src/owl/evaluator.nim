import std/[options, syncio, strutils]
import owl/[objects, errors]


proc defaultErrorReport*(msg: string) =
  writeLine(stderr, msg)

var errorReport*: proc(msg: string) = defaultErrorReport
var colorErrors* = false

var currentError* = owlError(RuntimeError, "")
var lastErrorMessage* = ""

var culprit = nothing()
var hasCulprit = false

proc setError(e: sink OwlError) =
  lastErrorMessage = e.message
  currentError = e
  hasCulprit = false

proc raiseError*(e: OwlError)  =
  setError(e)
  raise newException(ValueError, lastErrorMessage)

proc raiseError*(kind: ErrorKind, msg: string, at: Place)  =
  setError(owlError(kind, msg, at))
  raise newException(ValueError, lastErrorMessage)

proc err*(msg: string)  =
  setError(owlError(RuntimeError, msg))
  raise newException(ValueError, lastErrorMessage)

proc errAt*(at: Object, msg: string, kind: ErrorKind = RuntimeError)  =
  currentError = owlError(kind, msg, placeOf(at))
  lastErrorMessage = msg
  hasCulprit = not currentError.place.isKnown
  if hasCulprit:
    culprit = at
  raise newException(ValueError, lastErrorMessage)

proc errorText*(color: bool = false): string =
  renderError(currentError, color)

proc reportError*() =
  errorReport(errorText(colorErrors))

proc sealError*() =
  currentError.sealed = true

proc placeError(p: Place) =
  if not currentError.place.isKnown and p.isKnown:
    currentError.place = p
    hasCulprit = false

proc leaveCall(form: Object, cmd: Object) =
  if not currentError.place.isKnown:
    if hasCulprit:
      let i = findItem(form, culprit)
      if i >= 0:
        placeError(itemPlace(form, i))
    placeError(placeOf(form))
  elif isCommand(cmd) and not isBuiltin(cmd) and not currentError.sealed and
      currentError.trace.len < MaxTrace:
    let p = placeOf(form)
    if p.isKnown:
      currentError.trace.add TraceFrame(name: cmdName(cmd), place: p)

proc bodyStartOf(o: Object): int =
  let n = itemCount(o)
  let bs = bodyStart(o)
  result = if bs >= 1 and bs < n: bs - 1 else: max(n - 1, 0)

proc eval*(obj: Object, env: ref Environment): Object

proc numberIn*(env: ref Environment, form: Object, what: string): float64  =
  let v = eval(form, env)
  if not isNumber(v) and not isBoolean(v):
    errAt(form, what & " needs numbers, got " & stringify(v))
  toNumber(v)

proc numbersIn*(env: ref Environment, args: seq[Object], what: string): seq[float64]  =
  result = @[]
  for a in args:
    let v = eval(a, env)
    if not isNumber(v) and not isBoolean(v):
      errAt(a, what & " needs numbers, got " & stringify(v))
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
  result = nothing()
  var name = p
  if isPair(p):
    name = car(p)
  if isSymbol(name):
    let text = toSymbol(name)
    if text.len > 1 and text.endsWith("+"):
      result = symbol(text[0 ..< text.len - 1])

proc blockParam(params: seq[Object]): int =
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

proc bindParams(cmd: Object, call: Object, allArgs: seq[Object], callerEnv: ref Environment,
    child: ref Environment, bodyStart: int)  =
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
        let blockFun = newCommand("", newSeq[Object](), forms, callerEnv, true)
        setOrigin(blockFun, call, bodyStart + 1)
        define(child, shape.blockSym, blockFun)
      elif not isDynamic(cmd):
        var wrapped: seq[Object] = @[]
        for i in bodyStart ..< allArgs.len:
          wrapped.add syntaxAt(allArgs[i], callerEnv, itemPlace(call, i + 1))
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
        define(child, carOf(a), syntaxAt(cdrOf(a), callerEnv, valuePlace(a)))
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
          define(child, name, syntaxAt(a, callerEnv, itemPlace(call, ai + 1)))
        else:
          define(child, name, a)
      elif not hasRest:
        errAt(a, "too many arguments for " & cmdName(cmd))
      else:
        extras.add a
  if hasRest:
    if hygienic:
      var wrapped: seq[Object] = @[]
      for x in extras:
        wrapped.add syntaxAt(x, callerEnv, itemPlace(call, findItem(call, x)))
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
        value = syntax(value, child)
      define(child, name, value)

proc apply(cmd: Object, call: Object, callerEnv: ref Environment, args: seq[Object],
    bodyStart: int): Object  =
  if isBuiltin(cmd):
    let call = builtinCall(cmd)
    if call == nil:
      err("builtin " & cmdName(cmd) & " has no implementation")
    return call(callerEnv, args, bodyStart)
  var upEnv: ref Environment = cmdEnv(cmd)
  if isDynamic(cmd):
    upEnv = callerEnv
  let child = newEnvironment(upEnv)
  if not isFun(cmd) and not isDynamic(cmd):
    setCaller(child, callerEnv)
  bindParams(cmd, call, args, callerEnv, child, bodyStart)
  result = nothing()
  var i = 0
  try:
    for f in bodyOf(cmd):
      result = eval(f, child)
      inc i
  except:
    placeError(bodyPlace(cmd, i))
    raise newException(ValueError, lastErrorMessage)

proc invoke*(cmd: Object, values: seq[Object]): Object  =
  if not isCommand(cmd):
    err("cannot call " & stringify(cmd) & ", it is not a command")
  let scratch = newEnvironment()
  var args: seq[Object] = @[]
  for i in 0 ..< values.len:
    let name = symbol("arg" & $i)
    define(scratch, name, values[i])
    args.add name
  apply(cmd, nothing(), scratch, args, args.len)

proc evalForms*(env: ref Environment, forms: seq[Object]): Object  =
  result = nothing()
  for f in forms:
    result = eval(f, env)

proc evalRange*(env: ref Environment, forms: seq[Object], a, b: int): Object  =
  result = nothing()
  for i in a ..< b:
    result = eval(forms[i], env)

proc eval*(obj: Object, env: ref Environment): Object  =
  case objectKind(obj)
  of List:
    if itemCount(obj) == 0:
      return nothing()
    var cmd = nothing()
    try:
      if isSymbol(headOf(obj)):
        var found = false
        cmd = getVar(env, headOf(obj), found)
        if not found:
          errAt(headOf(obj), "unbound symbol: " & toSymbol(headOf(obj)))
      else:
        cmd = eval(headOf(obj), env)
      if not isCommand(cmd):
        errAt(headOf(obj), "the head of a call must be a command, got " & stringify(cmd))
      result = apply(cmd, obj, env, operands(obj), bodyStartOf(obj))
    except:
      leaveCall(obj, cmd)
      raise newException(ValueError, lastErrorMessage)
  of Symbol:
    var found = false
    result = getVar(env, obj, found)
    if not found:
      errAt(obj, "unbound symbol: " & toSymbol(obj))
  of Number, Boolean, Nothing, Record, String:
    result = obj
  of Syntax:
    let scope = syntaxScope(obj)
    if scope == nil:
      err("syntax without a scope: " & stringify(obj))
      result = nothing()
    else:
      try:
        result = eval(formOf(obj), resolveScope(env, scope))
      except:
        placeError(placeOf(obj))
        raise newException(ValueError, lastErrorMessage)
  of Pair:
    try:
      result = eval(cdrOf(obj), env)
    except:
      if hasCulprit and sameValue(cdrOf(obj), culprit):
        placeError(valuePlace(obj))
      placeError(placeOf(obj))
      raise newException(ValueError, lastErrorMessage)
    if isSyntax(carOf(obj)):
      let scope = syntaxScope(carOf(obj))
      if scope != nil:
        if isSymbol(formOf(carOf(obj))):
          define(resolveScope(env, scope), formOf(carOf(obj)), result)
          return
    if not isSymbol(carOf(obj)):
      errAt(obj, "a binding needs a symbol on the left of '='")
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
  let cmd = newCommand(toSymbol(it[1]), params, body, env, isFun, dynamic)
  setOrigin(cmd, f, bs)
  define(env, it[1], cmd)

proc isCommandDefinition*(f: Object): bool =
  isDefinition(f, "command") or isDefinition(f, "dynamic-command")

proc isAnyDefinition*(f: Object): bool =
  isCommandDefinition(f) or isDefinition(f, "fun")

proc makeCommandDefinition*(env: ref Environment, f: Object) =
  makeDefinition(env, f, false, isDefinition(f, "dynamic-command"))

proc runProgram*(env: ref Environment, forms: seq[Object])  =
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
