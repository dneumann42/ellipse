# embedFile — a template plugin that reads a file at COMPILE TIME and expands
# `embedFile("path")` into its contents as a string literal. This is Nimony's
# replacement for `staticRead` (which this toolchain does not provide): the
# plugin runs as a subprocess during semcheck, so `readFile` here executes at
# build time and the text is baked into the produced NIF.
#
# The path is resolved relative to the file that CALLS embedFile (read from the
# literal's line info), not the compiler's working directory, so the build works
# from any cwd. `dependsOn` records the read so the build reruns this plugin —
# and rechecks the module — whenever the file changes.

import plugins
import std/[syncio, os]

proc tr(n: NifCursor): NifBuilder =
  var args = callArgs(n)
  if not args.hasMore or args.kind != StrLit:
    return errorTree("embedFile needs a string literal path", n)
  let raw = args.stringValue
  let caller = filePath(args.info)
  var path = raw
  if caller.len > 0 and not raw.isAbsolute:
    path = parentDir(caller) / raw
  dependsOn path
  var content = ""
  var failed = false
  try:
    content = readFile(path)
  except:
    failed = true
  if failed:
    return errorTree("embedFile cannot read: " & path, n)
  result = createTree()
  result.addStrLit content

var inp = loadPluginInput()
saveTree tr(inp)
