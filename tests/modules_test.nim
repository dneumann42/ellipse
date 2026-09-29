import std/[syncio, options, result, tables, strutils]
import owl/[objects, reader, evaluator, modules]
import owl/libraries/[base, math]
import ./testutils

captureStdio()

proc expectError(needle: string) =
  expect find(lastError(), needle) >= 0,
    "reported error mentions '" & needle & "', got: " & lastError()

proc parseForms(src: string): seq[Object] =
  let r = parseOwl(src)
  expect r.isOk, "parse ok, got error: " & r.error("")
  result = r.get(@[])

proc value(env: ref Environment, name: string): Object =
  let found = lookup(env, symbol(name))
  expect found.isSome, "binding " & name & " exists"
  result = if found.isSome: found.get() else: nothing()

proc baseWorks() {.raises.} =
  let lib = newLibrary("t1")
  add(lib, baseModule())
  add(lib, mathModule())
  let env = runProgram(lib, parseForms("""
use base
use math
res = + 1 2
"""))
  expect toNumber(value(env, "res")) == 3.0, "use base and math provide the internal commands"

proc baseComparisonsWork() {.raises.} =
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
  expect toBool(value(env, "small")), "use base provides the ordering commands"
  expect toBool(value(env, "same")), "use base provides equality"
  expect toBool(value(env, "apart")), "use base provides inequality"
  expect toBool(value(env, "flipped")), "use base provides not"

proc indexedWorks() {.raises.} =
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
  expect toNumber(value(env, "v")) == 5.0, "use base provides index for the dot syntax"
  expect toNumber(value(env, "n")) == 2.0, "use base provides length"
  expect stringify(value(env, "f")) == "[] 4 5", "use base provides field"

proc exportUseWorks() {.raises.} =
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
  expect toNumber(value(env, "v")) == 42.0, "exported fun is usable via use"
  expect toNumber(value(env, "w")) == 7.0, "export can rename an internal form"

proc recursiveWorks() {.raises.} =
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
  expect toNumber(value(env, "r")) == 6.0, "recursive modules: a uses b which uses a"
  expect toNumber(value(env, "s")) == 15.0, "recursive modules: mutual calls both ways"

proc selfUseWorks() {.raises.} =
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
  expect toNumber(value(env, "t")) == 9.0, "a module may use itself"

proc fileWorks() {.raises.} =
  let fixture = "nimcache/owl_fixture_mod.owl"
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
  expect toNumber(value(env, "u")) == 12.0, "module loaded from an owl file"

proc manualWorks() {.raises.} =
  let lib = newLibrary("t6")
  add(lib, baseModule())
  let boxed = newModule("boxed").addExport("one", number(1))
  add(lib, boxed)
  let env = runProgram(lib, parseForms("""
use boxed
x = one
"""))
  expect toNumber(value(env, "x")) == 1.0, "manually added export via addExport"

proc doubleBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  number(toNumber(eval(args[0], env)) * 2.0)

proc mixedWorks() {.raises.} =
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
  expect toNumber(value(env, "a")) == 4.0, "owl form in a mixed module"
  expect toNumber(value(env, "b")) == 10.0, "internal builtin in the same mixed module"

check("base", baseWorks)
check("base comparisons", baseComparisonsWork)
check("index/length/field", indexedWorks)
check("export/use", exportUseWorks)
check("recursive", recursiveWorks)
check("self use", selfUseWorks)
check("file", fileWorks)
check("manual", manualWorks)
check("mixed", mixedWorks)

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
expect leaked, "non-exported forms are not visible to the user"
expectError "unbound symbol: secret"

var missing = false
clearCaptured()
try:
  let lib = newLibrary("t8")
  add(lib, newModule("x").addSource("use nope"))
  evaluate(lib)
except:
  missing = true
expect missing, "unknown module dependency fails the prepass"
expectError "uses unknown module nope"

var bad = false
clearCaptured()
try:
  discard newModule("bad").addSource("()")
except:
  bad = true
expect bad, "module with a parse error raises"
expectError "empty expression"

proc iteratorsWork() {.raises.} =
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
"""))
  expect toNumber(value(env, "i0")) == 0.0, "a range iterator yields its first value"
  expect toNumber(value(env, "i2")) == 2.0, "the iterator keeps its position between calls"
  expect isNothing(value(env, "i3")), "an exhausted iterator returns nothing"
  expect stringify(value(env, "got")) == "[] 0 1 2 3 4", "for drives a range iterator to the end"
  expect stringify(value(env, "seen")) == "[] 10 20 30", "for over items visits every element"
  expect stringify(value(env, "xs")) == "[] 10 20 30", "items does not consume the source list"
  expect stringify(value(env, "from2")) == "[] 2 3", "range counts from a start to a stop"
  expect stringify(value(env, "pairs")) == "[] 0 1 1 2", "for loops nest and see outer bindings"

check("iterators library", iteratorsWork)

proc stringsWorks() {.raises.} =
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
t = take "hello" 2
d = drop "hello" 3
"""))
  expect toBool(value(env, "yes")), "starts-with matches a prefix"
  expect not toBool(value(env, "no")), "starts-with rejects a non-prefix"
  expect not toBool(value(env, "short")), "starts-with is false when the string is shorter"
  expect toNumber(value(env, "at")) == 2.0, "find-char returns the first index"
  expect isNothing(value(env, "none")), "find-char returns nothing when absent"
  expect stringify(value(env, "t")) == "he", "take keeps the first characters"
  expect stringify(value(env, "d")) == "lo", "drop removes the first characters"

check("strings library", stringsWorks)

proc newCmdlineLib(name: string): Library {.raises.} =
  result = newLibrary(name)
  add(result, baseModule())
  add(result, mathModule())
  add(result, newModule("strings").addFile("src/owl/libraries/strings.owl"))
  add(result, newModule("cmdline").addFile("src/owl/libraries/cmdline.owl"))

proc cmdlineWorks() {.raises.} =
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
  expect stringify(value(env, "cmd")) == "{} (type = cmd) (name = myprog)", "a bare word parses as a cmd"
  expect stringify(value(env, "short")) == "{} (type = short-flag) (flag = f)", "a dash word parses as a short-flag"
  expect stringify(value(env, "long")) == "{} (type = long-flag) (flag = flag)", "a double-dash word parses as a long-flag"
  expect stringify(value(env, "val")) == "{} (type = flag-value) (flag = flag) (value = 123)", "equals splits the flag from its value"
  expect stringify(value(env, "eqempty")) == "{} (type = flag-value) (flag = flag) (value = )", "an empty value is preserved"
  expect isCommand(value(env, "it")), "cli-parser is exported as an iterator command"

proc cmdlineErrors() {.raises.} =
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
  expect raised, "a bare dash is a runtime error"
  expect find(lastError(), "a flag needs a name") >= 0,
    "the parser names the problem, got: " & lastError()

check("cmdline library", cmdlineWorks)
check("cmdline errors", cmdlineErrors)

proc baseOwlWorks() {.raises.} =
  let lib = newLibrary("t18")
  add(lib, baseModule())
  let env = runProgram(lib, parseForms("""
use base

m = max 2 9
o = or false 4
has = is-any ([] 1)
f = first ([] 7 8)
"""))
  expect toNumber(value(env, "m")) == 9.0, "base.owl defs merge into the base module"
  expect toNumber(value(env, "o")) == 4.0, "owl-defined or is exported through use base"
  expect toBool(value(env, "has")), "owl-defined is-any is exported through use base"
  expect toNumber(value(env, "f")) == 7.0, "owl-defined first is exported through use base"

check("base owl merge", baseOwlWorks)

finish "modules"
