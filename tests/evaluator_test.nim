import std/[syncio, options, result, strutils]
import owl/[objects, reader, evaluator]
import owl/libraries/[base, math, list, io]
import ./testutils

captureStdio()

proc newTestEnv(): ref Environment =
  result = newEnvironment()
  installBase(result)
  installMath(result)
  installList(result)
  installIo(result)

var failCalled = false

proc failBuiltin(env: ref Environment, args, body: seq[Object]): Object {.raises.} =
  failCalled = true
  nothing()

proc runSrc(src, extra: string): ref Environment {.raises.} =
  let r = parseOwl(src)
  expect r.isOk, "parse ok, got error: " & r.error("")
  result = newTestEnv()
  if extra.len > 0:
    define(result, symbol(extra), newBuiltin(extra, failBuiltin, true))
  runProgram(result, r.get(@[]))

proc runOk(src, extra: string): ref Environment =
  clearCaptured()
  try:
    result = runSrc(src, extra)
  except:
    expect false, "program should run without errors: " & lastError()
    result = newTestEnv()

proc value(env: ref Environment, name: string): Object =
  let found = lookup(env, symbol(name))
  expect found.isSome, "binding " & name & " exists"
  result = if found.isSome: found.get() else: nothing()

let docExample = """
fun factorial n (m = 2):
  if (< n m):
    1
    * n (factorial (- n 1))

res = factorial (n = 5) ; could also just be factorial 5
echo res
"""

let e1 = runOk(docExample, "")
expect toNumber(value(e1, "res")) == 120.0, "factorial 5 = 120"
expect outputLines == @["120"], "echo res prints 120, got: " & outputLines.join(" | ")

let eStr = runOk("""
msg = "Hello, World!"
echo msg
""", "")
expect outputLines == @["Hello, World!"],
  "echo prints a string literal, got: " & outputLines.join(" | ")
discard eStr

let e2 = runOk("""
res = factorial 5
fun factorial n (m = 2):
  if (< n m):
    1
    * n (factorial (- n 1))
""", "")
expect toNumber(value(e2, "res")) == 120.0, "fun may be used before its definition"

let e3 = runOk("""
q = quote (a b c)
v = eval (quote (+ 2 3))
""", "")
expect stringify(value(e3, "q")) == "a b c", "quote returns its argument unevaluated"
expect toNumber(value(e3, "v")) == 5.0, "eval runs quoted code"

let e4 = runOk("""
command invert cond:
  quote (not (eval cond))

command unless cond then else:
  newCond = invert cond
  if (eval newCond):
    eval(then)
    eval(else)

a = unless (< 1 2) (quote 10) (quote 20)
b = unless (> 1 2) (quote 10) (quote 20)
""", "")
expect toNumber(value(e4, "a")) == 20.0, "unless runs the else branch when the condition holds"
expect toNumber(value(e4, "b")) == 10.0, "unless runs the then branch when the condition fails"

let e5 = runOk("""
command or a b:
  va = eval a
  if va:
    va
    eval b

x = or 5 (fail)
y = or (not (< 1 2)) (quote 7)
""", "fail")
expect toNumber(value(e5, "x")) == 5.0, "or returns the first value"
expect not failCalled, "or short circuits its second argument"
expect toNumber(value(e5, "y")) == 7.0, "or falls through when the first value is false"

let e6 = runOk("""
m = 2
t = if (< m 5):
  42
  99
u = if (> m 5):
  42
  99
""", "")
expect toNumber(value(e6, "t")) == 42.0, "if takes the first body form when true"
expect toNumber(value(e6, "u")) == 99.0, "if takes the rest of the body when false"

let e7 = runOk("""
m = 2
if (< m 5):
  w = 1
  w = 2
""", "")
expect toNumber(value(e7, "w")) == 1.0, "if evaluates only the consequent when true"

let e8 = runOk("""
if (> 1 2):
  z = 1
  z = 2
""", "")
expect toNumber(value(e8, "z")) == 2.0, "if evaluates the alternative when false"

let e9 = runOk("""
n1 = + 1 2 3
n2 = - 10 4
n3 = * 2 3 4
n4 = / 100 5 2
n5 = < 1 2 3
n6 = > 3 2 1
n7 = not (< 1 2)
n8 = list 1 2 3
""", "")
expect toNumber(value(e9, "n1")) == 6.0, "addition"
expect toNumber(value(e9, "n2")) == 6.0, "subtraction"
expect toNumber(value(e9, "n3")) == 24.0, "multiplication"
expect toNumber(value(e9, "n4")) == 10.0, "division"
expect toBool(value(e9, "n5")), "less than"
expect toBool(value(e9, "n6")), "greater than"
expect not toBool(value(e9, "n7")), "not"
expect stringify(value(e9, "n8")) == "[] 1 2 3", "list"

let e10 = runOk("""
fun greet who:
  print who

greet (who = quote owl)
""", "")
expect outputLines == @["owl"], "print writes its argument to stdout, got: " & outputLines.join(" | ")

let e11 = runOk("""
fun add3 a b (c = 1):
  + a b c

p = add3 1 2
q = add3 1 2 3
r = add3 (b = 5) (a = 1)
""", "")
expect toNumber(value(e11, "p")) == 4.0, "default parameter"
expect toNumber(value(e11, "q")) == 6.0, "all parameters given"
expect toNumber(value(e11, "r")) == 7.0, "keyword arguments in any order"

let e12 = runOk("""
v2 = {}:
  x = 100
  y = 200

xs = []:
  1
  2
  3
""", "")
expect isRecord(value(e12, "v2")), "{} returns a record"
expect stringify(value(e12, "v2")) == "{} (x = 100) (y = 200)", "record from block body"
expect toNumber(field(value(e12, "v2"), "y")) == 200.0, "record field lookup"
expect not has(e12, symbol("x")), "record body does not leak bindings"
expect stringify(value(e12, "xs")) == "[] 1 2 3", "[] returns a list"

let e13 = runOk("""
r = {} (a = 1) (b = quote (1 2))
l = [] 1 (+ 1 1)
nested = {}:
  p = {}:
    q = 7
""", "")
expect stringify(value(e13, "r")) == "{} (a = 1) (b = [] 1 2)", "record from pair arguments"
expect stringify(value(e13, "l")) == "[] 1 2", "list from arguments"
expect stringify(value(e13, "nested")) == "{} (p = {} (q = 7))", "nested records"

finish "evaluator"
