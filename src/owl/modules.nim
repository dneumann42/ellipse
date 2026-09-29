import std/[tables, syncio]
import owl/[objects, reader, evaluator]

type
  Module* = ref object
    name*: string
    forms*: seq[Object]
    env*: ref Environment
    exports*: Table[string, Object]
    deps*: seq[string]
    evaluated: bool
    evaluating: bool

  Library* = ref object
    name*: string
    modules*: Table[string, Module]

proc fail(msg: string) {.raises.} =
  err(msg)

proc newModule*(name: string): Module =
  result = Module(name: name, forms: @[], env: newEnvironment(),
    exports: initTable[string, Object](), deps: @[],
    evaluated: false, evaluating: false)

proc addForm*(m: Module, form: Object): Module =
  result = m
  result.forms.add form

proc addForms*(m: Module, forms: seq[Object]): Module =
  result = m
  for f in forms:
    result.forms.add f

proc addSource*(m: Module, source: string): Module {.raises.} =
  let parsed = parseOwl(source)
  if not parsed.isOk:
    fail("module " & m.name & ": " & parsed.error("parse error"))
  result = addForms(m, parsed.get(@[]))

proc addFile*(m: Module, path: string): Module {.raises.} =
  result = addSource(m, readFile(path))

proc addExport*(m: Module, name: string, value: Object): Module =
  result = m
  define(result.env, symbol(name), value)
  result.exports[name] = value

proc addBuiltin*(m: Module, name: string, call: CommandProc, isFun: bool): Module =
  result = addExport(m, name, newBuiltin(name, call, isFun))

proc newLibrary*(name: string): Library =
  result = Library(name: name, modules: initTable[string, Module]())

proc add*(lib: Library, m: Module) {.raises.} =
  if lib.modules.hasKey(m.name):
    fail("duplicate module: " & m.name)
  lib.modules[m.name] = m

proc hasModule*(lib: Library, name: string): bool =
  lib.modules.hasKey(name)

proc headSymbol(f: Object): string =
  result = ""
  if isList(f):
    let it = toSeq(f)
    if it.len > 0:
      result = toSymbol(it[0])

proc isUseForm(f: Object): bool =
  headSymbol(f) == "use" and bodyStart(f) < 0 and toSeq(f).len > 1

proc useNames(f: Object): seq[string] =
  result = @[]
  let it = toSeq(f)
  for i in 1 ..< it.len:
    let name = toSymbol(it[i])
    if name.len > 0 and name notin result:
      result.add name

proc isExportForm(f: Object): bool =
  headSymbol(f) == "export" and toSeq(f).len > 1

proc exportEntries(f: Object): seq[Object] =
  result = @[]
  let it = toSeq(f)
  let bs = bodyStart(f)
  let first = if bs >= 1 and bs < it.len: bs else: 1
  for i in first ..< it.len:
    result.add it[i]

proc copyExports(m: Module, env: ref Environment) =
  for name, value in m.exports:
    define(env, symbol(name), value)

proc exportAllBindings*(m: Module) =
  let bindings = allBindings(m.env)
  for name, value in bindings:
    if isSymbol(name):
      m.exports[toSymbol(name)] = value

proc useFormsIn(env: ref Environment, forms: seq[Object], lib: Library) =
  for f in forms:
    if isUseForm(f):
      for name in useNames(f):
        for dep in lib.modules.values:
          if dep.name == name:
            copyExports(dep, env)

proc hoistDefinitions(env: ref Environment, forms: seq[Object]) =
  for f in forms:
    if evaluator.isDefinition(f, "command"):
      evaluator.makeDefinition(env, f, false)
  for f in forms:
    if evaluator.isDefinition(f, "fun"):
      evaluator.makeDefinition(env, f, true)

proc runModuleForms(m: Module, lib: Library) {.raises.} =
  let env = m.env
  hoistDefinitions(env, m.forms)
  useFormsIn(env, m.forms, lib)
  for f in m.forms:
    if evaluator.isDefinition(f, "command") or evaluator.isDefinition(f, "fun"):
      continue
    if isUseForm(f):
      continue
    if isExportForm(f):
      for e in exportEntries(f):
        if not isPair(e) or not isSymbol(car(e)):
          fail("module " & m.name & ": export needs (name = value) forms")
        let publicName = car(e)
        let value = eval(cdr(e), env)
        define(env, publicName, value)
        m.exports[toSymbol(publicName)] = value
      continue
    discard eval(f, env)

proc evaluateModule(lib: Library, m: Module) {.raises.} =
  if m.evaluated or m.evaluating:
    return
  m.evaluating = true
  for d in m.deps:
    for dep in lib.modules.values:
      if dep.name == d:
        evaluateModule(lib, dep)
  runModuleForms(m, lib)
  m.evaluating = false
  m.evaluated = true

proc collectDeps(lib: Library) {.raises.} =
  for m in lib.modules.values:
    m.deps = @[]
    for f in m.forms:
      if isUseForm(f):
        for name in useNames(f):
          if not lib.modules.hasKey(name):
            fail("module " & m.name & " uses unknown module " & name)
          if name notin m.deps:
            m.deps.add name

proc propagateExports(lib: Library) =
  var changed = true
  while changed:
    changed = false
    for m in lib.modules.values:
      for d in m.deps:
        for dep in lib.modules.values:
          if dep.name == d:
            for name, value in dep.exports:
              let key = symbol(name)
              let found = lookup(m.env, key)
              if not hasOwn(m.env, key) or found.get(nothing()) != value:
                define(m.env, key, value)
                changed = true

proc evaluate*(lib: Library) {.raises.} =
  collectDeps(lib)
  for m in lib.modules.values:
    evaluateModule(lib, m)
  propagateExports(lib)

proc runProgram*(lib: Library, forms: seq[Object]): ref Environment {.raises.} =
  evaluate(lib)
  result = newEnvironment()
  hoistDefinitions(result, forms)
  useFormsIn(result, forms, lib)
  var rest: seq[Object] = @[]
  for f in forms:
    if evaluator.isDefinition(f, "command") or evaluator.isDefinition(f, "fun"):
      continue
    if isUseForm(f):
      continue
    rest.add f
  discard evalForms(result, rest)
