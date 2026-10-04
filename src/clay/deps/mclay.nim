## Nimony template plugin: brackets element declarations.
##
## Rewrites
##   clay "label", decl:      ->  openElement(makeId(H, H, "label"), decl)
##   ...body...                   ...body...
##                                closeElement()
## and the auto-id form `clay decl: body` to `openElement(decl)` + body +
## `closeElement()`. `H` is Clay's string hash of the label, computed HERE at
## compile time (the CLAY_ID equivalent) and emitted as an integer literal.
##
## Input shape (verified against nifler output):
##   (stmts clay <label-str>? <decl-call> (stmts body...))

import plugins
import std/[syncio, envvars]


func hashString(label: string): uint32 =
  # Clay__HashString with seed 0 -- keep in sync with clay/hashing.nim.
  var hash = 0'u32
  for c in label:
    hash += uint32(ord(c))
    hash += hash shl 10
    hash = hash xor (hash shr 6)
  hash += hash shl 3
  hash = hash xor (hash shr 11)
  hash += hash shl 15
  hash + 1

proc emitId(r: var NifBuilder; info: LineInfo; h: uint32; label: string) =
  ## (call makeId <h> <h> <"label">) -- ElementId resolved at compile time.
  r.withTree CallX, info:
    r.addIdent "makeId"
    r.addIntLit int64(h)
    r.addIntLit int64(h)
    r.addStrLit label

proc emitOpen(r: var NifBuilder; info: LineInfo; args: var NifCursor) =
  ## (call openElement <id-expr>?) followed by (call configureOpenElement
  ## <decl>) -- split exactly like Clay's OpenElement + ConfigureOpenElement
  ## macro pair, so declaration expressions (e.g. `currentScrollOffset()`)
  ## evaluate with the element already open.
  if args.kind == StrLit:
    # named form: build the compile-time-hashed ElementId
    let label = args.stringValue
    let h = hashString(label)
    args.inc()
    r.withTree CallS, info:
      r.addIdent "openElement"
      emitId(r, info, h, label)
  else:
    r.withTree CallS, info:
      r.addIdent "openElement"
  r.withTree CallS, info:
    r.addIdent "configureOpenElement"
    r.takeTree args          # the declaration expression (advances args)

proc transform(n: NifCursor): NifBuilder =
  result = createTree()
  let info = n.info
  var args = callArgs(n)

  result.withTree StmtsS, info:
    emitOpen(result, info, args)
    # args now sits on the body `(stmts ...)` node: splice its children in.
    if args.hasMore:
      args.into:
        while args.hasMore:
          result.takeTree args   # takeTree advances the cursor
    result.withTree CallS, info:
      result.addIdent "closeElement"

  if getEnv("CLAY_DSL_DEBUG") != "":
    try:
      writeFile("/tmp/opencode/mclay-output.nif", renderTree(result))
    except ErrorCode:
      discard

var inp = loadPluginInput()
saveTree transform(inp)
