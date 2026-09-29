import std/syncio
import objects, reader, evaluator, modules
import libraries/[base, math, io]

proc start() {.raises.} =
  let lib = newLibrary("owl")
  lib.add baseModule()
  lib.add mathModule()
  lib.add ioModule()
  lib.add newModule("cli").addFile("src/owl/scripts/cli.owl")
  evaluate(lib)

when isMainModule:
  try:
    start()
  except:
    # err() already reported the reason through errorReport; the handler
    # must not touch `exc` because bare raises have no exception object.
    quit 1
