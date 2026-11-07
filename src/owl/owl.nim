import std/syncio
import ./[modules, library, evaluator, embedfile]
import ./libraries/term


proc start() =
  let lib = owlLibrary()
  lib.add newModule("cli").addLibrarySource(embedFile("scripts/cli.owl"))
  evaluate(lib)

when isMainModule:
  colorErrors = stderrIsTerminal()
  try:
    start()
  except CatchableError:
    flushFile(stdout)
    reportError()
    quit 1
