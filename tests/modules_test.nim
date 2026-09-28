import std/[syncio, options, result, tables]
import owl/[objects, reader, evaluator, modules]
import owl/libraries/[base, math]

var failures = 0

proc expect(cond: bool, msg: string) =
  if not cond:
    failures += 1
    echo "FAILED: ", msg

proc parseForms(src: string): seq[Object] =
  let r = parseOwl(src)
  expect r.isOk, "parse ok, got error: " & r.error("")
  result = r.get(@[])

proc value(env: ref Environment, name: string): Object =
  let found = lookup(env, symbol(name))
  expect found.isSome, "binding " & name & " exists"
  result = if found.isSome: found.get() else: nothing()

proc check(label: string, body: proc () {.raises.}) =
  try:
    body()
  except:
    expect false, label & " raised unexpectedly"

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

proc doubleBuiltin(env: ref Environment, args, body: seq[Object]): Object {.raises.} =
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
check("export/use", exportUseWorks)
check("recursive", recursiveWorks)
check("self use", selfUseWorks)
check("file", fileWorks)
check("manual", manualWorks)
check("mixed", mixedWorks)

var leaked = false
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

var missing = false
try:
  let lib = newLibrary("t8")
  add(lib, newModule("x").addSource("use nope"))
  evaluate(lib)
except:
  missing = true
expect missing, "unknown module dependency fails the prepass"

var bad = false
try:
  discard newModule("bad").addSource("()")
except:
  bad = true
expect bad, "module with a parse error raises"

if failures == 0:
  echo "modules tests OK"
else:
  quit "modules tests failed: " & $failures
