## Nimony template plugin: compile-time Clay id hashing.
##
## `hashId("some label")` evaluates Clay's string hash at compile time and
## emits `makeId(H, H, "some label")`, the equivalent of CLAY_ID("...").

import plugins

func hashNumber(offset, seed: uint32): uint32 =
  var hash = seed
  hash += offset + 48
  hash += hash shl 10
  hash = hash xor (hash shr 6)
  hash += hash shl 3
  hash = hash xor (hash shr 11)
  hash += hash shl 15
  hash + 1

func hashString(label: string; seed: uint32 = 0): uint32 =
  var hash = seed
  for c in label:
    hash += uint32(ord(c))
    hash += hash shl 10
    hash = hash xor (hash shr 6)
  hash += hash shl 3
  hash = hash xor (hash shr 11)
  hash += hash shl 15
  hash + 1

proc transform(n: NifCursor): NifBuilder =
  result = createTree()
  var args = callArgs(n)
  if args.kind != StrLit:
    return errorTree("hashId expects a string literal", args)
  let label = args.stringValue
  let h = hashString(label, 0)
  let info = n.info
  result.withTree CallX, info:
    result.addIdent "makeId"
    result.addIntLit int64(h)
    result.addIntLit int64(h)
    result.addStrLit label

var inp = loadPluginInput()
saveTree transform(inp)
