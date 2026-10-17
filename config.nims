# begin Nimble config (version 2)
when withDir(thisDir(), system.fileExists("nimble.paths")):
  include "nimble.paths"
# end Nimble config

# The GUI kit: `import clay` (ellipse_ui, tests, examples) resolves from
# src/clay -- same flag the source kit's Makefile passes (nim does not
# treat `src/clay/clay.nim` as reachable through `-p:src`).
when withDir(thisDir(), system.fileExists("src/clay/clay.nim")):
  switch("path", thisDir() & "/src/clay")
