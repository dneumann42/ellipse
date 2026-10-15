
import std/[macros, os]

macro embedFile*(path: untyped): untyped =
  if path.kind != nnkStrLit:
    error("embedFile needs a string literal path", path)
  let raw = path.strVal
  let caller = path.lineInfoObj.filename
  var full = raw
  if caller.len > 0 and not raw.isAbsolute:
    full = parentDir(caller) / raw
  var content = ""
  var failed = false
  try:
    content = readFile(full)
  except:
    failed = true
  if failed:
    error("embedFile cannot read: " & full, path)
  newLit(content)
