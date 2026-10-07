import std/[tables, syncio, options]
import std/private/oscommons
import owl/[objects, reader, evaluator]

type
  Module* = ref object
    name*: string
    forms*: seq[Object]
    env*: ref Environment
    # Seen by importers as a view into env, never as copies (see Exports).
    exports*: ref Exports
    deps*: seq[string]
    # The file a module was loaded from ("" for one made in memory) and the
    # text it currently runs, which the live layer patches and saves.
    path*: string
    source*: string
    evaluated: bool
    evaluating: bool

  Library* = ref object
    name*: string
    modules*: Table[string, Module]
    # Directories where `use name` finds name.owl when no module of that
    # name is loaded yet. A project adds its source directory here.
    paths*: seq[string]

proc fail(msg: string) {.raises.} =
  err(msg)

proc newModule*(name: string): Module =
  let env = newEnvironment()
  result = Module(name: name, forms: @[], env: env,
    exports: newExports(env), deps: @[], path: "", source: "",
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
  result.source.add source

proc addFile*(m: Module, path: string): Module {.raises.} =
  var source = ""
  var failed = false
  try:
    source = readFile(path)
  except:
    failed = true
  if failed:
    fail("module " & m.name & ": cannot open file: " & path)
  result = addSource(m, source)
  result.path = path

proc addExport*(m: Module, name: string, value: Object): Module =
  result = m
  define(result.env, symbol(name), value)
  exportName(result.exports, symbol(name), symbol(name))

proc addBuiltin*(m: Module, name: string, call: CommandProc, isFun: bool): Module =
  result = addExport(m, name, newBuiltin(name, call, isFun))

proc newLibrary*(name: string): Library =
  result = Library(name: name, modules: initTable[string, Module](), paths: @[])

proc addPath*(lib: Library, dir: string) =
  if dir notin lib.paths:
    lib.paths.add dir

proc removePath*(lib: Library, dir: string) =
  var kept: seq[string] = @[]
  for d in lib.paths:
    if d != dir:
      kept.add d
  lib.paths = kept

proc findModule*(lib: Library, name: string): nil Module =
  result = nil
  for m in lib.modules.values:
    if m.name == name:
      return m

# The file `use name` loads: name.owl in the first search path that has it,
# or "" when none does. A name may hold slashes: `use ui/button`.
proc moduleFile*(lib: Library, name: string): string =
  result = ""
  for dir in lib.paths:
    let candidate = (if dir.len == 0: "" else: dir & "/") & name & ".owl"
    if fileExists(candidate):
      return candidate

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

proc exportAllBindings*(m: Module) =
  let bindings = allBindings(m.env)
  for name, value in bindings:
    if isSymbol(name):
      exportName(m.exports, name, name)

# exportValue m name is what a user of m sees under name, if m exports it.
proc exportValue*(m: Module, name: string): Option[Object] =
  lookupExport(m.exports, symbol(name))

proc exportNames*(m: Module): seq[string] =
  result = @[]
  for name in exportedNames(m.exports):
    result.add toSymbol(name)

# useModule env m is `use m` in env: m's exports become visible there, live.
proc useModule*(env: ref Environment, m: Module) =
  addImport(env, m.exports)

proc useFormsIn(env: ref Environment, forms: seq[Object], lib: Library) =
  for f in forms:
    if isUseForm(f):
      for name in useNames(f):
        for dep in lib.modules.values:
          if dep.name == name:
            useModule(env, dep)

proc hoistDefinitions(env: ref Environment, forms: seq[Object]) =
  for f in forms:
    if evaluator.isCommandDefinition(f):
      evaluator.makeCommandDefinition(env, f)
  for f in forms:
    if evaluator.isDefinition(f, "fun"):
      evaluator.makeDefinition(env, f, true)

proc isExportAll*(f: Object): bool =
  # `export all`: everything the module binds itself is public.
  isExportForm(f) and bodyStart(f) < 0 and toSeq(f).len == 2 and
    toSymbol(toSeq(f)[1]) == "all"

proc registerExports(m: Module) {.raises.} =
  # Exports of a name are known before any statement runs, so a module in a
  # use cycle can already see them; the name resolves when it is used.
  for f in m.forms:
    if isExportAll(f):
      setExportAll(m.exports, true)
    elif isExportForm(f):
      for e in exportEntries(f):
        if not isPair(e) or not isSymbol(car(e)):
          fail("module " & m.name & ": export needs (name = value) forms")
        if isSymbol(cdr(e)):
          exportName(m.exports, car(e), cdr(e))

proc runExportForm(m: Module, f: Object) {.raises.} =
  for e in exportEntries(f):
    let publicName = car(e)
    if isSymbol(cdr(e)):
      if not has(m.env, cdr(e)):
        fail("module " & m.name & " exports an unbound name: " & toSymbol(cdr(e)))
    else:
      # An exported expression is evaluated once, into a binding of its own.
      define(m.env, publicName, eval(cdr(e), m.env))
      exportName(m.exports, publicName, publicName)

proc runModuleForms(m: Module, lib: Library) {.raises.} =
  let env = m.env
  hoistDefinitions(env, m.forms)
  useFormsIn(env, m.forms, lib)
  registerExports(m)
  for f in m.forms:
    if evaluator.isAnyDefinition(f):
      continue
    if isUseForm(f):
      continue
    if isExportAll(f):
      continue
    if isExportForm(f):
      runExportForm(m, f)
      continue
    discard eval(f, env)

proc runHook*(m: Module, hook: string, args: seq[Object]) {.raises.} =
  # A module's lifecycle hooks are funs it defines by these names, so they
  # are patched and reloaded like any other definition: on-load runs after
  # the first evaluation, on-reload after the live layer changed the module.
  let name = symbol(hook)
  if hasOwn(m.env, name) and isCommand(lookup(m.env, name).get(nothing())):
    var call = @[name]
    for a in args:
      call.add a
    discard eval(list(call), m.env)

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
  runHook(m, "on-load", @[])

# unload lib name runs the module's on-unload hook and takes it out of lib, so
# a later `use name` loads it afresh from the search paths. Scopes that
# already use it keep their view of it.
proc unload*(lib: Library, name: string) {.raises.} =
  let m = findModule(lib, name)
  if m == nil:
    fail("no module named " & name)
  else:
    runHook(m, "on-unload", @[])
    lib.modules.del(name)

proc loadDeps(lib: Library, m: Module) {.raises.}

# ensureLoaded lib name makes sure a module of that name is in lib, reading
# it and, in turn, the modules it uses from the search paths. Nothing is
# evaluated yet.
proc ensureLoaded(lib: Library, name: string, user: string) {.raises.} =
  if lib.modules.hasKey(name):
    return
  let path = moduleFile(lib, name)
  if path.len == 0:
    if user.len > 0:
      fail("module " & user & " uses unknown module " & name)
    fail("unknown module " & name)
  let m = newModule(name).addFile(path)
  lib.add m
  loadDeps(lib, m)

proc loadDeps(lib: Library, m: Module) {.raises.} =
  m.deps = @[]
  for f in m.forms:
    if isUseForm(f):
      for name in useNames(f):
        ensureLoaded(lib, name, m.name)
        if name notin m.deps:
          m.deps.add name

proc collectDeps(lib: Library) {.raises.} =
  var known: seq[Module] = @[]
  for m in lib.modules.values:
    known.add m
  for m in known:
    loadDeps(lib, m)

proc evaluate*(lib: Library) {.raises.} =
  collectDeps(lib)
  var all: seq[Module] = @[]
  for m in lib.modules.values:
    all.add m
  for m in all:
    evaluateModule(lib, m)

# require lib name is `use name` from the outside: the module, loaded from
# the search paths if needed, and evaluated.
proc require*(lib: Library, name: string): Module {.raises.} =
  ensureLoaded(lib, name, "")
  let found = findModule(lib, name)
  if found == nil:
    fail("unknown module " & name)
    result = newModule(name)
  else:
    loadDeps(lib, found)
    evaluateModule(lib, found)
    result = found

proc runProgram*(lib: Library, forms: seq[Object]): ref Environment {.raises.} =
  evaluate(lib)
  for f in forms:
    if isUseForm(f):
      for name in useNames(f):
        discard require(lib, name)
  result = newEnvironment()
  hoistDefinitions(result, forms)
  useFormsIn(result, forms, lib)
  var rest: seq[Object] = @[]
  for f in forms:
    if evaluator.isAnyDefinition(f):
      continue
    if isUseForm(f):
      continue
    rest.add f
  discard evalForms(result, rest)
