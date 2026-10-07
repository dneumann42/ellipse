import std/syncio
import ./[modules, library]

# The sources are embedded at build time (library.nim), so bin/owl runs from
# any directory. The command line itself is owl: scripts/cli.owl.
template embedFile(path: string): string {.plugin: "libraries/deps/embedFile".}

proc start() {.raises.} =
  let lib = owlLibrary()
  lib.add newModule("cli").addSource(embedFile("scripts/cli.owl"))
  evaluate(lib)

when isMainModule:
  try:
    start()
  except:
    # err() already reported the reason through errorReport; the handler
    # must not touch `exc` because bare raises have no exception object.
    quit 1
