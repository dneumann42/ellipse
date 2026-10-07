import std/[syncio, paths, dirs, envvars]
import std/private/oscommons
import owl/[objects, evaluator, modules]

# File primitives owl cannot express itself. Everything above whole-file reads
# and writes (splitting into items, editing definitions) lives in owl, see
# source.owl.

proc c_rename(src, dst: cstring): int32 {.importc: "rename", header: "<stdio.h>".}

proc pathArg(env: ref Environment, args: seq[Object], what: string): string {.raises.} =
  if args.len < 1:
    err(what & " needs a path")
  let path = eval(args[0], env)
  if not isString(path):
    err(what & " needs a string path, got " & stringify(path))
  toStr(path)

proc readFileBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  if args.len != 1:
    err("read-file needs one path")
  let path = pathArg(env, args, "read-file")
  var source = ""
  var failed = false
  try:
    source = readFile(path)
  except:
    failed = true
  if failed:
    err("cannot read file: " & path)
  str(source)

proc writeFileBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # write-file path text replaces the file as a whole: the text goes to a
  # sibling temp file that is then renamed over the path, so a reader never
  # sees half a module.
  if args.len != 2:
    err("write-file needs a path and a string")
  let path = pathArg(env, args, "write-file")
  let text = eval(args[1], env)
  if not isString(text):
    err("write-file needs a string to write, got " & stringify(text))
  let tmp = path & ".owl-tmp"
  var failed = false
  try:
    writeFile(tmp, toStr(text))
  except:
    failed = true
  if failed:
    err("cannot write file: " & tmp)
  var src = tmp
  var dst = path
  if c_rename(src.toCString, dst.toCString) != 0:
    err("cannot replace file: " & path)
  nothing()

proc fileExistsBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  if args.len != 1:
    err("file-exists needs one path")
  boolean(fileExists(pathArg(env, args, "file-exists")))

proc dirExistsBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  if args.len != 1:
    err("dir-exists needs one path")
  boolean(dirExists(pathArg(env, args, "dir-exists")))

proc listDirBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # list-dir path gives the entries of a directory, sorted by name, as
  # records with a name and a kind, "file" or "dir".
  if args.len != 1:
    err("list-dir needs one path")
  let dir = pathArg(env, args, "list-dir")
  if not dirExists(dir):
    err("not a directory: " & dir)
  var names: seq[string] = @[]
  var kinds: seq[string] = @[]
  var failed = false
  try:
    for kind, entry in walkDir(path(dir), relative = true):
      names.add $entry
      kinds.add(if kind == pcDir or kind == pcLinkToDir: "dir" else: "file")
  except:
    failed = true
  if failed:
    err("cannot list directory: " & dir)
  var order: seq[int] = @[]
  for i in 0 ..< names.len:
    order.add i
  # insertion sort by name, so listings are stable across file systems
  for i in 1 ..< order.len:
    var j = i
    while j > 0 and names[order[j - 1]] > names[order[j]]:
      let a = order[j - 1]
      let b = order[j]
      order[j - 1] = b
      order[j] = a
      dec j
  var entries: seq[Object] = @[]
  for i in order:
    entries.add record(@[pair(symbol("name"), str(names[i])),
      pair(symbol("kind"), str(kinds[i]))])
  list(entries)

proc makeDirBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # make-dir path creates a directory and any missing parents.
  if args.len != 1:
    err("make-dir needs one path")
  let dir = pathArg(env, args, "make-dir")
  var failed = false
  try:
    createDir(path(dir))
  except:
    failed = true
  if failed or not dirExists(dir):
    err("cannot create directory: " & dir)
  nothing()

proc currentDirBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  if args.len != 0:
    err("current-dir takes no arguments")
  var dir = ""
  var failed = false
  try:
    dir = $dirs.getCurrentDir()
  except:
    failed = true
  if failed:
    err("cannot read the current directory")
  str(dir)

proc changeDirBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # change-dir path makes path the current directory, which relative paths
  # are then read against.
  if args.len != 1:
    err("change-dir needs one path")
  let dir = pathArg(env, args, "change-dir")
  var failed = false
  try:
    setCurrentDir(path(dir))
  except:
    failed = true
  if failed:
    err("cannot change to directory: " & dir)
  nothing()

proc envVarBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # env-var name: the environment variable's value, or nothing when unset.
  if args.len != 1:
    err("env-var needs a name")
  let name = pathArg(env, args, "env-var")
  if existsEnv(name):
    result = str(getEnv(name))
  else:
    result = nothing()

proc installFs*(env: ref Environment) =
  define(env, symbol("read-file"), newBuiltin("read-file", readFileBuiltin, true))
  define(env, symbol("write-file"), newBuiltin("write-file", writeFileBuiltin, true))
  define(env, symbol("file-exists"), newBuiltin("file-exists", fileExistsBuiltin, true))
  define(env, symbol("dir-exists"), newBuiltin("dir-exists", dirExistsBuiltin, true))
  define(env, symbol("list-dir"), newBuiltin("list-dir", listDirBuiltin, true))
  define(env, symbol("make-dir"), newBuiltin("make-dir", makeDirBuiltin, true))
  define(env, symbol("env-var"), newBuiltin("env-var", envVarBuiltin, true))
  define(env, symbol("change-dir"), newBuiltin("change-dir", changeDirBuiltin, true))
  define(env, symbol("current-dir"), newBuiltin("current-dir", currentDirBuiltin, true))

proc fsModule*(): Module =
  result = newModule("fs")
  installFs(result.env)
  exportAllBindings(result)
