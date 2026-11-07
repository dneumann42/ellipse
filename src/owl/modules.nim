import std/[tables, syncio, options, os]
export tables
import owl/[objects, reader, evaluator, errors]

type
  Module* = ref object
    name*: string
    forms*: seq[Object]
    env*: ref Environment
    exports*: ref Exports
    deps*: seq[string]
    path*: string
    source*: string
    evaluated: bool
    evaluating: bool

  Library* = ref object
    name*: string
    modules*: Table[string, Module]
    paths*: seq[string]

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

proc sourceName*(m: Module): string =
  if m.path.len > 0: m.path else: "<" & m.name & ">"

proc readSource*(source: string, name: string, internal: bool = false): seq[Object] =
  let parsed = readForms(source, name, internal)
  if not parsed.isOk:
    raiseError(parsed.error(owlError(ReadError, "")))
  result = parsed.get(@[])

proc addSource*(m: Module, source: string): Module =
  result = addForms(m, readSource(source, sourceName(m)))
  result.source.add source

proc addLibrarySource*(m: Module, source: string): Module =
  result = addForms(m, readSource(source, sourceName(m), true))
  result.source.add source

proc addFile*(m: Module, path: string): Module =
  var source = ""
  var failed = false
  try:
    source = readFile(path)
  except CatchableError:
    failed = true
  if failed:
    err("module " & m.name & ": cannot open file: " & path)
  m.path = path
  result = addSource(m, source)

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

proc findModule*(lib: Library, name: string): Module =
  lib.modules.getOrDefault(name, nil)

proc moduleFile*(lib: Library, name: string): string =
  result = ""
  for dir in lib.paths:
    let candidate = (if dir.len == 0: "" else: dir & "/") & name & ".owl"
    if fileExists(candidate):
      return candidate

proc add*(lib: Library, m: Module) =
  if lib.modules.hasKey(m.name):
    err("duplicate module: " & m.name)
  lib.modules[m.name] = m

proc hasModule*(lib: Library, name: string): bool =
  lib.modules.hasKey(name)

proc headSymbol(f: Object): string =
  result = ""
  if itemCount(f) > 0:
    result = toSymbol(headOf(f))

proc isUseForm*(f: Object): bool =
  ## Whether `f` is a `use name...` line.
  headSymbol(f) == "use" and bodyStart(f) < 0 and itemCount(f) > 1

proc useNames*(f: Object): seq[string] =
  ## The modules a `use` line asks for.
  result = @[]
  let it = toSeq(f)
  for i in 1 ..< it.len:
    let name = toSymbol(it[i])
    if name.len > 0 and name notin result:
      result.add name

proc isExportForm(f: Object): bool =
  headSymbol(f) == "export" and itemCount(f) > 1

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

proc exportValue*(m: Module, name: string): Option[Object] =
  lookupExport(m.exports, symbol(name))

proc exportNames*(m: Module): seq[string] =
  result = @[]
  for name in exportedNames(m.exports):
    result.add toSymbol(name)

proc useModule*(env: ref Environment, m: Module) =
  addImport(env, m.exports)

proc useFormsIn*(env: ref Environment, forms: seq[Object], lib: Library) =
  ## Import into `env` every module the `use` lines in `forms` name, as long
  ## as the library holds it.
  for f in forms:
    if isUseForm(f):
      for name in useNames(f):
        let dep = findModule(lib, name)
        if dep != nil:
          useModule(env, dep)

proc isExportAll*(f: Object): bool =
  isExportForm(f) and bodyStart(f) < 0 and itemCount(f) == 2 and
    toSymbol(itemAt(f, 1)) == "all"

proc registerExports(m: Module) =
  for f in m.forms:
    if isExportAll(f):
      setExportAll(m.exports, true)
    elif isExportForm(f):
      for e in exportEntries(f):
        if not isPair(e) or not isSymbol(car(e)):
          errAt(e, "module " & m.name & ": export needs (name = value) forms", CompileError)
        if isSymbol(cdr(e)):
          exportName(m.exports, car(e), cdr(e))

proc runExportForm(m: Module, f: Object) =
  for e in exportEntries(f):
    let publicName = car(e)
    if isSymbol(cdr(e)):
      if not has(m.env, cdr(e)):
        raiseError(CompileError, "module " & m.name & " exports an unbound name: " &
          toSymbol(cdr(e)), valuePlace(e))
    else:
      define(m.env, publicName, eval(cdr(e), m.env))
      exportName(m.exports, publicName, publicName)

proc runModuleForms(m: Module, lib: Library) =
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

proc runHook*(m: Module, hook: string, args: seq[Object]) =
  let name = symbol(hook)
  if hasOwn(m.env, name) and isCommand(lookup(m.env, name).get(nothing())):
    var call = @[name]
    for a in args:
      call.add a
    discard eval(list(call), m.env)

proc evaluateModule(lib: Library, m: Module) =
  if m.evaluated or m.evaluating:
    return
  m.evaluating = true
  try:
    for d in m.deps:
      let dep = findModule(lib, d)
      if dep != nil:
        evaluateModule(lib, dep)
    runModuleForms(m, lib)
    m.evaluating = false
    m.evaluated = true
    runHook(m, "on-load", @[])
  except CatchableError:
    # Left marked as evaluating, a failed module would be skipped silently
    # by every later evaluate; clear it so a retry reports again.
    m.evaluating = false
    adoptForeign()
    sealError()
    rethrow()

proc unload*(lib: Library, name: string) =
  let m = findModule(lib, name)
  if m == nil:
    err("no module named " & name)
  else:
    runHook(m, "on-unload", @[])
    lib.modules.del(name)

proc loadDeps(lib: Library, m: Module) {.gcsafe.}

proc ensureLoaded(lib: Library, name: string, user: string,
    useForm: Object = nothing())  =
  if lib.modules.hasKey(name):
    return
  let path = moduleFile(lib, name)
  if path.len == 0:
    let at = itemPlace(useForm, findItem(useForm, symbol(name)))
    if user.len > 0:
      raiseError(CompileError, "module " & user & " uses unknown module " & name, at)
    if at.isKnown:
      raiseError(CompileError, "unknown module " & name, at)
    err("unknown module " & name)
  let m = newModule(name).addFile(path)
  lib.add m
  loadDeps(lib, m)

proc loadDeps(lib: Library, m: Module) {.gcsafe.} =
  m.deps = @[]
  for f in m.forms:
    if isUseForm(f):
      for name in useNames(f):
        ensureLoaded(lib, name, m.name, f)
        if name notin m.deps:
          m.deps.add name

proc collectDeps(lib: Library) =
  var known: seq[Module] = @[]
  for m in lib.modules.values:
    known.add m
  for m in known:
    loadDeps(lib, m)

proc evaluate*(lib: Library) =
  collectDeps(lib)
  var all: seq[Module] = @[]
  for m in lib.modules.values:
    all.add m
  for m in all:
    evaluateModule(lib, m)

proc require*(lib: Library, name: string, useForm: Object = nothing()): Module =
  ensureLoaded(lib, name, "", useForm)
  let found = findModule(lib, name)
  if found == nil:
    err("unknown module " & name)
  loadDeps(lib, found)
  evaluateModule(lib, found)
  result = found

proc runProgram*(lib: Library, forms: seq[Object]): ref Environment =
  evaluate(lib)
  for f in forms:
    if isUseForm(f):
      for name in useNames(f):
        discard require(lib, name, f)
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
  try:
    discard evalForms(result, rest)
  except CatchableError:
    adoptForeign()
    sealError()
    rethrow()
