import std/syncio
import ./[objects, reader, evaluator, modules, embedfile]
import ./libraries/[base, math, io, term, fs, loader, net, gui]


var programLib: Library = nil

proc runFileBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object  =
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
  let forms = readSource(source, toStr(path))
  let lib = programLib
  if lib == nil:
    err("run-file has no library to run against")
  else:
    discard runProgram(lib, forms)
  nothing()

proc programModule(): Module =
  result = newModule("program").addBuiltin("run-file", runFileBuiltin, true)

proc owlLibrary*(): Library  =
  let lib = newLibrary("owl")
  programLib = lib
  lib.add baseModule()
  lib.add mathModule()
  lib.add ioModule()
  lib.add programModule()
  lib.add termModule()
  lib.add fsModule()
  lib.add loaderModule(lib)
  lib.add newModule("iterators").addLibrarySource(embedFile("libraries/iterators.owl"))
  lib.add newModule("strings").addLibrarySource(embedFile("libraries/strings.owl"))
  lib.add newModule("ansi").addLibrarySource(embedFile("libraries/ansi.owl"))
  lib.add newModule("keys").addLibrarySource(embedFile("libraries/keys.owl"))
  lib.add newModule("editor").addLibrarySource(embedFile("libraries/editor.owl"))
  lib.add newModule("tui").addLibrarySource(embedFile("libraries/tui.owl"))
  lib.add newModule("cmdline").addLibrarySource(embedFile("libraries/cmdline.owl"))
  lib.add newModule("source").addLibrarySource(embedFile("libraries/source.owl"))
  lib.add newModule("live").addLibrarySource(embedFile("libraries/live.owl"))
  lib.add newModule("projects").addLibrarySource(embedFile("libraries/projects.owl"))
  lib.add netModule()
  lib.add newModule("wire").addLibrarySource(embedFile("libraries/wire.owl"))
  lib.add newModule("repl").addLibrarySource(embedFile("scripts/repl.owl"))
  lib.add newModule("repl-app").addLibrarySource(embedFile("scripts/repl-app.owl"))
  lib.add newModule("attach").addLibrarySource(embedFile("libraries/attach.owl"))
  lib.add guiModule(embedFile("libraries/gui.owl"))
  result = lib

