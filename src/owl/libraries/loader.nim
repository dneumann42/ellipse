import std/[syncio, options]
import owl/[objects, evaluator, modules]

# The module registry as owl sees it: loading modules, and the handles the
# live layer (live.owl) needs to patch one in place: its scope, its text, its
# uses and exports. Modules are named by strings.

var loaderLibrary: nil Library = nil

proc theLibrary(): Library {.raises.} =
  let lib = loaderLibrary
  if lib == nil:
    err("no module library is installed")
    result = newLibrary("none")
  else:
    result = lib

proc stringArg(env: ref Environment, args: seq[Object], i: int, what: string): string {.raises.} =
  if i >= args.len:
    err(what & " needs more arguments")
  let v = eval(args[i], env)
  if not isString(v):
    err(what & " needs a string, got " & stringify(v))
  toStr(v)

proc moduleArg(env: ref Environment, args: seq[Object], what: string): Module {.raises.} =
  let name = stringArg(env, args, 0, what)
  let found = findModule(theLibrary(), name)
  if found == nil:
    err("no module named " & name)
    result = newModule(name)
  else:
    result = found

proc scopeArg(env: ref Environment, args: seq[Object], what: string): ref Environment {.raises.} =
  let v = eval(args[0], env)
  let scope = scopeEnv(v)
  if scope == nil:
    err(what & " needs a scope, got " & stringify(v))
    result = newEnvironment()
  else:
    result = scope

proc loadModuleBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # load-module name evaluates a module, reading it from the search paths
  # the first time, and gives its name back.
  let name = stringArg(env, args, 0, "load-module")
  discard require(theLibrary(), name)
  str(name)

proc newModuleBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # new-module name makes an empty module in memory, for a repl document.
  let name = stringArg(env, args, 0, "new-module")
  let lib = theLibrary()
  if hasModule(lib, name):
    err("a module named " & name & " already exists")
  let m = newModule(name)
  lib.add m
  discard require(lib, name)
  str(name)

proc hasModuleBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  boolean(hasModule(theLibrary(), stringArg(env, args, 0, "has-module")))

proc moduleNamesBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  let lib = theLibrary()
  var names: seq[Object] = @[]
  for m in lib.modules.values:
    names.add str(m.name)
  list(names)

proc modulePathsBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  let lib = theLibrary()
  var dirs: seq[Object] = @[]
  for i in 0 ..< lib.paths.len:
    dirs.add str(lib.paths[i])
  list(dirs)

proc addModulePathBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  addPath(theLibrary(), stringArg(env, args, 0, "add-module-path"))
  nothing()

proc removeModulePathBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  removePath(theLibrary(), stringArg(env, args, 0, "remove-module-path"))
  nothing()

proc unloadModuleBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # unload-module name: runs its on-unload and forgets it (see modules.unload).
  unload(theLibrary(), stringArg(env, args, 0, "unload-module"))
  nothing()

proc moduleFileBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # module-file name: the file `use name` would load, or nothing.
  let path = moduleFile(theLibrary(), stringArg(env, args, 0, "module-file"))
  if path.len == 0:
    result = nothing()
  else:
    result = str(path)

proc modulePathBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # module-path name: the file a loaded module belongs to, or nothing.
  let m = moduleArg(env, args, "module-path")
  if m.path.len == 0:
    result = nothing()
  else:
    result = str(m.path)

proc setModulePathBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  let m = moduleArg(env, args, "set-module-path")
  m.path = stringArg(env, args, 1, "set-module-path")
  nothing()

proc moduleSourceBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  str(moduleArg(env, args, "module-source").source)

proc setModuleSourceBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # Only records the text; live.owl evaluates the changes itself.
  let m = moduleArg(env, args, "set-module-source")
  m.source = stringArg(env, args, 1, "set-module-source")
  nothing()

proc moduleScopeBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  scopeValue(moduleArg(env, args, "module-scope").env)

proc moduleExportsBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  var names: seq[Object] = @[]
  for n in exportNames(moduleArg(env, args, "module-exports")):
    names.add str(n)
  list(names)

proc moduleUsesBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  let m = moduleArg(env, args, "module-uses")
  var names: seq[Object] = @[]
  for i in 0 ..< m.deps.len:
    names.add str(m.deps[i])
  list(names)

proc moduleUseBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # module-use name dep: `use dep` inside module name, loading dep if needed.
  let m = moduleArg(env, args, "module-use")
  let dep = stringArg(env, args, 1, "module-use")
  let d = require(theLibrary(), dep)
  useModule(m.env, d)
  if dep notin m.deps:
    m.deps.add dep
  nothing()

proc moduleClearUsesBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  let m = moduleArg(env, args, "module-clear-uses")
  clearImports(m.env)
  m.deps = @[]
  nothing()

proc moduleExportBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # module-export name public internal: users of the module see its binding
  # internal under the name public.
  let m = moduleArg(env, args, "module-export")
  let public = stringArg(env, args, 1, "module-export")
  let internal = stringArg(env, args, 2, "module-export")
  exportName(m.exports, symbol(public), symbol(internal))
  nothing()

proc moduleClearExportsBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  clearExportNames(moduleArg(env, args, "module-clear-exports").exports)
  nothing()

proc hasOwnBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # has-own scope name: whether scope itself binds name, not counting what
  # it uses or encloses.
  if args.len != 2:
    err("has-own needs a scope and a name")
  let scope = scopeArg(env, args, "has-own")
  boolean(hasOwn(scope, symbol(stringArg(env, args, 1, "has-own"))))

proc unbindBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # unbind scope name removes scope's own binding of name.
  if args.len != 2:
    err("unbind needs a scope and a name")
  let scope = scopeArg(env, args, "unbind")
  undefine(scope, symbol(stringArg(env, args, 1, "unbind")))
  nothing()

proc makeDefinitionBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # make-definition scope form makes a parsed fun, command or
  # dynamic-command in scope the way loading a module does, so it works in a
  # module that does not itself use base (where `fun` is unbound).
  if args.len != 2:
    err("make-definition needs a scope and a form")
  let scope = scopeArg(env, args, "make-definition")
  let form = eval(args[1], env)
  if isCommandDefinition(form):
    makeCommandDefinition(scope, form)
  elif isDefinition(form, "fun"):
    makeDefinition(scope, form, true)
  else:
    err("make-definition needs a fun, command or dynamic-command, got " & stringify(form))
  nothing()

proc scopeNamesBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # scope-names scope: the names scope itself binds, not what it uses.
  if args.len != 1:
    err("scope-names needs a scope")
  let scope = scopeArg(env, args, "scope-names")
  var names: seq[Object] = @[]
  for name, value in allBindings(scope):
    if isSymbol(name):
      names.add str(toSymbol(name))
  list(names)

proc installLoader*(env: ref Environment) =
  define(env, symbol("load-module"), newBuiltin("load-module", loadModuleBuiltin, true))
  define(env, symbol("new-module"), newBuiltin("new-module", newModuleBuiltin, true))
  define(env, symbol("has-module"), newBuiltin("has-module", hasModuleBuiltin, true))
  define(env, symbol("module-names"), newBuiltin("module-names", moduleNamesBuiltin, true))
  define(env, symbol("module-paths"), newBuiltin("module-paths", modulePathsBuiltin, true))
  define(env, symbol("add-module-path"), newBuiltin("add-module-path", addModulePathBuiltin, true))
  define(env, symbol("remove-module-path"), newBuiltin("remove-module-path", removeModulePathBuiltin, true))
  define(env, symbol("unload-module"), newBuiltin("unload-module", unloadModuleBuiltin, true))
  define(env, symbol("module-file"), newBuiltin("module-file", moduleFileBuiltin, true))
  define(env, symbol("module-path"), newBuiltin("module-path", modulePathBuiltin, true))
  define(env, symbol("set-module-path"), newBuiltin("set-module-path", setModulePathBuiltin, true))
  define(env, symbol("module-source"), newBuiltin("module-source", moduleSourceBuiltin, true))
  define(env, symbol("set-module-source"), newBuiltin("set-module-source", setModuleSourceBuiltin, true))
  define(env, symbol("module-scope"), newBuiltin("module-scope", moduleScopeBuiltin, true))
  define(env, symbol("module-exports"), newBuiltin("module-exports", moduleExportsBuiltin, true))
  define(env, symbol("module-uses"), newBuiltin("module-uses", moduleUsesBuiltin, true))
  define(env, symbol("module-use"), newBuiltin("module-use", moduleUseBuiltin, true))
  define(env, symbol("module-clear-uses"), newBuiltin("module-clear-uses", moduleClearUsesBuiltin, true))
  define(env, symbol("module-export"), newBuiltin("module-export", moduleExportBuiltin, true))
  define(env, symbol("module-clear-exports"), newBuiltin("module-clear-exports", moduleClearExportsBuiltin, true))
  define(env, symbol("has-own"), newBuiltin("has-own", hasOwnBuiltin, true))
  define(env, symbol("scope-names"), newBuiltin("scope-names", scopeNamesBuiltin, true))
  define(env, symbol("unbind"), newBuiltin("unbind", unbindBuiltin, true))
  define(env, symbol("make-definition"), newBuiltin("make-definition", makeDefinitionBuiltin, true))

proc loaderModule*(lib: Library): Module =
  loaderLibrary = lib
  result = newModule("modules")
  installLoader(result.env)
  exportAllBindings(result)
