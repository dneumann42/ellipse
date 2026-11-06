import std/[syncio, strutils]
import owl/[objects, errors]


type
  OwlFailure* = object of ValueError
    ## Raised for every owl error; the details live in `currentError`.

  ErrorReporter* = proc (msg: string) {.gcsafe.}

proc defaultErrorReport*(msg: string) =
  writeLine(stderr, msg)

# The error being raised, and where reports go, belong to the thread: each
# thread runs its own interpreter, and its failures are its own. Thread
# variables start zeroed, so `nil` stands for the default reporter.
var errorReport* {.threadvar.}: ErrorReporter
  ## Where `reportError` sends a rendered error; `nil` writes to stderr.
var colorErrors* {.threadvar.}: bool
var currentError* {.threadvar.}: OwlError
var lastErrorMessage* {.threadvar.}: string

var culprit {.threadvar.}: Object
var hasCulprit {.threadvar.}: bool

proc setError(e: sink OwlError) =
  lastErrorMessage = e.message
  currentError = e
  hasCulprit = false

proc fail() {.noreturn.} =
  raise newException(OwlFailure, lastErrorMessage)

proc adoptForeign*() =
  ## Called first thing in an `except` that goes on to report: a Nim
  ## exception escaping a builtin (an IOError, a ValueError) becomes the
  ## current owl error, so its own message is reported rather than whatever
  ## failed last. Defects are bugs, not owl errors, and are never caught.
  let e = getCurrentException()
  if e != nil and not (e of OwlFailure):
    setError(owlError(RuntimeError, e.msg))

proc rethrow*() {.noreturn.} =
  ## Re-raise from an `except` as an owl failure.
  adoptForeign()
  fail()

proc raiseError*(e: OwlError) {.noreturn.} =
  setError(e)
  fail()

proc raiseError*(kind: ErrorKind, msg: string, at: Place) {.noreturn.} =
  setError(owlError(kind, msg, at))
  fail()

proc err*(msg: string) {.noreturn.} =
  setError(owlError(RuntimeError, msg))
  fail()

proc errAt*(at: Object, msg: string, kind: ErrorKind = RuntimeError) {.noreturn.} =
  ## Fail at `at`'s place. A value with no place of its own is remembered,
  ## so the call that holds it can point at it on the way out.
  setError(owlError(kind, msg, placeOf(at)))
  hasCulprit = not currentError.place.isKnown
  if hasCulprit:
    culprit = at
  fail()

proc errorText*(color: bool = false): string =
  renderError(currentError, color)

proc report*(msg: string) =
  ## Send `msg` to this thread's error reporter.
  let r = errorReport
  if r == nil:
    defaultErrorReport(msg)
  else:
    r(msg)

proc reportError*() =
  report(errorText(colorErrors))

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

proc eval*(obj: Object, env: ref Environment): Object {.gcsafe.}

proc numberIn*(env: ref Environment, form: Object, what: string): float64 =
  let v = eval(form, env)
  if not isNumber(v) and not isBoolean(v):
    errAt(form, what & " needs numbers, got " & stringify(v))
  toNumber(v)

proc numbersIn*(env: ref Environment, args: seq[Object], what: string): seq[float64] =
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

proc calleeName(cmd: Object): string =
  result = cmdName(cmd)
  if result.len == 0:
    result = "lambda"

proc makeShape(cmd: Object, withBlock: bool): CallShape =
  ## How a call binds `cmd`'s parameters, with or without a `:` block.
  ## `names[0 ..< fixed]` are filled by position, `defaults` fill what is
  ## still unbound afterwards, and a trailing `name+` (commands only) takes
  ## the arguments left over.
  var params = cmdParams(cmd)
  result = CallShape(names: @[], defaults: @[], fixed: 0, rest: nothing(),
    blockAt: blockParam(params), blockSym: nothing(), emptyBlock: false)
  var blockDefault = nothing()
  if result.blockAt >= 0:
    let p = params[result.blockAt]
    result.blockSym = blockName(p)
    params.delete(result.blockAt)
    if not withBlock:
      # With no block the `&name` parameter is an ordinary one, given by name
      # (or by position, unless a rest parameter takes those) or defaulted.
      if isPair(p):
        blockDefault = pair(result.blockSym, cdr(p))
      elif isFun(cmd):
        blockDefault = pair(result.blockSym, nothing())
      else:
        result.emptyBlock = true
  if not isFun(cmd) and params.len > 0:
    result.rest = restName(params[^1])
  let hasRest = not result.rest.isNothing
  if hasRest:
    params.setLen(params.len - 1)
  for p in params:
    result.names.add paramNameOrNothing(p)
    if isPair(p):
      result.defaults.add p
  if not blockDefault.isNothing:
    result.defaults.add blockDefault
    if not hasRest:
      result.names.add result.blockSym
  result.fixed = result.names.len

proc bindParams(cmd: Object, call: Object, allArgs: seq[Object], callerEnv: ref Environment,
    child: ref Environment, bodyStart: int)  =
  if not hasShapes(cmd):
    setShapes(cmd, makeShape(cmd, true), makeShape(cmd, false))
  let hasBlock = bodyStart >= 0 and bodyStart < allArgs.len
  let shape = shapeOf(cmd, hasBlock)
  let fun = isFun(cmd)
  let hygienic = not fun and not isDynamic(cmd)

  # What a parameter is bound to: a fun gets the value, a command the form
  # as syntax scoped to its caller, a dynamic command the bare form.
  template argument(form: Object, at: Place): Object =
    (if fun: eval(form, callerEnv)
     elif hygienic: syntaxAt(form, callerEnv, at)
     else: form)

  var argEnd = allArgs.len
  if shape.blockAt >= 0:
    if hasBlock:
      argEnd = bodyStart
      if fun:
        let forms = allArgs[bodyStart ..< allArgs.len]
        let blockFun = newCommand("", newSeq[Object](), forms, callerEnv, true)
        setOrigin(blockFun, call, bodyStart + 1)
        define(child, shape.blockSym, blockFun)
      else:
        var forms: seq[Object] = @[]
        for i in bodyStart ..< allArgs.len:
          forms.add (if hygienic: syntaxAt(allArgs[i], callerEnv, itemPlace(call, i + 1))
                     else: allArgs[i])
        define(child, shape.blockSym, list(forms))
    elif shape.emptyBlock:
      define(child, shape.blockSym, list(newSeq[Object]()))

  # Arguments are taken left to right. Named ones bind straight away, so
  # positional ones fill the parameters still open whatever order the call
  # wrote them in. Once the positional parameters are full, a rest
  # parameter takes everything else, named or not.
  let hasRest = not shape.rest.isNothing
  var given: seq[(int, Object)] = @[]
  var extras: seq[Object] = @[]
  for ai in 0 ..< argEnd:
    let a = allArgs[ai]
    if hasRest and given.len >= shape.fixed:
      extras.add argument(a, itemPlace(call, ai + 1))
    elif isPair(a) and isSymbol(carOf(a)):
      define(child, carOf(a), argument(cdrOf(a), valuePlace(a)))
    else:
      given.add (ai, argument(a, itemPlace(call, ai + 1)))
  var slot = 0
  for (ai, value) in given:
    while slot < shape.fixed and not isNothing(shape.names[slot]) and
        hasOwn(child, shape.names[slot]):
      inc slot
    if slot < shape.fixed:
      if isNothing(shape.names[slot]):
        err("a parameter of " & calleeName(cmd) &
          " must be a symbol or a (name = default) pair")
      define(child, shape.names[slot], value)
      inc slot
    elif hasRest:
      extras.add value
    else:
      errAt(allArgs[ai], "too many arguments for " & calleeName(cmd))
  if hasRest:
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
  for i in 0 ..< shape.fixed:
    if not hasOwn(child, shape.names[i]):
      errAt(call, "missing argument " & toSymbol(shape.names[i]) & " for " &
        calleeName(cmd))

proc apply(cmd: Object, call: Object, callerEnv: ref Environment, args: seq[Object],
    bodyStart: int): Object  =
  if isBuiltin(cmd):
    return builtinCall(cmd)(callerEnv, args, bodyStart)
  let upEnv = if isDynamic(cmd): callerEnv else: cmdEnv(cmd)
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
  except CatchableError:
    adoptForeign()
    placeError(bodyPlace(cmd, i))
    fail()

proc invoke*(cmd: Object, values: seq[Object]): Object =
  if not isCommand(cmd):
    err("cannot call " & stringify(cmd) & ", it is not a command")
  let scratch = newEnvironment()
  var args: seq[Object] = @[]
  for i in 0 ..< values.len:
    let name = symbol("arg" & $i)
    define(scratch, name, values[i])
    args.add name
  try:
    result = apply(cmd, nothing(), scratch, args, args.len)
  except CatchableError:
    rethrow()

proc evalForms*(env: ref Environment, forms: seq[Object]): Object =
  result = nothing()
  for f in forms:
    result = eval(f, env)

proc evalRange*(env: ref Environment, forms: seq[Object], a, b: int): Object =
  result = nothing()
  for i in a ..< b:
    result = eval(forms[i], env)

proc eval*(obj: Object, env: ref Environment): Object {.gcsafe.} =
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
    except CatchableError:
      adoptForeign()
      leaveCall(obj, cmd)
      fail()
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
    try:
      result = eval(formOf(obj), resolveScope(env, scope))
    except CatchableError:
      adoptForeign()
      placeError(placeOf(obj))
      fail()
  of Pair:
    try:
      result = eval(cdrOf(obj), env)
    except CatchableError:
      adoptForeign()
      if hasCulprit and sameValue(cdrOf(obj), culprit):
        placeError(valuePlace(obj))
      placeError(placeOf(obj))
      fail()
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

proc hoistDefinitions*(env: ref Environment, forms: seq[Object]) =
  ## Define every `fun`/`command`/`dynamic-command` in `forms` before
  ## anything runs, so a body may call a definition that comes later.
  for f in forms:
    if isDefinition(f, "fun"):
      makeDefinition(env, f, true)
    elif isCommandDefinition(f):
      makeCommandDefinition(env, f)

proc runProgram*(env: ref Environment, forms: seq[Object]) =
  hoistDefinitions(env, forms)
  for f in forms:
    if not isAnyDefinition(f):
      discard eval(f, env)
