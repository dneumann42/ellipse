import std/[syncio, strutils]
import owl/[objects, evaluator, modules]
import owl/libraries/[base, math]
import ./testutils

captureStdio()

# source.owl is loaded from the tree, so these tests exercise the same code
# the owl binary embeds.
proc sourceEnv(): ref Environment {.raises.} =
  let lib = newLibrary("source-test")
  add(lib, baseModule())
  add(lib, mathModule())
  add(lib, newModule("strings").addFile("src/owl/libraries/strings.owl"))
  add(lib, newModule("source").addFile("src/owl/libraries/source.owl"))
  evaluate(lib)
  result = newEnvironment()
  for m in lib.modules.values:
    if m.name == "source" or m.name == "base":
      useModule(result, m)

proc loadEnv(): ref Environment =
  try:
    result = sourceEnv()
  except:
    quit "cannot load source.owl: " & lastError()

let env = loadEnv()

proc call(name: string, args: seq[string]): Object {.raises.} =
  var form = @[symbol(name)]
  for a in args:
    form.add str(a)
  eval(list(form), env)

proc edit(name: string, args: seq[string]): string =
  try:
    result = toStr(call(name, args))
  except:
    expect false, name & " should succeed: " & lastError()
    result = ""

proc refuses(name: string, args: seq[string], needle: string) =
  var failed = false
  try:
    discard call(name, args)
  except:
    failed = true
  expect failed, name & " should refuse: " & needle
  if failed:
    expect find(lastError(), needle) >= 0,
      "error mentions '" & needle & "', got: " & lastError()

proc itemsOf(text: string): seq[Object] =
  try:
    result = toSeq(call("source-items", @[text]))
  except:
    expect false, "source-items should succeed: " & lastError()
    result = @[]

proc describe(text: string): seq[string] =
  # kind:name@line[start..end) for each item
  result = @[]
  for it in itemsOf(text):
    let name = field(it, "name")
    result.add toStr(field(it, "kind")) & ":" &
      (if isNothing(name): "-" else: toStr(name)) & "@" &
      $int(toNumber(field(it, "line"))) & "[" &
      $int(toNumber(field(it, "start"))) & ".." & $int(toNumber(field(it, "end"))) & ")"

let module = """; header comment, stays put

use base

; doubles
; a number
fun double x:
    * x 2

limit = 10

fun spaced a:
    first a

; inside the body, kept
    second a
    ; trailing indented comment, kept

command twice body+:
    body

double 4
"""

expect describe(module) == @[
  "use:-@3[2..3)",
  "fun:double@7[4..8)",
  "binding:limit@10[9..10)",
  "fun:spaced@12[11..17)",
  "command:twice@19[18..20)",
  "statement:-@22[21..22)"], "items and spans: " & describe(module).join(" ")

# Rewriting any item with its own text, or with its code alone, is no change.
block identity:
  for key in ["#1", "double", "limit", "spaced", "twice", "#6"]:
    var text = ""
    for it in itemsOf(module):
      let name = field(it, "name")
      let label = if isNothing(name): "#" & $int(toNumber(field(it, "ordinal"))) else: toStr(name)
      if label == key:
        text = toStr(field(it, "text"))
    expect edit("update-item", @[module, key, text]) == module, "identity edit of " & key
    expect edit("update-item", @[module, key, text & "\n\n"]) == module,
      "trailing blank lines in new code are ignored for " & key

# update keeps the old leading comment unless the new code brings one.
block update:
  let kept = edit("update-item", @[module, "double", "fun double x:\n    + x x"])
  expect kept == module.replace("    * x 2", "    + x x"), "comment kept:\n" & kept
  let swapped = edit("update-item", @[module, "double", "; new doc\nfun double y:\n    + y y\n"])
  expect swapped == module.replace("; doubles\n; a number\nfun double x:\n    * x 2",
    "; new doc\nfun double y:\n    + y y"), "comment replaced:\n" & swapped
  refuses("update-item", @[module, "double", "fun triple x:\n    * x 3"], "defines triple, not double")
  refuses("update-item", @[module, "double", "double = 2"], "is a fun, not a binding")
  refuses("update-item", @[module, "nope", "fun nope:\n    1"], "no item named nope")
  refuses("update-item", @[module, "#9", "1"], "no item #9")
  refuses("update-item", @[module, "double", "fun double x:\n    1\nfun other:\n    2"], "expected one item, got 2")
  refuses("update-item", @[module, "double", "fun double x:\n    1\n; loose\n\nfun other:\n    2"], "line 3 is outside of any item: ; loose")
  refuses("update-item", @[module, "double", "    fun double x:"], "read error")
  let stmt = edit("update-item", @[module, "#6", "double 5"])
  expect stmt == module.replace("double 4", "double 5"), "a statement is updated by position"

block add:
  let added = edit("add-item", @[module, "fun half x:\n    / x 2\n"])
  expect added == module & "\nfun half x:\n    / x 2\n", "appended after a blank line:\n" & added
  expect edit("add-item", @["", "x = 1"]) == "x = 1\n", "add to an empty module"
  expect edit("add-item", @["x = 1\n", "y = 2"]) == "x = 1\n\ny = 2\n", "keeps the final newline"
  expect edit("add-item", @["x = 1", "y = 2"]) == "x = 1\n\ny = 2", "adds no final newline"
  expect edit("add-item", @["x = 1\n\n\n", "y = 2"]) == "x = 1\n\ny = 2\n\n\n", "keeps trailing blank lines after"
  expect edit("add-item", @["x = 1\n", "y = 2\n\nz = 3\n"]) == "x = 1\n\ny = 2\n\nz = 3\n", "adds several"
  refuses("add-item", @[module, "fun double x:\n    1"], "double is already defined")
  refuses("add-item", @[module, "y = 1\n; loose comment\n\nz = 2"], "line 2 is outside of any item")
  refuses("add-item", @[module, ""], "no code given")

block put:
  let both = edit("put-item", @[module, "limit = 20\n\nfun half x:\n    / x 2\n"])
  expect both == module.replace("limit = 10", "limit = 20") & "\nfun half x:\n    / x 2\n",
    "put updates and adds:\n" & both

block remove:
  expect edit("remove-item", @[module, "limit"]) == module.replace("limit = 10\n\n", ""),
    "middle item and one blank"
  expect edit("remove-item", @[module, "double"]) ==
    module.replace("; doubles\n; a number\nfun double x:\n    * x 2\n\n", ""), "with its leading comment"
  expect edit("remove-item", @[module, "#6"]) == module.replace("\ndouble 4\n", ""), "last item keeps final newline"
  expect edit("remove-item", @["x = 1\n\ny = 2\n", "x"]) == "y = 2\n", "first item"
  expect edit("remove-item", @["x = 1\n", "x"]) == "", "only item"
  expect edit("remove-item", @["x = 1\ny = 2\n", "x"]) == "y = 2\n", "no blank lines involved"

block duplicates:
  let twice = "fun f:\n    1\n\nfun f:\n    2\n"
  refuses("update-item", @[twice, "f", "fun f:\n    3"], "f is defined 2 times, name it by position: #1 (line 1), #2 (line 4)")
  expect edit("update-item", @[twice, "#2", "fun f:\n    3"]) == "fun f:\n    1\n\nfun f:\n    3\n",
    "a duplicate is updated by position"

block crlf:
  let dos = "x = 1\r\n\r\nfun f:\r\n    2\r\n"
  expect describe(dos) == @["binding:x@1[0..1)", "fun:f@3[2..4)"], "CRLF spans: " & describe(dos).join(" ")
  expect edit("remove-item", @[dos, "x"]) == "fun f:\r\n    2\r\n", "CRLF blank lines count as blank"

block shapes:
  expect describe("fun f\nexport:\n    f = f\n(g) = 1\n") ==
    @["statement:-@1[0..1)", "export:-@2[1..3)", "statement:-@4[3..4)"],
    "a fun without a block, export and a grouped binding: " &
    describe("fun f\nexport:\n    f = f\n(g) = 1\n").join(" ")
  refuses("source-items", @["x = (\n"], "read error")

finish("source")
