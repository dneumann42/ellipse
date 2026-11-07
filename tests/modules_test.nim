import std/[syncio, options, tables, strutils, unittest]
import owl/[objects, reader, evaluator, modules]
import owl/libraries/[base, math]
import ./testutils

captureStdio()

proc expectError(needle: string) =
  if not (find(lastError(), needle) >= 0):
    raiseAssert("reported error mentions '" & needle & "', got: " & lastError())

proc parseForms(src: string): seq[Object] =
  let r = parseOwl(src)
  if not r.isOk:
    raiseAssert("parse ok, got error: " & r.error(""))
  r.get(@[])

proc value(env: ref Environment, name: string): Object =
  let found = lookup(env, symbol(name))
  if not found.isSome:
    raiseAssert("binding " & name & " exists")
  found.get()

template baseWorks() =
  let lib = newLibrary("t1")
  add(lib, baseModule())
  add(lib, mathModule())
  let env = runProgram(lib, parseForms("""
use base
use math
res = + 1 2
"""))
  check toNumber(value(env, "res")) == 3.0, "use base and math provide the internal commands"

template baseComparisonsWork() =
  let lib = newLibrary("t13")
  add(lib, baseModule())
  let env = runProgram(lib, parseForms("""
use base

r = {}:
  a = 1
  b = 2

small = < r.a r.b
same = = r.a 1
apart = <> r.a r.b
flipped = not (= r.a r.b)
"""))
  check toBool(value(env, "small")), "use base provides the ordering commands"
  check toBool(value(env, "same")), "use base provides equality"
  check toBool(value(env, "apart")), "use base provides inequality"
  check toBool(value(env, "flipped")), "use base provides not"

template indexedWorks() =
  let lib = newLibrary("t12")
  add(lib, baseModule())
  let env = runProgram(lib, parseForms("""
use base

r = {}:
  a = [] 4 5

v = r.a.1
n = length r.a
f = field r "a"
"""))
  check toNumber(value(env, "v")) == 5.0, "use base provides index for the dot syntax"
  check toNumber(value(env, "n")) == 2.0, "use base provides length"
  check stringify(value(env, "f")) == "[] 4 5", "use base provides field"

template exportUseWorks() =
  let lib = newLibrary("t2")
  add(lib, baseModule())
  add(lib, mathModule())
  add(lib, newModule("mathx").addSource("""
use base
use math

fun double x:
  * x 2

fun secret x:
  x

export:
  double = double
  shown = secret
"""))
  let env = runProgram(lib, parseForms("""
use mathx
v = double 21
w = shown 7
"""))
  check toNumber(value(env, "v")) == 42.0, "exported fun is usable via use"
  check toNumber(value(env, "w")) == 7.0, "export can rename an internal form"

template recursiveWorks() =
  let lib = newLibrary("t3")
  add(lib, baseModule())
  add(lib, mathModule())
  add(lib, newModule("a").addSource("""
use base
use math
use b

fun ping n:
  if (< n 0):
    0
    + n (pong (- n 1))

export:
  ping = ping
"""))
  add(lib, newModule("b").addSource("""
use base
use math
use a

fun pong n:
  if (< n 0):
    0
    + n (ping (- n 1))

export:
  pong = pong
"""))
  let env = runProgram(lib, parseForms("""
use a
use b
r = ping 3
s = pong 5
"""))
  check toNumber(value(env, "r")) == 6.0, "recursive modules: a uses b which uses a"
  check toNumber(value(env, "s")) == 15.0, "recursive modules: mutual calls both ways"

template selfUseWorks() =
  let lib = newLibrary("t4")
  add(lib, baseModule())
  add(lib, newModule("c").addSource("""
use base
use c

fun idf x:
  x

export:
  idf = idf
"""))
  let env = runProgram(lib, parseForms("""
use c
t = idf 9
"""))
  check toNumber(value(env, "t")) == 9.0, "a module may use itself"

template fileWorks() =
  let fixture = "build/nimcache/owl_fixture_mod.owl"
  writeFile(fixture, """
use base
use math
fun triple x:
  * x 3
export:
  triple = triple
""")
  let lib = newLibrary("t5")
  add(lib, baseModule())
  add(lib, mathModule())
  add(lib, newModule("f").addFile(fixture))
  let env = runProgram(lib, parseForms("""
use f
u = triple 4
"""))
  check toNumber(value(env, "u")) == 12.0, "module loaded from an owl file"

template manualWorks() =
  let lib = newLibrary("t6")
  add(lib, baseModule())
  let boxed = newModule("boxed").addExport("one", number(1))
  add(lib, boxed)
  let env = runProgram(lib, parseForms("""
use boxed
x = one
"""))
  check toNumber(value(env, "x")) == 1.0, "manually added export via addExport"

proc doubleBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object =
  number(toNumber(eval(args[0], env)) * 2.0)

template mixedWorks() =
  let lib = newLibrary("t9")
  add(lib, baseModule())
  add(lib, mathModule())
  let mixed = newModule("mixed").
    addSource("""
use math
fun owl-half x:
  / x 2
export:
  owl-half = owl-half
""").
    addBuiltin("nim-double", doubleBuiltin, true)
  add(lib, mixed)
  let env = runProgram(lib, parseForms("""
use mixed
a = owl-half 8
b = nim-double 5
"""))
  check toNumber(value(env, "a")) == 4.0, "owl form in a mixed module"
  check toNumber(value(env, "b")) == 10.0, "internal builtin in the same mixed module"

template nonExportedWorks() =
  var leaked = false
  clearCaptured()
  try:
    let lib = newLibrary("t7")
    add(lib, baseModule())
    add(lib, mathModule())
    add(lib, newModule("mathx").addSource("""
use base
use math

fun double x:
  * x 2

fun secret x:
  x

export:
  double = double
"""))
    discard runProgram(lib, parseForms("""
use mathx
v = secret 1
"""))
  except:
    leaked = true
  check leaked, "non-exported forms are not visible to the user"
  expectError "unbound symbol: secret"

template unknownDepWorks() =
  var missing = false
  clearCaptured()
  try:
    let lib = newLibrary("t8")
    add(lib, newModule("x").addSource("use nope"))
    evaluate(lib)
  except:
    missing = true
  check missing, "unknown module dependency fails the prepass"
  expectError "uses unknown module nope"

template parseErrorWorks() =
  var bad = false
  clearCaptured()
  try:
    discard newModule("bad").addSource("()")
  except:
    bad = true
  check bad, "module with a parse error raises"
  expectError "empty expression"

template iteratorsWork() =
  let lib = newLibrary("t14")
  add(lib, baseModule())
  add(lib, mathModule())
  add(lib, newModule("iterators").addFile("src/owl/libraries/iterators.owl"))
  let env = runProgram(lib, parseForms("""
use base
use math
use iterators

it = range 3
i0 = (it)
i1 = (it)
i2 = (it)
i3 = (it)

got = ([])
for x (range 5):
  append got x

xs = [] 10 20 30
seen = ([])
for y (items xs):
  append seen y

from2 = ([])
for z (range 2 4):
  append from2 z

pairs = ([])
for a (range 2):
  for b (range 2):
    append pairs (+ a b)

v = 100
it = 200
forms = 300
names = ([])
for k (range 2):
  append names (+ k v it forms)

nested = [] ([] 1 2) ([] 3)
sizes = ([])
for row (items nested):
  append sizes (length row)

total = 0
for q (range 4):
  step = q
  set total (+ total step)

x = 99
xs-seen = ([])
for x (range 2):
  append xs-seen x

after-x = x

hits = ([])
when true:
  for w (range 2):
    unless false:
      inner = (* w 10)
      append hits inner
"""))
  check toNumber(value(env, "i0")) == 0.0, "a range iterator yields its first value"
  check toNumber(value(env, "i2")) == 2.0, "the iterator keeps its position between calls"
  check isNothing(value(env, "i3")), "an exhausted iterator returns nothing"
  check stringify(value(env, "got")) == "[] 0 1 2 3 4", "for drives a range iterator to the end"
  check stringify(value(env, "seen")) == "[] 10 20 30", "for over items visits every element"
  check stringify(value(env, "xs")) == "[] 10 20 30", "items does not consume the source list"
  check stringify(value(env, "from2")) == "[] 2 3", "range counts from a start to a stop"
  check stringify(value(env, "pairs")) == "[] 0 1 1 2", "for loops nest and see outer bindings"
  check stringify(value(env, "names")) == "[] 600 601",
    "for's own locals (v, it, forms) never shadow the body's names"
  check stringify(value(env, "sizes")) == "[] 2 1", "for binds list values without evaluating them"
  check toNumber(value(env, "total")) == 6.0, "set in a for body reaches the caller's variables"
  check lookup(env, symbol("q")).isNone, "the loop variable ends with the loop"
  check lookup(env, symbol("step")).isNone, "names the loop body defines end with each pass"
  check toNumber(value(env, "after-x")) == 99.0, "a loop variable shadows an outer name only inside the loop"
  check stringify(value(env, "xs-seen")) == "[] 0 1", "inside the loop the loop variable wins"
  check stringify(value(env, "hits")) == "[] 0 10", "unless blocks inside for see the loop variable"
  check lookup(env, symbol("inner")).isNone, "names an unless block defines end with it"

template stringsWorks() =
  let lib = newLibrary("t17")
  add(lib, baseModule())
  add(lib, mathModule())
  add(lib, newModule("strings").addFile("src/owl/libraries/strings.owl"))
  let env = runProgram(lib, parseForms("""
use base
use math
use strings

yes = starts-with "hello" "he"
no = starts-with "hello" "lo"
short = starts-with "he" "hello"
at = find-char "hello" "l"
none = find-char "hello" "z"
last = find-last "a/b/c" "/"
nolast = find-last "abc" "/"
t = take "hello" 2
d = drop "hello" 3
"""))
  check toBool(value(env, "yes")), "starts-with matches a prefix"
  check not toBool(value(env, "no")), "starts-with rejects a non-prefix"
  check not toBool(value(env, "short")), "starts-with is false when the string is shorter"
  check toNumber(value(env, "at")) == 2.0, "find-char returns the first index"
  check isNothing(value(env, "none")), "find-char returns nothing when absent"
  check toNumber(value(env, "last")) == 3.0, "find-last returns the last index"
  check isNothing(value(env, "nolast")), "find-last returns nothing when absent"
  check stringify(value(env, "t")) == "he", "take keeps the first characters"
  check stringify(value(env, "d")) == "lo", "drop removes the first characters"

proc newCmdlineLib(name: string): Library =
  result = newLibrary(name)
  add(result, baseModule())
  add(result, mathModule())
  add(result, newModule("strings").addFile("src/owl/libraries/strings.owl"))
  add(result, newModule("cmdline").addFile("src/owl/libraries/cmdline.owl"))

template cmdlineWorks() =
  let env = runProgram(newCmdlineLib("t15"), parseForms("""
use base
use math
use cmdline

cmd = parse-arg "myprog"
short = parse-arg "-f"
long = parse-arg "--flag"
val = parse-arg "--flag=123"
eqempty = parse-arg "--flag="
it = cli-parser
"""))
  check stringify(value(env, "cmd")) == "{} (type = cmd) (name = myprog)", "a bare word parses as a cmd"
  check stringify(value(env, "short")) == "{} (type = short-flag) (flag = f)", "a dash word parses as a short-flag"
  check stringify(value(env, "long")) == "{} (type = long-flag) (flag = flag)", "a double-dash word parses as a long-flag"
  check stringify(value(env, "val")) == "{} (type = flag-value) (flag = flag) (value = 123)", "equals splits the flag from its value"
  check stringify(value(env, "eqempty")) == "{} (type = flag-value) (flag = flag) (value = )", "an empty value is preserved"
  check isCommand(value(env, "it")), "cli-parser is exported as an iterator command"

template cmdlineErrors() =
  let lib = newCmdlineLib("t16")
  var raised = false
  clearCaptured()
  try:
    discard runProgram(lib, parseForms("""
use cmdline
x = parse-arg "-"
"""))
  except:
    raised = true
  check raised, "a bare dash is a runtime error"
  check find(lastError(), "a flag needs a name") >= 0,
    "the parser names the problem, got: " & lastError()

template baseOwlWorks() =
  let lib = newLibrary("t18")
  add(lib, baseModule())
  let env = runProgram(lib, parseForms("""
use base

m = max 2 9
o = or false 4
has = is-any ([] 1)
f = first ([] 7 8)
"""))
  check toNumber(value(env, "m")) == 9.0, "base.owl defs merge into the base module"
  check toNumber(value(env, "o")) == 4.0, "owl-defined or is exported through use base"
  check toBool(value(env, "has")), "owl-defined is-any is exported through use base"
  check toNumber(value(env, "f")) == 7.0, "owl-defined first is exported through use base"

proc moduleNamed(lib: Library, name: string): Module =
  result = newModule("missing")
  for m in lib.modules.values:
    if m.name == name:
      result = m

template liveImportsWork() =
  let lib = newLibrary("t19")
  add(lib, baseModule())
  add(lib, mathModule())
  add(lib, newModule("shapes").addSource("""
use math

count = 0

fun area w h:
  * w h

fun hidden-area w h:
  area w h

export:
  area = area
  boxed = hidden-area
  count = count
"""))
  add(lib, newModule("report").addSource("""
use shapes

fun report w h:
  area w h

export:
  report = report
"""))
  let env = runProgram(lib, parseForms("""
use base
use shapes
use report
before = report 2 3
"""))
  check toNumber(value(env, "before")) == 6.0, "before the patch"
  let shapes = moduleNamed(lib, "shapes")
  let patch = parseForms("fun area w h:\n  + w h")
  makeDefinition(shapes.env, patch[0], true)
  let after = runProgram(lib, parseForms("""
use shapes
use report
direct = area 2 3
indirect = report 2 3
renamed = boxed 2 3
"""))
  check toNumber(value(after, "direct")) == 5.0, "a patched fun reaches a user of its module"
  check toNumber(value(after, "indirect")) == 5.0, "and a module that uses it"
  check toNumber(value(after, "renamed")) == 5.0, "and callers through a renamed export"
  discard evalForms(env, parseForms("again = report 2 3"))
  check toNumber(value(env, "again")) == 5.0, "an env that used the module before the patch sees it"
  discard evalForms(env, parseForms("set count 4"))
  check toNumber(exportValue(shapes, "count").get(nothing())) == 4.0,
    "set on an imported name writes the exporting module's binding"
  check toNumber(value(shapes.env, "count")) == 4.0, "inside the module too"
  discard evalForms(env, parseForms("area = 1"))
  check toNumber(value(env, "area")) == 1.0, "a definition of its own shadows an import"
  check isCommand(exportValue(shapes, "area").get(nothing())), "without touching the module"

template unboundExportFails() =
  var raised = false
  clearCaptured()
  try:
    let lib = newLibrary("t20")
    add(lib, newModule("bad").addSource("export:\n  ghost = ghost"))
    evaluate(lib)
  except:
    raised = true
  check raised, "exporting an unbound name fails"
  expectError "bad exports an unbound name: ghost"

suite "owl/modules":
  test "base": baseWorks()
  test "base comparisons": baseComparisonsWork()
  test "index/length/field": indexedWorks()
  test "export/use": exportUseWorks()
  test "recursive": recursiveWorks()
  test "self use": selfUseWorks()
  test "file": fileWorks()
  test "manual": manualWorks()
  test "mixed": mixedWorks()
  test "non-exported forms": nonExportedWorks()
  test "unknown module dependency": unknownDepWorks()
  test "module parse error": parseErrorWorks()
  test "iterators library": iteratorsWork()
  test "strings library": stringsWorks()
  test "cmdline library": cmdlineWorks()
  test "cmdline errors": cmdlineErrors()
  test "base owl merge": baseOwlWorks()
  test "live imports": liveImportsWork()
  test "unbound export": unboundExportFails()
