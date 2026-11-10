# One of owls primary purposes is to work as a settings file, replacing toml, yaml, json, xml with owl
# simple expressions can be ran, so data can be defined using abstractions like functions and commands.
#
# A settings file is an owl file whose *value* is the data: the last form it
# holds. It may be a plain record, and it may compute that record with
# functions, commands and `use`d modules:
#
#   use base
#
#   fun scale x pct:
#       / (* x pct) 100
#
#   {}:
#       width = scale 1024 75
#       title = "editor"
#
# `evaluateBindings` reads a file differently: its value is a record of its
# top-level bindings, so a file read that way leaves out the `{}:`:
#
#   width = scale 1024 75
#   title = "editor"
#
# Files are registered by type with `add`, which hands back a mutable borrow of
# the data, and read back through `get`. Both borrow, so writing to one writes
# to the stored settings:
#
#   var settings = newSettings()
#   discard settings.add("theme.owl", Theme)    # written with defaults if absent
#   settings.get(Theme).accent = "#e8b339"      # lands in the settings
#   settings.save(Theme)                        # back out to the file
#
# `add` returns `var T`, so Nim asks for that borrow to be used or discarded:
# `discard` it when you only mean to register the file, or assign through it
# (`settings.add("theme.owl", Theme).accent = "#e8b339"`). Binding it to a `var`
# would copy it out, as Nim does with every `var` result: read the stored data
# through `get`.
#
# Once a repository is `hotReload`ed, its files are watched through the owl
# watch system (inotify on POSIX, change notifications on Windows) and
# `checkForChanges` reloads whatever changed: **the file is the source of
# truth**, and the data in memory is replaced to match it. `descriptor` hands
# the watching descriptor to an event loop (`watchFd`) so the reload happens
# when a file moves rather than on a timer; without one, `checkForChanges`
# still works, comparing file contents each time it is called.
#
# A settings file runs in a restricted environment: it can reach arithmetic,
# strings, lists, iterators and its own definitions, and nothing else. It cannot
# open a file, make a socket, start a process or touch a display -- those
# builtins are simply not bound where it evaluates. `use fs` and `use net` fail
# as modules a settings file cannot use, so abstractions pulled in (`use`d or
# read from a directory through `addModulePath`) stay data.
#
# Types convert through `owl/serde`: nearly every Nim type needs no code, and
# the `asOwl`/`asNim` hooks there shape the rest. Because `add` builds its load
# and save hooks at *its* call site, hooks defined next to the type are seen by
# the first write and by every reload afterwards.

import std/[tables, strutils, sha1, syncio, os, typetraits, options]
import owl/[objects, reader, evaluator, errors, modules, embedfile]
import owl/[serde, watch]
import owl/libraries/[base, math, list]

export serde, watch


type
  SettingsTypeName* = string

  LoadHook = proc (self: AbstractSettingsObject) {.closure, gcsafe.}
  WriteHook = proc (self: AbstractSettingsObject): string {.closure, gcsafe.}

  AbstractSettingsObject* = ref object of RootObj
    path: string
    typeName: SettingsTypeName
    sandbox: Library        # the modules this file may `use`
    root: ref Environment   # the names it has without asking for any
    stamp: string           # content hash of the file as last read
    error: string           # what the last load rejected, "" when it was clean
    load: LoadHook
    write: WriteHook

  SettingsObject*[T] = ref object of AbstractSettingsObject
    data: T

  SettingsRepository* = object
    settings: Table[SettingsTypeName, AbstractSettingsObject]
    sandbox: Library
    root: ref Environment
    watch: FileWatch
    hot: bool
    quiet: bool
    opened: bool

const
  allowedModules = ["base", "math", "list", "strings", "iterators"]
    ## What a settings file may `use`: data and arithmetic, nothing with hands.


# The restricted environment ---------------------------------------------------

proc settingsLibrary*(): Library =
  ## The library a settings file resolves `use` against. Only the pure modules
  ## are in it, so `use fs`, `use net` and `use gui` name modules that do not
  ## exist here and fail.
  let lib = newLibrary("settings")
  lib.add baseModule()
  lib.add mathModule()
  lib.add listModule()
  lib.add newModule("strings").addLibrarySource(embedFile("libraries/strings.owl"))
  lib.add newModule("iterators").addLibrarySource(embedFile("libraries/iterators.owl"))
  result = lib

proc settingsRoot*(): ref Environment =
  ## The names a settings file has before it asks for any: the pure builtins,
  ## so a bare record literal evaluates without a `use` line.
  result = newEnvironment()
  installBase(result)
  installMath(result)
  installList(result)
  for source in [embedFile("libraries/strings.owl"), embedFile("libraries/iterators.owl")]:
    let parsed = readForms(source, "<settings library>", true)
    if parsed.isOk:
      hoistDefinitions(result, parsed.get(@[]))

proc run(lib: Library, root: ref Environment, path: string, source: string,
    rest: var seq[Object], env: var ref Environment): Object =
  ## Run a settings file: `use` lines, hoisted definitions, then the other
  ## forms (left in `rest`) in `env`. The value of the last form.
  let forms = readSource(source, path)
  for f in forms:
    if isUseForm(f):
      for name in useNames(f):
        # only the modules the sandbox holds -- or ones `addModulePath` put on
        # its search path -- resolve, and every one of them runs with the same
        # restricted names and none more
        if name notin allowedModules and moduleFile(lib, name).len == 0:
          raiseError(CompileError, "a settings file cannot use module " & name,
            itemPlace(f, findItem(f, symbol(name))))
        discard require(lib, name, f)
  env = newEnvironment(root)
  hoistDefinitions(env, forms)
  useFormsIn(env, forms, lib)
  rest = @[]
  for f in forms:
    if evaluator.isAnyDefinition(f) or isUseForm(f):
      continue
    rest.add f
  evalForms(env, rest)

proc evaluate*(lib: Library, root: ref Environment, path: string,
    source: string): Object =
  ## Run a settings file's source and return the value of its last form.
  ## Definitions are hoisted first, so a record may call a function below it.
  var rest: seq[Object]
  var env: ref Environment
  run(lib, root, path, source, rest, env)

proc evaluateBindings*(lib: Library, root: ref Environment, path: string,
    source: string): Object =
  ## Run a settings file's source and return its top-level `name = value`
  ## bindings as a record, in the order they first appear, each with the
  ## value it ended up with. `fun`s, `command`s and `use`d names are not
  ## bindings, so helpers stay out of the record.
  var rest: seq[Object]
  var env: ref Environment
  discard run(lib, root, path, source, rest, env)
  var names: seq[Object] = @[]
  for f in rest:
    if isPair(f) and isSymbol(car(f)) and car(f) notin names:
      names.add car(f)
  var fields: seq[Object] = @[]
  for name in names:
    fields.add pair(name, lookup(env, name).get(nothing()))
  record(fields)

proc readValue*(self: AbstractSettingsObject): Object =
  ## The file's current value, read fresh off disk.
  var source = ""
  try:
    source = readFile(self.path)
  except CatchableError:
    err("cannot read settings: " & self.path)
  evaluate(self.sandbox, self.root, self.path, source)

proc settingsText*(name: SettingsTypeName, text: string): string =
  ## The file's contents: a line saying what it holds, then the data.
  result = "; " & name & " -- owl settings\n"
  result.add text
  if not result.endsWith("\n"):
    result.add "\n"

template writeText*[T](x: T): string =
  ## A value as the text of its settings file.
  settingsText(name(T), owlText(x))

# Files ------------------------------------------------------------------------

proc stampOf(path: string): string =
  ## A hash of the file's contents: what a changed mtime and what a changed
  ## byte both move, and what a save within the same second still moves.
  try:
    var ctx = newSha1State()
    ctx.update(readFile(path))
    let digest = ctx.finalize()
    const H = "0123456789abcdef"
    for b in digest:
      result.add H[int(b) shr 4]
      result.add H[int(b) and 15]
  except CatchableError:
    result = ""

proc writeFileText(path, text: string) =
  ## Write in one step the watchers can see: a temporary file renamed over the
  ## target, so a reload never reads a half-written file.
  let dir = dirOf(path)
  if dir.len > 0 and dir != ".":
    try:
      createDir(dir)
    except CatchableError:
      discard
  var failed = false
  try:
    writeFile(path & ".owl-tmp", text)
  except CatchableError:
    failed = true
  if failed:
    err("cannot write settings: " & path)
  try:
    moveFile(path & ".owl-tmp", path)
  except CatchableError:
    removeFile(path & ".owl-tmp")
    err("cannot replace settings: " & path)

proc nameFor(T: type): SettingsTypeName =
  name(T)

# The repository ---------------------------------------------------------------

proc newSettings*(hot: bool = false, quiet: bool = false): SettingsRepository =
  ## An empty repository. `hot` starts watching every file added to it.
  result = SettingsRepository(
    settings: initTable[SettingsTypeName, AbstractSettingsObject](),
    sandbox: settingsLibrary(),
    root: settingsRoot(),
    hot: hot,
    quiet: quiet)
  evaluate(result.sandbox)

proc prepare(repo: var SettingsRepository) =
  ## A zeroed `var settings: SettingsRepository` works too: this builds what
  ## `newSettings` would have.
  if not repo.opened:
    if repo.settings.len == 0:
      repo.settings = initTable[SettingsTypeName, AbstractSettingsObject]()
    if repo.sandbox == nil:
      repo.sandbox = settingsLibrary()
      evaluate(repo.sandbox)
    if repo.root == nil:
      repo.root = settingsRoot()
    repo.opened = true

proc watchOne(repo: var SettingsRepository, path: string) =
  if repo.hot:
    if repo.watch == nil:
      repo.watch = newFileWatch()
    discard repo.watch.watchFile(path)

proc addModulePath*(repo: var SettingsRepository, dir: string) =
  ## Let settings files `use` modules found in `dir`, for abstractions shared
  ## between several of them. A module loaded from a path runs in the same
  ## restricted environment and reaches the same names, never more: giving a
  ## settings file a directory gives it functions and data, not a filesystem.
  prepare(repo)
  addPath(repo.sandbox, dir)

template loadHook*(T: typedesc): LoadHook =
  ## Replace the data with what the file now holds. Serde's hooks resolve here,
  ## which is why `add` is a template: they are looked up where it is called.
  proc (self: AbstractSettingsObject) =
    let typed = cast[SettingsObject[T]](self)
    let value = readValue(self)
    typed.data = decode(value, T)

template writeHook*(T: typedesc): WriteHook =
  ## The data as the file's text.
  proc (self: AbstractSettingsObject): string =
    writeText(cast[SettingsObject[T]](self).data)

proc borrow[T](repo: var SettingsRepository, t: typedesc[T],
    key: SettingsTypeName): var T =
  if not repo.settings.hasKey(key):
    err("settings: nothing registered as " & key)
  let found = repo.settings[key]
  if not (found of SettingsObject[T]):
    err("settings: " & key & " holds a " & found.typeName & ", not a " & name(T))
  var typed = cast[SettingsObject[T]](found)
  result = typed.data

proc register[T](repo: var SettingsRepository, path: string, t: typedesc[T],
    key: SettingsTypeName, load: LoadHook, write: WriteHook): var T =
  prepare(repo)
  if repo.settings.hasKey(key):
    if repo.settings[key].path != path:
      err("settings: " & key & " is already registered from " &
        repo.settings[key].path)
    return repo.borrow(t, key)
  var obj = SettingsObject[T](path: path, typeName: key, sandbox: repo.sandbox,
    root: repo.root, load: load, write: write)
  repo.settings[key] = obj
  if fileExists(path):
    obj.stamp = stampOf(path)
    try:
      obj.load(obj)
    except ValueError:
      obj.error = lastErrorMessage
      raise   # the defaults are still in place; the caller decides
  else:
    writeFileText(path, obj.write(obj))
    obj.stamp = stampOf(path)
  repo.watchOne(path)
  result = obj.data

template add*[T](repo: var SettingsRepository, path: string,
    t: typedesc[T], name: SettingsTypeName = ""): var T =
  ## Register `T`, backed by `path`: the file is read into the data, or written
  ## from `default(T)` when it is not there yet. Returns a mutable borrow of it.
  ##
  ## Binding the result to a `var` copies it, as Nim does; reach the stored data
  ## through `get`, or assign through this borrow where it is called.
  register(repo, path, t, if name.len > 0: name else: nameFor(t),
    loadHook(t), writeHook(t))

proc get*[T](repo: var SettingsRepository, t: typedesc[T],
    name: SettingsTypeName = ""): var T =
  ## A mutable borrow of the registered data, by type or by the name it was
  ## registered under. Raises when nothing is registered as that type.
  prepare(repo)
  repo.borrow(T, if name.len > 0: name else: nameFor(t))

proc has*[T](repo: var SettingsRepository, t: typedesc[T],
    name: SettingsTypeName = ""): bool =
  ## Whether a `T` (under that name) is registered.
  prepare(repo)
  let key = if name.len > 0: name else: nameFor(t)
  repo.settings.hasKey(key) and repo.settings[key] of SettingsObject[T]

# Reading and writing the files ------------------------------------------------

proc reload*(repo: var SettingsRepository, name: SettingsTypeName): bool =
  ## Read a registered file again, whatever it says about changes: the file's
  ## data replaces the in-memory data. False, with the reason in `errorOf`,
  ## when the file no longer reads.
  prepare(repo)
  if not repo.settings.hasKey(name):
    err("settings: nothing registered as " & name)
  var obj = repo.settings[name]
  obj.stamp = stampOf(obj.path)
  try:
    obj.load(obj)
    obj.error = ""
    result = true
  except ValueError:
    obj.error = lastErrorMessage
    if not repo.quiet:
      report(errorText(colorErrors))
    result = false

proc reloadAll*(repo: var SettingsRepository): int =
  ## Reload every registered file. Returns how many took.
  prepare(repo)
  for obj in repo.settings.values:
    if repo.reload(obj.typeName):
      inc result

proc save*[T](repo: var SettingsRepository, t: typedesc[T],
    name: SettingsTypeName = "") =
  ## Write the data out, replacing the file. The borrow from `get` is where the
  ## program's own changes live; this makes them the file's.
  prepare(repo)
  let key = if name.len > 0: name else: nameFor(t)
  if not repo.settings.hasKey(key):
    err("settings: nothing registered as " & key)
  var obj = repo.settings[key]
  writeFileText(obj.path, obj.write(obj))
  obj.stamp = stampOf(obj.path)
  obj.error = ""

proc saveAll*(repo: var SettingsRepository) =
  ## Write out every registered file.
  prepare(repo)
  for obj in repo.settings.values:
    writeFileText(obj.path, obj.write(obj))
    obj.stamp = stampOf(obj.path)

# Hot loading ------------------------------------------------------------------

proc hotReload*(repo: var SettingsRepository, on: bool = true) =
  ## Watch the registered files, or stop. Watching is optional: a repository
  ## that never watches still reloads through `reload`, and `checkForChanges`
  ## works either way, because a change is decided by the file's contents --
  ## including where there is no descriptor to wait on (Windows), where the
  ## watcher polls its change notifications instead.
  prepare(repo)
  repo.hot = on
  if on:
    for obj in repo.settings.values:
      repo.watchOne(obj.path)
  elif repo.watch != nil:
    repo.watch.close()
    repo.watch = nil

proc descriptor*(repo: var SettingsRepository): int32 =
  ## The descriptor that turns readable when a watched file changes, for an
  ## event loop (`watchFd` in the ellipse platform layer); -1 when there is
  ## none to wait on. Its callback calls `checkForChanges`.
  if repo.watch == nil: -1'i32 else: repo.watch.descriptor

proc checkForChanges*(repo: var SettingsRepository): int =
  ## Reload every file whose contents changed since it was last read -- the
  ## watcher's events, if any, only say when to look; the hash says what moved.
  ## Returns how many files were reloaded, and leaves a file that stopped
  ## reading on its old data with the reason in `errorOf`.
  prepare(repo)
  if repo.watch != nil:
    discard repo.watch.poll()
  for obj in repo.settings.values:
    let stamp = stampOf(obj.path)
    if stamp.len > 0 and stamp != obj.stamp:
      obj.stamp = stamp
      try:
        obj.load(obj)
        obj.error = ""
        inc result
      except ValueError:
        obj.error = lastErrorMessage
        if not repo.quiet:
          report(errorText(colorErrors))

proc close*(repo: var SettingsRepository) =
  ## Give up the watcher's descriptor. Registered data is left alone.
  if repo.watch != nil:
    repo.watch.close()
    repo.watch = nil
  repo.hot = false

# What is registered -----------------------------------------------------------

proc names*(repo: var SettingsRepository): seq[SettingsTypeName] =
  ## Every registered name, newest last.
  prepare(repo)
  result = @[]
  for key in repo.settings.keys:
    result.add key

proc pathOf*(repo: var SettingsRepository, name: SettingsTypeName): string =
  ## The file a registration reads and writes.
  prepare(repo)
  if repo.settings.hasKey(name): repo.settings[name].path else: ""

proc errorOf*(repo: var SettingsRepository, name: SettingsTypeName): string =
  ## What the last load of that file rejected, or "" when it read clean. A
  ## reload that failed leaves the old data serving and the reason here.
  prepare(repo)
  if repo.settings.hasKey(name): repo.settings[name].error else: ""

proc remove*(repo: var SettingsRepository, name: SettingsTypeName) =
  ## Forget a registration; the file on disk is left as it is.
  prepare(repo)
  repo.settings.del(name)

proc count*(repo: var SettingsRepository): int =
  ## How many settings are registered.
  repo.settings.len
