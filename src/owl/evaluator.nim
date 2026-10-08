import std/[options, syncio, strutils]
import owl/[objects, errors]

# --- errors -------------------------------------------------------------------
#
# Reading, loading and running fail the same way: err (or errAt, raiseError)
# records an OwlError in currentError and raises. Bare raises carry no
# exception object, so currentError is how a handler learns what failed.
#
# Nothing is printed when the error is raised. On its way out the evaluator
# places it: the innermost call form read from a source that the error
# leaves sets where it happened (the item an errAt pointed at, else the
# whole call), and each command made in owl it then leaves adds a line to
# its trace. That costs nothing until something fails. Whoever handles the
# error last shows it: reportError hands the rendered window to errorReport.

proc defaultErrorReport*(msg: string) =
  writeLine(stderr, msg)

var errorReport*: proc(msg: string) = defaultErrorReport
# ANSI colors in reported errors (owl sets it when stderr is a terminal)
var colorErrors* = false

var currentError* = owlError(RuntimeError, "")
# currentError's message
var lastErrorMessage* = ""

# The form an errAt pointed at that has no place of its own (an atom): the
# call form holding it places the error at its item.
var culprit = nothing()
var hasCulprit = false

# Each raising proc ends in its own raise: a raising call as the last
# statement of a {.raises.} proc lost the error (nimony 0.6.2).
proc setError(e: sink OwlError) =
  lastErrorMessage = e.message
  currentError = e
  hasCulprit = false

proc raiseError*(e: OwlError) {.raises.} =
  ## Raise e as it is, its place and trace kept (a handler giving up on it).
  setError(e)
  raise ValueError

proc raiseError*(kind: ErrorKind, msg: string, at: Place) {.raises.} =
  setError(owlError(kind, msg, at))
  raise ValueError

proc err*(msg: string) {.raises.} =
  setError(owlError(RuntimeError, msg))
  raise ValueError

proc errAt*(at: Object, msg: string, kind: ErrorKind = RuntimeError) {.raises.} =
  ## err pointing at a form, such as the argument that is wrong: at its place
  ## when it has one, else at its item in the call form it is part of.
  currentError = owlError(kind, msg, placeOf(at))
  lastErrorMessage = msg
  hasCulprit = not currentError.place.isKnown
  if hasCulprit:
    culprit = at
  raise ValueError

proc errorText*(color: bool = false): string =
  ## currentError as an error window (see renderError).
  renderError(currentError, color)

proc reportError*() =
  ## Show currentError through errorReport: for the handler that ends it.
  errorReport(errorText(colorErrors))

proc sealError*() =
  ## The error leaves the code it is about (a module, a program run): the
  ## calls further out, such as owl's command line, stay out of its trace.
  currentError.sealed = true

proc placeError(p: Place) =
  if not currentError.place.isKnown and p.isKnown:
    currentError.place = p
    hasCulprit = false

proc leaveCall(form: Object, cmd: Object) =
  # An error leaves the call form: see "errors" above.
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

# numberIn env form what: the value of form as a number, as numbersIn
# checks it, for the builtins that fold numbers without gathering them.
proc numberIn*(env: ref Environment, form: Object, what: string): float64 {.raises.} =
  let v = eval(form, env)
  if not isNumber(v) and not isBoolean(v):
    errAt(form, what & " needs numbers, got " & stringify(v))
  toNumber(v)

proc numbersIn*(env: ref Environment, args: seq[Object], what: string): seq[float64] {.raises.} =
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

proc bindParams(cmd: Object, call: Object, allArgs: seq[Object], callerEnv: ref Environment,
    child: ref Environment, bodyStart: int) {.raises.} =
  # A fun gets its arguments' values. A command gets them unevaluated: as
  # syntax that remembers the caller's scope, or, for a dynamic-command, as
  # bare forms that its body evaluates in its own (the caller's) scope.
  #
  # A parameter written `&name` takes the forms of the call's `:` block. A
  # fun gets them as a closure over the caller's scope, (name) runs them;
  # a command gets the list of forms (syntax, for a hygienic one). Without
  # a block it can still be passed by name, or keeps its default.
  #
  # call is the call form (allArgs are its items after the head), for where
  # the arguments were written: syntax keeps it, a block fun its body's.
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
        # a default is written in the definition, so it belongs to it
        value = syntax(value, child)
      define(child, name, value)

proc apply(cmd: Object, call: Object, callerEnv: ref Environment, args: seq[Object],
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
  bindParams(cmd, call, args, callerEnv, child, bodyStart)
  result = nothing()
  var i = 0
  try:
    for f in bodyOf(cmd):
      result = eval(f, child)
      inc i
  except:
    # a body form that is a lone name places the error itself
    placeError(bodyPlace(cmd, i))
    raise ValueError

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
  apply(cmd, nothing(), scratch, args, args.len)

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
      raise ValueError
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
        # not placed inside the argument (a lone name, or code built at run
        # time): where the caller wrote it
        placeError(placeOf(obj))
        raise ValueError
  of Pair:
    try:
      result = eval(cdrOf(obj), env)
    except:
      if hasCulprit and sameValue(cdrOf(obj), culprit):
        placeError(valuePlace(obj))
      placeError(placeOf(obj))
      raise ValueError
    # A name that came in as syntax binds in the scope it was written in.
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
