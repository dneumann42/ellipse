import std/syncio
import objects, reader, evaluator, modules
import libraries/[base, math, io, term, fs, loader]

# The owl sources are baked into the binary at build time (see
# libraries/deps/embedFile.nim), so bin/owl runs from any directory.
template embedFile(path: string): string {.plugin: "libraries/deps/embedFile".}

var programLib: nil Library = nil

proc runFileBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  if args.len != 1:
    err("run-file needs one path")
  let path = eval(args[0], env)
  if not isString(path):
    err("run-file needs a string path, got " & stringify(path))
  var source = ""
  var failed = false
  try:
    source = readFile(toStr(path))
  except:
    failed = true
  if failed:
    err("cannot open file: " & toStr(path))
  let parsed = parseOwl(source)
  if not parsed.isOk:
    err(toStr(path) & ": " & parsed.error("parse error"))
  let lib = programLib
  if lib == nil:
    err("run-file has no library to run against")
  else:
    discard runProgram(lib, parsed.get(@[]))
  nothing()

proc programModule(): Module =
  result = newModule("program").addBuiltin("run-file", runFileBuiltin, true)

proc start() {.raises.} =
  let lib = newLibrary("owl")
  programLib = lib
  lib.add baseModule()
  lib.add mathModule()
  lib.add ioModule()
  lib.add programModule()
  lib.add termModule()
  lib.add fsModule()
  lib.add loaderModule(lib)
  lib.add newModule("iterators").addSource(embedFile("libraries/iterators.owl"))
  lib.add newModule("strings").addSource(embedFile("libraries/strings.owl"))
  lib.add newModule("ansi").addSource(embedFile("libraries/ansi.owl"))
  lib.add newModule("keys").addSource(embedFile("libraries/keys.owl"))
  lib.add newModule("editor").addSource(embedFile("libraries/editor.owl"))
  lib.add newModule("tui").addSource(embedFile("libraries/tui.owl"))
  lib.add newModule("cmdline").addSource(embedFile("libraries/cmdline.owl"))
  lib.add newModule("source").addSource(embedFile("libraries/source.owl"))
  lib.add newModule("live").addSource(embedFile("libraries/live.owl"))
  lib.add newModule("projects").addSource(embedFile("libraries/projects.owl"))
  lib.add newModule("repl").addSource(embedFile("scripts/repl.owl"))
  lib.add newModule("cli").addSource(embedFile("scripts/cli.owl"))
  evaluate(lib)

when isMainModule:
  try:
    start()
  except:
    # err() already reported the reason through errorReport; the handler
    # must not touch `exc` because bare raises have no exception object.
    quit 1
