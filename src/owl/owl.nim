import std/syncio
import ./[modules, library, evaluator]
import ./libraries/term

# The sources are embedded at build time (library.nim), so bin/owl runs from
# any directory. The command line itself is owl: scripts/cli.owl.
template embedFile(path: string): string {.plugin: "libraries/deps/embedFile".}

proc start() {.raises.} =
  let lib = owlLibrary()
  lib.add newModule("cli").addLibrarySource(embedFile("scripts/cli.owl"))
  evaluate(lib)

when isMainModule:
  colorErrors = stderrIsTerminal()
  try:
    start()
  except:
    # The error is in currentError (bare raises have no exception object):
    # show its window, after what the program printed.
    flushFile(stdout)
    reportError()
    quit 1
