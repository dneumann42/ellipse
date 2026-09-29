import std/syncio
import owl/[objects, evaluator, modules]

proc quoteBuiltin(env: ref Environment, args, body: seq[Object]): Object {.raises.} =
  if args.len == 0:
    err("quote needs one argument")
  args[0]

proc evalBuiltin(env: ref Environment, args, body: seq[Object]): Object {.raises.} =
  if args.len == 0:
    err("eval needs one argument")
  let syntax = eval(args[0], env)
  eval(syntax, env)

proc ifBuiltin(env: ref Environment, args, body: seq[Object]): Object {.raises.} =
  if args.len == 0:
    err("if needs a condition")
  if body.len == 0:
    err("if needs at least one body form")
  if toBool(eval(args[0], env)):
    eval(body[0], env)
  else:
    evalForms(env, body[1 ..< body.len])

proc defineInEnv(env: ref Environment, args, body: seq[Object], isFun: bool): Object {.raises.} =
  if args.len < 1 or not isSymbol(args[0]):
    let kw = if isFun: "fun" else: "command"
    err(kw & " needs a name")
  var params: seq[Object] = @[]
  for i in 1 ..< args.len:
    params.add args[i]
  define(env, args[0], newCommand(toSymbol(args[0]), params, body, env, isFun))
  nothing()

proc funBuiltin(env: ref Environment, args, body: seq[Object]): Object {.raises.} =
  defineInEnv(env, args, body, true)

proc commandBuiltin(env: ref Environment, args, body: seq[Object]): Object {.raises.} =
  defineInEnv(env, args, body, false)

func allForms(args, body: seq[Object]): seq[Object] =
  result = @[]
  for f in args:
    result.add f
  for f in body:
    result.add f

proc recordBuiltin(env: ref Environment, args, body: seq[Object]): Object {.raises.} =
  var fields: seq[Object] = @[]
  for form in allForms(args, body):
    if not isPair(form):
      err("{} needs (name = value) forms")
    if not isSymbol(car(form)):
      err("{} needs a symbol before '='")
    fields.add pair(car(form), eval(cdr(form), env))
  record(fields)

proc listBuiltin(env: ref Environment, args, body: seq[Object]): Object {.raises.} =
  var xs: seq[Object] = @[]
  for form in allForms(args, body):
    xs.add eval(form, env)
  list(xs)

proc installBase*(env: ref Environment) =
  define(env, symbol("quote"), newBuiltin("quote", quoteBuiltin, false))
  define(env, symbol("eval"), newBuiltin("eval", evalBuiltin, false))
  define(env, symbol("if"), newBuiltin("if", ifBuiltin, false))
  define(env, symbol("fun"), newBuiltin("fun", funBuiltin, true))
  define(env, symbol("command"), newBuiltin("command", commandBuiltin, false))
  define(env, symbol("{}"), newBuiltin("{}", recordBuiltin, true))
  define(env, symbol("[]"), newBuiltin("[]", listBuiltin, true))

proc baseModule*(): Module =
  result = newModule("base")
  installBase(result.env)
  exportAllBindings(result)
