import std/[cmdline, options, strutils]
import owl/[objects, evaluator, reader, modules]

# Compile-time file embedding via a Nimony template plugin (see deps/embedFile.nim).
template embedFile(path: string): string {.plugin: "deps/embedFile".}

proc quoteBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  if args.len == 0:
    err("quote needs one argument")
  args[0]

proc evalBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  if args.len == 0:
    err("eval needs one argument")
  let syntax = eval(args[0], env)
  eval(syntax, env)

proc parseBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  if args.len != 1:
    err("parse needs one string")
  let source = eval(args[0], env)
  if not isString(source):
    err("parse needs a string, got " & stringify(source))
  let parsed = parseOwl(toStr(source))
  if not parsed.isOk:
    err("parse error: " & parsed.error("unknown"))
  list(parsed.get(@[]))

proc charBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # char 27 gives the one-character string with that byte, for the control
  # characters that owl string literals cannot spell.
  if args.len != 1:
    err("char needs one number")
  let code = eval(args[0], env)
  if not isNumber(code):
    err("char needs a number, got " & stringify(code))
  let n = toNumber(code)
  if n < 0.0 or n > 255.0 or n != float64(int64(n)):
    err("char needs a whole number from 0 to 255, got " & stringify(code))
  var s = " "
  s[0] = char(int(n))
  str(s)

proc wholeArg(env: ref Environment, form: Object, what: string): int {.raises.} =
  let v = eval(form, env)
  if not isNumber(v) or toNumber(v) != float64(int64(toNumber(v))):
    err(what & " needs a whole number, got " & stringify(v))
  int(toNumber(v))

proc sliceBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # slice x from (to) copies x[from ..< to] of a string or list; to defaults
  # to the end. Both ends are clamped into range.
  if args.len < 2 or args.len > 3:
    err("slice needs a string or list, a start and an optional end")
  let x = eval(args[0], env)
  if not isString(x) and not isList(x):
    err("slice needs a string or list, got " & stringify(x))
  let n = if isString(x): toStr(x).len else: toSeq(x).len
  var a = wholeArg(env, args[1], "slice")
  var b = if args.len == 3: wholeArg(env, args[2], "slice") else: n
  a = max(0, min(a, n))
  b = max(a, min(b, n))
  if isString(x):
    result = str(toStr(x)[a ..< b])
  else:
    let items = toSeq(x)
    var part: seq[Object] = @[]
    for i in a ..< b:
      part.add items[i]
    result = list(part)

proc findBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # find s needle (start) gives the position of needle in s at or after start,
  # or nothing when it does not occur.
  if args.len < 2 or args.len > 3:
    err("find needs a string, a needle and an optional start")
  let s = eval(args[0], env)
  let needle = eval(args[1], env)
  if not isString(s) or not isString(needle):
    err("find needs strings, got " & stringify(s) & " and " & stringify(needle))
  let start = if args.len == 3: wholeArg(env, args[2], "find") else: 0
  let at = find(toStr(s), toStr(needle), max(start, 0))
  if at < 0:
    result = nothing()
  else:
    result = number(float64(at))

proc codeBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # code s (at) gives the byte at position at (default 0) as a number.
  if args.len < 1 or args.len > 2:
    err("code needs a string and an optional position")
  let s = eval(args[0], env)
  if not isString(s):
    err("code needs a string, got " & stringify(s))
  let at = if args.len == 2: wholeArg(env, args[1], "code") else: 0
  if at < 0 or at >= toStr(s).len:
    err("code position out of range: " & $at)
  number(float64(ord(toStr(s)[at])))

proc toStringBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  if args.len != 1:
    err("to-string needs one argument")
  str(stringify(eval(args[0], env)))

proc toCodeBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # to-code value (width) writes value as owl code that reads back as it,
  # broken into blocks where it would pass width columns (default 80).
  if args.len < 1 or args.len > 2:
    err("to-code needs a value and an optional width")
  let value = eval(args[0], env)
  var width = 80
  if args.len == 2:
    width = wholeArg(env, args[1], "to-code")
  str(toCode(value, max(width, 20)))

proc typeOfBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # type-of x names the kind of value: "number", "string", "symbol", "list",
  # "pair", "record", "command", ... Code that reads code (see source.owl)
  # needs it to tell a binding from a call.
  if args.len != 1:
    err("type-of needs one argument")
  str(kindName(eval(args[0], env)))

proc bodyStartBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # body-start form gives the position where a parsed form's ':' block begins,
  # or nothing when it has no block.
  if args.len != 1:
    err("body-start needs one form")
  let at = bodyStart(eval(args[0], env))
  if at < 0:
    result = nothing()
  else:
    result = number(float64(at))

proc syntaxFormBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # syntax-form x: the code a command argument was written as. A command
  # that rewrites code (see `widget` in gui.owl) reads its arguments so.
  if args.len != 1:
    err("syntax-form needs one argument")
  let v = eval(args[0], env)
  result = if isSyntax(v): syntaxForm(v) else: v

proc syntaxScopeBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # syntax-scope x: the scope a command argument was written in, for
  # eval-in and make-definition.
  if args.len != 1:
    err("syntax-scope needs one argument")
  let v = eval(args[0], env)
  let scope = syntaxScope(v)
  if scope == nil:
    err("syntax-scope needs a command argument, got " & stringify(v))
    result = nothing()
  else:
    result = scopeValue(scope)

proc withBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # with r (name = value)...: r with those fields replaced, or added when r
  # has none of that name. Records are values; this gives a new one.
  if args.len < 1:
    err("with needs a record")
  let r = eval(args[0], env)
  if not isRecord(r):
    err("with needs a record, got " & stringify(r))
  var fields = recordFields(r)
  for i in 1 ..< args.len:
    let f = args[i]
    if not isPair(f) or not isSymbol(car(f)):
      err("with needs (name = value) changes")
    let value = eval(cdr(f), env)
    var found = false
    for j in 0 ..< fields.len:
      if car(fields[j]) == car(f):
        fields[j] = pair(car(f), value)
        found = true
    if not found:
      fields.add pair(car(f), value)
  record(fields)

proc silentReport(msg: string) =
  discard

proc blockScope(env: ref Environment): ref Environment =
  # Every block (do, if, when, while, cond and try bodies) runs in its own
  # scope: what it defines ends with it, while set still reaches outer names.
  newEnvironment(env)

proc callerBlockScope(env: ref Environment): ref Environment =
  # A do inside a command also opens a scope on the caller's side, a fresh
  # child of the caller's scope, where the command's syntax arguments
  # evaluate and bind while the block runs. That is how `for` gives each pass
  # its own loop variable. Other blocks leave the caller's side alone, so a
  # command's own loops and branches never split its caller's code apart.
  result = newEnvironment(env)
  let caller = commandCaller(env)
  if caller != nil:
    setRedirect(result, caller, newEnvironment(resolveScope(env, caller)))

proc tryBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # try expr...: handler... evaluates the forms before the block. If one fails,
  # the error is not reported; the handler block runs instead, with `failure`
  # bound to the message. A lone `try expr` gives nothing on failure.
  if args.len == 0:
    err("try needs something to evaluate")
  let attempt = if bodyStart >= 1 and bodyStart < args.len: bodyStart else: args.len
  let saved = errorReport
  errorReport = silentReport
  var failed = false
  result = nothing()
  try:
    result = evalRange(env, args, 0, attempt)
  except:
    failed = true
  errorReport = saved
  if failed:
    let child = blockScope(env)
    define(child, symbol("failure"), str(lastErrorMessage))
    result = evalRange(child, args, attempt, args.len)

proc ifBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  if args.len == 0:
    err("if needs a condition")
  if bodyStart >= args.len:
    err("if needs at least one body form")
  if toBool(eval(args[0], env)):
    eval(args[bodyStart], blockScope(env))
  else:
    evalRange(blockScope(env), args, bodyStart + 1, args.len)

proc doBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  let scope = callerBlockScope(env)
  result = nothing()
  for form in args:
    result = eval(form, scope)

proc whileBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  if args.len == 0:
    err("while needs a condition")
  if bodyStart >= args.len:
    err("while needs at least one body form")
  # each pass gets a fresh scope
  while toBool(eval(args[0], env)):
    discard evalRange(blockScope(env), args, bodyStart, args.len)
  nothing()

proc whenBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  if args.len == 0:
    err("when needs a condition")
  if bodyStart >= args.len:
    err("when needs at least one body form")
  if toBool(eval(args[0], env)):
    evalRange(blockScope(env), args, bodyStart, args.len)
  else:
    nothing()

proc condBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # Each argument is an unevaluated pair (test = body). The test is either a raw
  # symbol (evaluated as a value, e.g. 'true' for the else branch) or a grouped
  # call kept syntactically by the reader. The first truthy test runs its body.
  result = nothing()
  for form in args:
    if not isPair(form):
      err("cond needs (test = body) pairs")
    if toBool(eval(car(form), env)):
      return eval(cdr(form), blockScope(env))

proc concatBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  if args.len == 0:
    err("concat needs at least one argument")
  let first = eval(args[0], env)
  if isString(first):
    var joined = toStr(first)
    for i in 1 ..< args.len:
      let v = eval(args[i], env)
      if not isString(v):
        err("concat mixes a string with " & stringify(v))
      joined.add toStr(v)
    result = str(joined)
  elif isList(first):
    var joined = toSeq(first)
    for i in 1 ..< args.len:
      let v = eval(args[i], env)
      if not isList(v):
        err("concat mixes a list with " & stringify(v))
      for x in toSeq(v):
        joined.add x
    result = list(joined)
  elif isRecord(first):
    var joined = recordFields(first)
    for i in 1 ..< args.len:
      let v = eval(args[i], env)
      if not isRecord(v):
        err("concat mixes a record with " & stringify(v))
      for x in recordFields(v):
        joined.add x
    result = record(joined)
  else:
    err("concat needs strings, lists or records, got " & stringify(first))
    result = nothing()

proc errorBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  var parts: seq[string] = @[]
  for a in args:
    parts.add stringify(eval(a, env))
  err(parts.join(" "))

proc setBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  if args.len != 2:
    err("set needs a name and a value")
  var key = args[0]
  if not isSymbol(key):
    key = eval(key, env)
  if not isSymbol(key):
    err("set needs a symbol name, got " & stringify(key))
  let value = eval(args[1], env)
  if not assign(env, key, value):
    err("set on an unbound symbol: " & toSymbol(key))
  value

proc pairBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  if args.len != 2:
    err("pair needs a name and a value")
  var key = args[0]
  if not isSymbol(key):
    key = eval(key, env)
  if not isSymbol(key) and not isSymbol(syntaxForm(key)):
    err("pair needs a symbol name, got " & stringify(key))
  pair(key, eval(args[1], env))

proc ordered(env: ref Environment, args: seq[Object], ascending: bool): Object {.raises.} =
  # Every argument is evaluated (and checked) before the answer is known.
  var ok = true
  var previous = 0.0
  for i in 0 ..< args.len:
    let n = numberIn(env, args[i], "comparison")
    if i > 0 and ok:
      ok = if ascending: previous < n else: previous > n
    previous = n
  if args.len < 2:
    err("comparisons need at least two arguments")
  boolean(ok)

proc ltBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  ordered(env, args, true)

proc gtBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  ordered(env, args, false)

proc equality(env: ref Environment, args: seq[Object], wantSame: bool): Object {.raises.} =
  if args.len < 2:
    err("comparisons need at least two arguments")
  result = boolean(true)
  var previous = eval(args[0], env)
  for i in 1 ..< args.len:
    let current = eval(args[i], env)
    if (current == previous) != wantSame:
      result = boolean(false)
      return
    previous = current

proc eqBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  equality(env, args, true)

proc neBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  equality(env, args, false)

proc notBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  if args.len != 1:
    err("not needs exactly one argument")
  boolean(not toBool(eval(args[0], env)))

proc defineInEnv(env: ref Environment, args: seq[Object], bodyStart: int,
    isFun: bool, dynamic: bool = false): Object {.raises.} =
  if args.len < 1 or not isSymbol(args[0]):
    let kw = if isFun: "fun" elif dynamic: "dynamic-command" else: "command"
    err(kw & " needs a name")
  define(env, args[0], newCommand(toSymbol(args[0]), args[1 ..< bodyStart],
    args[bodyStart ..< args.len], env, isFun, dynamic))
  nothing()

proc funBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  defineInEnv(env, args, bodyStart, true)

proc commandBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  defineInEnv(env, args, bodyStart, false)

proc dynamicCommandBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  defineInEnv(env, args, bodyStart, false, true)

proc bindBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # bind name value defines name where it was written. Given a command's
  # parameter, that is the caller's scope, or, inside a `do`, the block's
  # scope on the caller's side, which ends with the block.
  if args.len != 2:
    err("bind needs a name and a value")
  let name = eval(args[0], env)
  let value = eval(args[1], env)
  let scope = syntaxScope(name)
  if isSymbol(name):
    define(env, name, value)
  elif scope != nil:
    if not isSymbol(syntaxForm(name)):
      err("bind needs a name, got " & stringify(name))
    define(resolveScope(env, scope), syntaxForm(name), value)
  else:
    err("bind needs a name, got " & stringify(name))
  value

proc newScopeBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # new-scope gives a fresh scope, a child of the current one, as a value
  # that eval-in can run code in. It lasts as long as the value does, which
  # is what a repl needs to keep definitions between inputs.
  if args.len != 0:
    err("new-scope takes no arguments")
  scopeValue(newEnvironment(env))

proc evalInBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # eval-in scope code evaluates the value of code in scope.
  if args.len != 2:
    err("eval-in needs a scope and code")
  let target = eval(args[0], env)
  let code = eval(args[1], env)
  let scope = scopeEnv(target)
  result = nothing()
  if scope == nil:
    err("eval-in needs a scope from new-scope, got " & stringify(target))
  else:
    result = eval(code, scope)

proc lambdaBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  result = newCommand("", args[0 ..< bodyStart], args[bodyStart ..< args.len], env, true)

proc recordBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  var fields = newSeqOfCap[Object](args.len)
  for form in args:
    if not isPair(form):
      err("{} needs (name = value) forms")
    if not isSymbol(car(form)):
      err("{} needs a symbol before '='")
    fields.add pair(car(form), eval(cdr(form), env))
  record(fields)

proc listBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  var xs = newSeqOfCap[Object](args.len)
  for form in args:
    xs.add eval(form, env)
  list(xs)

proc hasLength(o: Object): bool =
  isList(o) or isRecord(o) or isString(o) or isPair(o)

proc lengthOf(o: Object): int =
  result = 0
  if isList(o):
    result = itemCount(o)
  elif isRecord(o):
    result = recordFields(o).len
  elif isString(o):
    result = toStr(o).len
  elif isPair(o):
    result = 2

proc lengthBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  if args.len != 1:
    err("length needs one argument")
  let o = eval(args[0], env)
  if not hasLength(o):
    err("length needs something with a length, got " & stringify(o))
  number(float64(lengthOf(o)))

proc nameOf(key: Object): string =
  result = ""
  if isSymbol(key):
    result = toSymbol(key)
  elif isString(key):
    result = toStr(key)

proc positionOf(key: Object): int =
  result = -1
  if isNumber(key):
    let n = toNumber(key)
    if n >= 0.0 and n == float64(int64(n)):
      result = int(n)

proc keyOf(env: ref Environment, form: Object): Object {.raises.} =
  result = form
  if not isSymbol(form):
    result = eval(form, env)

proc indexAt(o: Object, key: Object): Object {.raises.} =
  let name = nameOf(key)
  if name.len > 0:
    if isRecord(o):
      return field(o, name)
    err("index needs a record for a name, got " & stringify(o))
  let at = positionOf(key)
  if at < 0:
    if isNumber(key):
      err("index needs a whole number position, got " & stringify(key))
    err("index needs a number or a name key, got " & stringify(key))
  if not hasLength(o):
    err("index needs something with a length, got " & stringify(o))
  if at >= lengthOf(o):
    err("index out of range: " & stringify(key) & " for " & stringify(o))
  if isPair(o):
    result = if at == 0: car(o) else: cdr(o)
  elif isString(o):
    result = str(toStr(o)[at .. at])
  elif isRecord(o):
    result = recordFields(o)[at]
  else:
    result = itemAt(o, at)

proc indexBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  if args.len < 2:
    err("index needs a value and a key")
  result = eval(args[0], env)
  for i in 1 ..< args.len:
    result = indexAt(result, keyOf(env, args[i]))

proc fieldBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  if args.len != 2:
    err("field needs a record and a name")
  let o = eval(args[0], env)
  let key = keyOf(env, args[1])
  if not isRecord(o):
    err("field needs a record, got " & stringify(o))
  if nameOf(key).len == 0:
    err("field needs a name, got " & stringify(key))
  field(o, nameOf(key))

proc listVar(env: ref Environment, form: Object, what: string): Object {.raises.} =
  if not isSymbol(form):
    err(what & " needs a variable name")
  let found = lookup(env, form)
  if found.isNone:
    err(what & " needs a defined variable: " & toSymbol(form))
  result = found.get()
  if not isList(result):
    err(what & " needs a list variable, got " & stringify(result))

proc storeList(env: ref Environment, name: Object, items: sink seq[Object]) =
  discard assign(env, name, list(items))

proc appendBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  if args.len < 1:
    err("append needs a variable")
  var items = toSeq(listVar(env, args[0], "append"))
  for i in 1 ..< args.len:
    items.add eval(args[i], env)
  # lists are values: the variable and the result share the new one
  result = list(items)
  discard assign(env, args[0], result)

proc prependBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  if args.len < 1:
    err("prepend needs a variable")
  var items: seq[Object] = @[]
  for i in 1 ..< args.len:
    items.add eval(args[i], env)
  let old = listVar(env, args[0], "prepend")
  for i in 0 ..< itemCount(old):
    items.add itemAt(old, i)
  result = list(items)
  discard assign(env, args[0], result)

proc insertBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  if args.len < 2:
    err("insert needs a variable and a position")
  let items = toSeq(listVar(env, args[0], "insert"))
  let key = eval(args[1], env)
  let at = positionOf(key)
  if at < 0:
    err("insert needs a whole number position, got " & stringify(key))
  if at > items.len:
    err("insert position out of range: " & stringify(key))
  var grown: seq[Object] = @[]
  for i in 0 ..< at:
    grown.add items[i]
  for i in 2 ..< args.len:
    grown.add eval(args[i], env)
  for i in at ..< items.len:
    grown.add items[i]
  result = list(grown)
  discard assign(env, args[0], result)

proc popBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  if args.len != 1:
    err("pop needs one variable")
  let old = listVar(env, args[0], "pop")
  let n = itemCount(old)
  if n == 0:
    err("pop from an empty list")
  result = itemAt(old, n - 1)
  var rest: seq[Object] = @[]
  for i in 0 ..< n - 1:
    rest.add itemAt(old, i)
  storeList(env, args[0], rest)

proc popFrontBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  if args.len != 1:
    err("pop-front needs one variable")
  let old = listVar(env, args[0], "pop-front")
  let n = itemCount(old)
  if n == 0:
    err("pop-front from an empty list")
  result = itemAt(old, 0)
  var rest: seq[Object] = @[]
  for i in 1 ..< n:
    rest.add itemAt(old, i)
  storeList(env, args[0], rest)

proc argvValue(): Object =
  var xs: seq[Object] = @[]
  for i in 1 .. paramCount():
    xs.add str(paramStr(i))
  list(xs)

proc installBaseOwl*(env: ref Environment)

proc installBase*(env: ref Environment) =
  define(env, symbol("argv"), argvValue())
  define(env, symbol("nothing"), nothing())
  define(env, symbol("true"), boolean(true))
  define(env, symbol("false"), boolean(false))
  define(env, symbol("concat"), newBuiltin("concat", concatBuiltin, true))
  define(env, symbol("error"), newBuiltin("error", errorBuiltin, false))
  define(env, symbol("do"), newBuiltin("do", doBuiltin, false))
  define(env, symbol("while"), newBuiltin("while", whileBuiltin, false))
  define(env, symbol("when"), newBuiltin("when", whenBuiltin, false))
  define(env, symbol("cond"), newBuiltin("cond", condBuiltin, false))
  define(env, symbol("pair"), newBuiltin("pair", pairBuiltin, false))
  define(env, symbol("set"), newBuiltin("set", setBuiltin, false))
  define(env, symbol("quote"), newBuiltin("quote", quoteBuiltin, false))
  define(env, symbol("eval"), newBuiltin("eval", evalBuiltin, false))
  define(env, symbol("parse"), newBuiltin("parse", parseBuiltin, true))
  define(env, symbol("try"), newBuiltin("try", tryBuiltin, false))
  define(env, symbol("char"), newBuiltin("char", charBuiltin, true))
  define(env, symbol("to-string"), newBuiltin("to-string", toStringBuiltin, true))
  define(env, symbol("to-code"), newBuiltin("to-code", toCodeBuiltin, true))
  define(env, symbol("type-of"), newBuiltin("type-of", typeOfBuiltin, true))
  define(env, symbol("body-start"), newBuiltin("body-start", bodyStartBuiltin, true))
  define(env, symbol("syntax-form"), newBuiltin("syntax-form", syntaxFormBuiltin, true))
  define(env, symbol("syntax-scope"), newBuiltin("syntax-scope", syntaxScopeBuiltin, true))
  define(env, symbol("with"), newBuiltin("with", withBuiltin, false))
  define(env, symbol("slice"), newBuiltin("slice", sliceBuiltin, true))
  define(env, symbol("find"), newBuiltin("find", findBuiltin, true))
  define(env, symbol("code"), newBuiltin("code", codeBuiltin, true))
  define(env, symbol("if"), newBuiltin("if", ifBuiltin, false))
  define(env, symbol("<"), newBuiltin("<", ltBuiltin, true))
  define(env, symbol(">"), newBuiltin(">", gtBuiltin, true))
  define(env, symbol("="), newBuiltin("=", eqBuiltin, true))
  define(env, symbol("<>"), newBuiltin("<>", neBuiltin, true))
  define(env, symbol("not"), newBuiltin("not", notBuiltin, true))
  define(env, symbol("fun"), newBuiltin("fun", funBuiltin, true))
  define(env, symbol("command"), newBuiltin("command", commandBuiltin, false))
  define(env, symbol("dynamic-command"), newBuiltin("dynamic-command", dynamicCommandBuiltin, false))
  define(env, symbol("bind"), newBuiltin("bind", bindBuiltin, false))
  define(env, symbol("new-scope"), newBuiltin("new-scope", newScopeBuiltin, true))
  define(env, symbol("eval-in"), newBuiltin("eval-in", evalInBuiltin, true))
  define(env, symbol("lambda"), newBuiltin("lambda", lambdaBuiltin, true))
  define(env, symbol("λ"), newBuiltin("λ", lambdaBuiltin, true))
  define(env, symbol("{}"), newBuiltin("{}", recordBuiltin, true))
  define(env, symbol("[]"), newBuiltin("[]", listBuiltin, true))
  define(env, symbol("length"), newBuiltin("length", lengthBuiltin, true))
  define(env, symbol("index"), newBuiltin("index", indexBuiltin, true))
  define(env, symbol("field"), newBuiltin("field", fieldBuiltin, true))
  define(env, symbol("append"), newBuiltin("append", appendBuiltin, false))
  define(env, symbol("prepend"), newBuiltin("prepend", prependBuiltin, false))
  define(env, symbol("insert"), newBuiltin("insert", insertBuiltin, false))
  define(env, symbol("pop"), newBuiltin("pop", popBuiltin, false))
  define(env, symbol("pop-front"), newBuiltin("pop-front", popFrontBuiltin, false))
  installBaseOwl(env)

proc installBaseOwl*(env: ref Environment) =
  # Merge the owl half of base into the same env as the Nim builtins, so that
  # `use base` exports both. base.owl uses only base primitives and never a
  # number from another module; base is the bottom of the stack.
  # embedFile is a compile-time template plugin: the source is read at build
  # time and baked in as a literal (Nimony has no staticRead). The path is
  # resolved relative to this file, so the build is independent of the cwd.
  const source: string = embedFile("base.owl")
  let parsed = parseOwl(source)
  if parsed.isOk:
    for f in parsed.get(@[]):
      if isCommandDefinition(f):
        makeCommandDefinition(env, f)
      elif isDefinition(f, "fun"):
        makeDefinition(env, f, true)

proc baseModule*(): Module =
  result = newModule("base")
  installBase(result.env)
  exportAllBindings(result)
