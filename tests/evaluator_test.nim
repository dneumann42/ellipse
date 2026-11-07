import std/[syncio, options, strutils, unittest]
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

proc failBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object =
  failCalled = true
  nothing()

proc ioFailBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object =
  raise newException(IOError, "disk gone")

proc runSrc(src, extra: string): ref Environment =
  let r = parseOwl(src)
  if not r.isOk:
    raiseAssert("parse ok, got error: " & r.error(""))
  result = newTestEnv()
  if extra.len > 0:
    define(result, symbol(extra), newBuiltin(extra, failBuiltin, true))
  runProgram(result, r.get(@[]))

proc runOk(src, extra: string): ref Environment =
  clearCaptured()
  try:
    result = runSrc(src, extra)
  except:
    raiseAssert("program should run without errors: " & lastError())

proc value(env: ref Environment, name: string): Object =
  let found = lookup(env, symbol(name))
  if not found.isSome:
    raiseAssert("binding " & name & " exists")
  found.get()

let docExample = """
fun factorial n (m = 2):
  if (< n m):
    1
    * n (factorial (- n 1))

res = factorial (n = 5) ; could also just be factorial 5
echo res
"""

proc evalText(text: string): Object =
  let r = parseOwl(text)
  if not r.isOk:
    raiseAssert("printed code parses: " & r.error("") & "\n" & text)
  result = nothing()
  try:
    let env = newTestEnv()
    for f in r.get(@[]):
      result = eval(f, env)
  except:
    raiseAssert("printed code evaluates: " & lastError() & "\n" & text)

suite "owl/evaluator":
  test "string interpolation":
    check evalText("p = {} (name = \"Joe\") (age = 45)\n\"\\(p.name) is \\(+ p.age 1)\"") == str("Joe is 46"),
      "values and calls are spliced in"
    check evalText("xs = [] 1 2\n\"\\(xs) \\(true) \\(nothing)\"") == str("[] 1 2 true ()"),
      "any value reads as to-string gives it"
    check evalText("fun f:\n    \"called\"\n\"<\\((f))>\"") == str("<called>"), "parens call a fun"
    check evalText("n = 2\n\"\\(n)\\(n)\"") == str("22"), "pieces may touch"
    check evalText("\"\\\\(not) \\\"q\\\"\"") == str("\\(not) \"q\""), "escapes still work beside it"
    check evalText(toCode(str("a \\(b)"), 80)) == str("a \\(b)"), "to-code keeps a literal \\( literal"

  test "factorial doc example":
    let e1 = runOk(docExample, "")
    check toNumber(value(e1, "res")) == 120.0, "factorial 5 = 120"
    check outputLines == @["120"], "echo res prints 120, got: " & outputLines.join(" | ")

  test "echo a string":
    let eStr = runOk("""
msg = "Hello, World!"
echo msg
""", "")
    check outputLines == @["Hello, World!"],
      "echo prints a string literal, got: " & outputLines.join(" | ")
    discard eStr

  test "fun before definition":
    let e2 = runOk("""
res = factorial 5
fun factorial n (m = 2):
  if (< n m):
    1
    * n (factorial (- n 1))
""", "")
    check toNumber(value(e2, "res")) == 120.0, "fun may be used before its definition"

  test "quote and eval":
    let e3 = runOk("""
q = quote (a b c)
v = eval (quote (+ 2 3))
""", "")
    check stringify(value(e3, "q")) == "a b c", "quote returns its argument unevaluated"
    check toNumber(value(e3, "v")) == 5.0, "eval runs quoted code"

  test "user-defined commands":
    let e4 = runOk("""
command invert cond:
  quote (not (eval cond))

command unless cond then else:
  newCond = invert cond
  if (eval newCond):
    (eval then)
    (eval else)

a = unless (< 1 2) (quote 10) (quote 20)
b = unless (> 1 2) (quote 10) (quote 20)
""", "")
    check toNumber(value(e4, "a")) == 20.0, "unless runs the else branch when the condition holds"
    check toNumber(value(e4, "b")) == 10.0, "unless runs the then branch when the condition fails"

  test "or short circuits":
    let e5 = runOk("""
command or a b:
  va = eval a
  if va:
    va
    eval b

x = or 5 (fail)
y = or (not (< 1 2)) (quote 7)
""", "fail")
    check toNumber(value(e5, "x")) == 5.0, "or returns the first value"
    check not failCalled, "or short circuits its second argument"
    check toNumber(value(e5, "y")) == 7.0, "or falls through when the first value is false"

  test "if branches":
    let e6 = runOk("""
m = 2
t = if (< m 5):
  42
  99
u = if (> m 5):
  42
  99
""", "")
    check toNumber(value(e6, "t")) == 42.0, "if takes the first body form when true"
    check toNumber(value(e6, "u")) == 99.0, "if takes the rest of the body when false"

  test "if runs only its branch":
    let e7 = runOk("""
m = 2
w = 0
if (< m 5):
  set w 1
  set w 2
""", "")
    check toNumber(value(e7, "w")) == 1.0, "if evaluates only the consequent when true"

  test "if alternative":
    let e8 = runOk("""
z = if (> 1 2):
  1
  2
""", "")
    check toNumber(value(e8, "z")) == 2.0, "if evaluates the alternative when false"

  test "math and list commands":
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
    check toNumber(value(e9, "n1")) == 6.0, "addition"
    check toNumber(value(e9, "n2")) == 6.0, "subtraction"
    check toNumber(value(e9, "n3")) == 24.0, "multiplication"
    check toNumber(value(e9, "n4")) == 10.0, "division"
    check toBool(value(e9, "n5")), "less than"
    check toBool(value(e9, "n6")), "greater than"
    check not toBool(value(e9, "n7")), "not"
    check stringify(value(e9, "n8")) == "[] 1 2 3", "list"

  test "print":
    let e10 = runOk("""
fun greet who:
  print who

greet (who = quote owl)
""", "")
    check outputLines == @["owl"], "print writes its argument to stdout, got: " & outputLines.join(" | ")

  test "default and keyword parameters":
    let e11 = runOk("""
fun add3 a b (c = 1):
  + a b c

p = add3 1 2
q = add3 1 2 3
r = add3 (b = 5) (a = 1)
""", "")
    check toNumber(value(e11, "p")) == 4.0, "default parameter"
    check toNumber(value(e11, "q")) == 6.0, "all parameters given"
    check toNumber(value(e11, "r")) == 7.0, "keyword arguments in any order"

  test "record and list literals":
    let e12 = runOk("""
v2 = {}:
  x = 100
  y = 200

xs = []:
  1
  2
  3
""", "")
    check isRecord(value(e12, "v2")), "{} returns a record"
    check stringify(value(e12, "v2")) == "{} (x = 100) (y = 200)", "record from block body"
    check toNumber(field(value(e12, "v2"), "y")) == 200.0, "record field lookup"
    check not has(e12, symbol("x")), "record body does not leak bindings"
    check stringify(value(e12, "xs")) == "[] 1 2 3", "[] returns a list"

  test "record and list from arguments":
    let e13 = runOk("""
r = {} (a = 1) (b = quote (1 2))
l = [] 1 (+ 1 1)
nested = {}:
  p = {}:
    q = 7
""", "")
    check stringify(value(e13, "r")) == "{} (a = 1) (b = [] 1 2)", "record from pair arguments"
    check stringify(value(e13, "l")) == "[] 1 2", "list from arguments"
    check stringify(value(e13, "nested")) == "{} (p = {} (q = 7))", "nested records"

  test "index and length":
    let e14 = runOk("""
xs = [] 10 20 30
s = "hello"
r = {}:
  a = "one"
  b = xs
n = {}:
  p = {}:
    q = 7

recs = []:
  {}:
    k = "one"
  {}:
    k = "two"

pair = quote (a = 2)

first = xs.0
last = xs.2
mid = s.1
fieldName = r.a
deep = r.b.1
chain = n.p.q
byGroup = xs.(+ 0 1)
afterGroup = recs.(+ 0 1).k
letter = s.(+ 0 2).0
byName = index r b 1
literal = r.0

lxs = length xs
ls = length s
lr = length r
ln = length n
lp = length pair

p0 = pair.0
p1 = pair.1
""", "")
    check toNumber(value(e14, "first")) == 10.0, "a dot with a position reads a list"
    check toNumber(value(e14, "last")) == 30.0, "the last position"
    check stringify(value(e14, "mid")) == "e", "a dot reads a string"
    check stringify(value(e14, "fieldName")) == "one", "a dot reads a record field"
    check toNumber(value(e14, "deep")) == 20.0, "a dot chains into a field value"
    check toNumber(value(e14, "chain")) == 7.0, "dot chains through records"
    check toNumber(value(e14, "byGroup")) == 20.0, "a group is a computed key"
    check stringify(value(e14, "afterGroup")) == "two", "a group key chains into a name"
    check stringify(value(e14, "letter")) == "l", "a group key chains into a position"
    check toNumber(value(e14, "byName")) == 20.0, "index chains over several keys"
    check stringify(value(e14, "literal")) == "(a = one)", "a record position is its field"
    check toNumber(value(e14, "lxs")) == 3.0, "length of a list"
    check toNumber(value(e14, "ls")) == 5.0, "length of a string"
    check toNumber(value(e14, "lr")) == 2.0, "length of a record"
    check toNumber(value(e14, "ln")) == 1.0, "length of a one field record"
    check toNumber(value(e14, "lp")) == 2.0, "length of a pair"
    check toSymbol(value(e14, "p0")) == "a", "car of a pair by position"
    check toNumber(value(e14, "p1")) == 2.0, "cdr of a pair by position"

  test "record fields are callable":
    let e15 = runOk("""
fun double x:
  * x 2

ops = {}:
  f = double

v = ops.f 21
w = ops.f (ops.f 3)
named = field ops "f"
""", "")
    check toNumber(value(e15, "v")) == 42.0, "a field is just a command, callable through the dot"
    check toNumber(value(e15, "w")) == 12.0, "a dotted call nests"
    check isCommand(value(e15, "named")), "field reads the record by name"

  test "comparisons":
    let e16 = runOk("""
v1 = {}:
  a = 1

v2 = {}:
  a = 1

yes = < 1 2
same = = 1 1
diff = <> 1 2
words = = "owl" "owl"
kinds = <> 1 yes
chains = = 2 2 2
neighbours = <> 1 2 3
recs = = v1 v2
mixed = (= (+ 1 1) 2)
broken = = 1 2 2
half = <> 1 2 2
""", "")
    check toBool(value(e16, "same")), "the equality command compares numbers"
    check toBool(value(e16, "diff")), "the inequality command reports a difference"
    check toBool(value(e16, "words")), "equality compares strings"
    check toBool(value(e16, "kinds")), "a number is not a boolean"
    check toBool(value(e16, "chains")), "equality chains over equal neighbours"
    check toBool(value(e16, "neighbours")), "inequality chains over different neighbours"
    check toBool(value(e16, "recs")), "equality compares records by structure"
    check toBool(value(e16, "mixed")), "equality compares computed values"
    check not toBool(value(e16, "broken")), "one unequal neighbour fails the chain"
    check not toBool(value(e16, "half")), "one equal neighbour fails the inequality chain"

  test "comparisons in expressions":
    let e17 = runOk("""
xs = [] 1 2
n2 = <> (length xs) 3
ordered = < 1 2 3

branch = if (= (length xs) 2):
  1
  2

flag = not (= 1 2)
""", "")
    check toBool(value(e17, "n2")), "inequality compares computed values"
    check toBool(value(e17, "ordered")), "the ordering commands still chain"
    check toNumber(value(e17, "branch")) == 1.0, "equality works as an if condition"
    check toBool(value(e17, "flag")), "not is installed with base"

  test "equality needs two values":
    var oneArg = false
    clearCaptured()
    try:
      discard runSrc("x = = 1", "")
    except:
      oneArg = true
    check oneArg, "equality needs two values to compare"
    check find(lastError(), "comparisons need at least two arguments") >= 0,
      "equality says what it needs, got: " & lastError()

  test "ordering needs numbers":
    var textOrder = false
    clearCaptured()
    try:
      discard runSrc("x = < \"a\" \"b\"", "")
    except:
      textOrder = true
    check textOrder, "ordering needs numbers"
    check find(lastError(), "comparison needs numbers") >= 0,
      "ordering reports the value it got, got: " & lastError()

  test "not arity":
    var badNot = false
    clearCaptured()
    try:
      discard runSrc("x = not 1 2", "")
    except:
      badNot = true
    check badNot, "not takes exactly one argument"
    check find(lastError(), "not needs exactly one argument") >= 0,
      "not reports its arity, got: " & lastError()

  test "length needs a length":
    var noLen = false
    clearCaptured()
    try:
      discard runSrc("x = length 42", "")
    except:
      noLen = true
    check noLen, "length refuses what has no length"
    check find(lastError(), "length needs something with a length") >= 0,
      "length says what it needs, got: " & lastError()

  test "index out of range":
    var badRange = false
    clearCaptured()
    try:
      discard runSrc("xs = [] 1 2\nx = xs.2", "")
    except:
      badRange = true
    check badRange, "a position past the end fails"
    check find(lastError(), "index out of range") >= 0,
      "index reports the range, got: " & lastError()

  test "fractional position":
    var badPos = false
    clearCaptured()
    try:
      discard runSrc("xs = [] 1 2\nx = xs.1.5", "")
    except:
      badPos = true
    check badPos, "a fractional position fails"
    check find(lastError(), "index needs a whole number position") >= 0,
      "index reports the position, got: " & lastError()

  test "name key needs a record":
    var nameOnList = false
    clearCaptured()
    try:
      discard runSrc("xs = [] 1 2\nx = xs.a", "")
    except:
      nameOnList = true
    check nameOnList, "a name key needs a record"
    check find(lastError(), "index needs a record for a name") >= 0,
      "index says a name needs a record, got: " & lastError()

  test "field needs a record":
    var noField = false
    clearCaptured()
    try:
      discard runSrc("x = field 42 \"a\"", "")
    except:
      noField = true
    check noField, "field needs a record"
    check find(lastError(), "field needs a record") >= 0,
      "field says it needs a record, got: " & lastError()

  test "list mutation":
    let e18 = runOk("""
xs = [] 1 2 3
a = append xs 4 5
afterAppend = length xs
p = pop xs
pf = pop-front xs
i = insert xs 1 99
pre = prepend xs 0 7
final = length xs
""", "")
    check stringify(value(e18, "a")) == "[] 1 2 3 4 5", "append returns the grown list"
    check toNumber(value(e18, "afterAppend")) == 5.0, "append mutates the variable in place"
    check toNumber(value(e18, "p")) == 5.0, "pop returns the last element"
    check toNumber(value(e18, "pf")) == 1.0, "pop-front returns the first element"
    check stringify(value(e18, "i")) == "[] 2 99 3 4", "insert places a value at a position"
    check stringify(value(e18, "pre")) == "[] 0 7 2 99 3 4", "prepend adds values at the front"
    check toNumber(value(e18, "final")) == 6.0, "the commands keep mutating the same list"

  test "pop from empty":
    var popEmpty = false
    clearCaptured()
    try:
      discard runSrc("xs = ([])\npop xs", "")
    except:
      popEmpty = true
    check popEmpty, "pop from an empty list fails"
    check find(lastError(), "pop from an empty list") >= 0,
      "pop reports the empty list, got: " & lastError()

  test "append needs a list":
    var appendNoList = false
    clearCaptured()
    try:
      discard runSrc("n = 4\nappend n 1", "")
    except:
      appendNoList = true
    check appendNoList, "append needs a list variable"
    check find(lastError(), "append needs a list variable") >= 0,
      "append says it needs a list, got: " & lastError()

  test "do blocks":
    let e19 = runOk("""
n = nothing
e = do 1 2 3
blk = do:
  a1 = 1
  + a1 1
empty = (do)
""", "")
    check isNothing(value(e19, "n")), "nothing evaluates to the nil value"
    check toNumber(value(e19, "e")) == 3.0, "do returns the last value"
    check toNumber(value(e19, "blk")) == 2.0, "do returns the last form of a block"
    check lookup(e19, symbol("a1")).isNone, "names defined in a do end with it"
    check isNothing(value(e19, "empty")), "an empty do is nothing"

  test "while and eval":
    let e20 = runOk("""
count = 0
while (< count 3):
  set count (+ count 1)

p = pair (quote x) 5
eval p
""", "")
    check toNumber(value(e20, "count")) == 3.0, "while loops until the condition fails"
    check toNumber(value(e20, "x")) == 5.0, "pair builds syntax that eval binds"

  test "plus parameter collects the block":
    let e21 = runOk("""
command count-forms body+:
  length body

n = count-forms:
  1
  2
  3
empty = count-forms
""", "")
    check toNumber(value(e21, "n")) == 3.0, "a + parameter collects the caller's block"
    check toNumber(value(e21, "empty")) == 0.0, "no block means an empty body list"

  test "commands reject extras":
    var tooMany = false
    clearCaptured()
    try:
      discard runSrc("command two a b:\n  1\ntwo 1 2 3", "")
    except:
      tooMany = true
    check tooMany, "commands without a + parameter still reject extras"

  test "set":
    let e22 = runOk("""
count = 0
bump = lambda:
  set count (+ count 1)

(bump)
(bump)
twice = set count 10
""", "")
    check toNumber(value(e22, "count")) == 10.0, "set updates the binding where it was found"
    check toNumber(value(e22, "twice")) == 10.0, "set returns the new value"

  test "set on unbound":
    var setUnbound = false
    clearCaptured()
    try:
      discard runSrc("set missing 1", "")
    except:
      setUnbound = true
    check setUnbound, "set on an unbound symbol is a runtime error"
    check find(lastError(), "set on an unbound symbol: missing") >= 0,
      "set reports the missing name, got: " & lastError()

  test "concat":
    let e23 = runOk("""
s = concat "ab" "cd" "e"
a = [] 1 2
b = [] 3 4
l = concat a b
r1 = {} (x = 1)
r2 = {} (y = 2)
r = concat r1 r2
t = true
f = not false
""", "")
    check stringify(value(e23, "s")) == "abcde", "concat joins strings"
    check stringify(value(e23, "l")) == "[] 1 2 3 4", "concat joins lists"
    check stringify(value(e23, "r")) == "{} (x = 1) (y = 2)", "concat merges records"
    check toBool(value(e23, "t")), "true is a boolean literal"
    check toBool(value(e23, "f")), "false is a boolean literal"

  test "concat refuses mixed kinds":
    var concatMix = false
    clearCaptured()
    try:
      discard runSrc("x = concat \"a\" ([])", "")
    except:
      concatMix = true
    check concatMix, "concat refuses to mix a string with a list"
    check find(lastError(), "concat mixes a string with") >= 0,
      "concat names the kind it mixed, got: " & lastError()

  test "concat rejects other kinds":
    var concatBad = false
    clearCaptured()
    try:
      discard runSrc("x = concat 1 2", "")
    except:
      concatBad = true
    check concatBad, "concat rejects operands that are not string/list/record"
    check find(lastError(), "concat needs strings, lists or records") >= 0,
      "concat says what it accepts, got: " & lastError()

  test "error raises":
    var raised = false
    clearCaptured()
    try:
      discard runSrc("error \"boom\" \"here\"", "")
    except:
      raised = true
    check raised, "error raises a runtime error"
    check find(lastError(), "boom here") >= 0,
      "error joins its message parts, got: " & lastError()

  test "base predicates and logic":
    let e24 = runOk("""
o1 = or 5 6
o2 = or nothing 6
o3 = or false 7
a1 = and 5 6
a2 = and nothing 6
w = 0
when true:
  set w 1
u = 0
unless false:
  set u 2
ie = is-empty ([])
ia = is-any ([] 1)
f = first ([] 8 9)
mn = min 3 5
mx = max 3 5
in1 = is-nothing nothing
in2 = is-nothing 5
""", "")
    check toNumber(value(e24, "o1")) == 5.0, "or returns the first truthy operand"
    check toNumber(value(e24, "o2")) == 6.0, "or skips nothing"
    check toNumber(value(e24, "o3")) == 7.0, "or skips false"
    check toNumber(value(e24, "a1")) == 6.0, "and returns the second when the first is truthy"
    check isNothing(value(e24, "a2")), "and short-circuits on a falsy first operand"
    check toNumber(value(e24, "w")) == 1.0, "when runs its block when the condition holds"
    check toNumber(value(e24, "u")) == 2.0, "unless runs its block when the condition fails"
    check toBool(value(e24, "ie")), "is-empty on an empty list"
    check toBool(value(e24, "ia")), "is-any on a non-empty list"
    check toNumber(value(e24, "f")) == 8.0, "first returns the head"
    check toNumber(value(e24, "mn")) == 3.0, "min picks the smaller"
    check toNumber(value(e24, "mx")) == 5.0, "max picks the larger"
    check toBool(value(e24, "in1")), "is-nothing on nothing"
    check not toBool(value(e24, "in2")), "is-nothing on a value"

  test "when and cond":
    let e25 = runOk("""
n = 2
w1 = 0
when (= n 2):
  set w1 1
w2 = 0
when (< n 2):
  set w2 1
c1 = 0
cond:
  (= n 1) = set c1 10
  (= n 2) = set c1 20
  true = set c1 30
c2 = 0
cond:
  (= n 5) = set c2 10
  false = set c2 20
""", "")
    check toNumber(value(e25, "w1")) == 1.0, "when runs its block on a grouped true condition"
    check toNumber(value(e25, "w2")) == 0.0, "when skips its block on a grouped false condition"
    check toNumber(value(e25, "c1")) == 20.0, "cond runs the first matching pair only"
    check toNumber(value(e25, "c2")) == 0.0, "cond does nothing when no pair matches"

  test "cond stops at the first match":
    var condShort = false
    clearCaptured()
    try:
      discard runSrc("cond:\n  true = 1\n  true = error \"boom\"", "")
    except:
      condShort = true
    check not condShort, "cond stops after the first matching pair"

  test "cond rejects non-pairs":
    var condBad = false
    clearCaptured()
    try:
      discard runSrc("cond 5", "")
    except:
      condBad = true
    check condBad, "cond rejects arguments that are not pairs"
    check find(lastError(), "cond needs (test = body) pairs") >= 0,
      "cond says what it needs, got: " & lastError()

  test "or short circuits eagerly":
    var orShort = false
    clearCaptured()
    try:
      discard runSrc("x = or 5 (error \"boom\")", "")
    except:
      orShort = true
    check not orShort, "or does not evaluate its second operand when the first is truthy"

  test "and short circuits eagerly":
    var andShort = false
    clearCaptured()
    try:
      discard runSrc("x = and nothing (error \"boom\")", "")
    except:
      andShort = true
    check not andShort, "and does not evaluate its second operand when the first is falsy"

  test "parse builtin":
    let eParse = runOk("""
forms = parse (concat "x = 2" newline "+ x 3")
n = length forms
a = eval (pop-front forms)
b = eval (pop-front forms)
""", "")
    check toNumber(value(eParse, "n")) == 2.0, "parse returns one form per top-level expression"
    check toNumber(value(eParse, "b")) == 5.0, "parsed forms evaluate in the caller's env"

  test "parse fails on malformed source":
    var parseBad = false
    clearCaptured()
    try:
      discard runSrc("x = parse \"(\"", "")
    except:
      parseBad = true
    check parseBad, "parse fails on malformed source"
    check find(lastError(), "read error") >= 0, "parse names the failure, got: " & lastError()

  test "try and handlers":
    let eTry = runOk("""
ok = try (+ 1 2):
  0
bad = try (error "boom"):
  concat "caught " failure
quiet = try (error "boom")
flag = 0
try (error "again"):
  set flag 1
""", "")
    check toNumber(value(eTry, "ok")) == 3.0, "try returns the value when nothing fails"
    check toStr(value(eTry, "bad")) == "caught boom", "try runs the handler with failure bound"
    check isNothing(value(eTry, "quiet")), "try without a handler gives nothing on failure"
    check toNumber(value(eTry, "flag")) == 1.0, "the try handler can set outer variables"
    check errorLines.len == 0, "try keeps caught errors from being reported"

  test "try rethrow propagates":
    var tryRethrow = false
    clearCaptured()
    try:
      discard runSrc("try (error \"one\"):\n  error \"two\"", "")
    except:
      tryRethrow = true
    check tryRethrow, "an error in the try handler propagates"
    check currentError.message == "two", "the handler's error is reported, got: " & lastError()

  test "char and to-string":
    let eChar = runOk("""
a = char 65
n = to-string 42
s = concat "n=" (to-string 1.5)
""", "")
    check toStr(value(eChar, "a")) == "A", "char builds a one-character string from a byte"
    check toStr(value(eChar, "n")) == "42", "to-string writes whole numbers without a fraction"
    check toStr(value(eChar, "s")) == "n=1.5", "to-string output concatenates with strings"

  test "char rejects out of range":
    var charBad = false
    clearCaptured()
    try:
      discard runSrc("x = char 300", "")
    except:
      charBad = true
    check charBad, "char rejects numbers outside a byte"

  test "slice find and code":
    let eSlice = runOk("""
s1 = slice "hello" 1 3
s2 = slice "hello" 3
s3 = slice "hello" -2 99
l1 = slice ([] 1 2 3) 1
f1 = find "a=b=c" "="
f2 = find "a=b=c" "=" 2
f3 = find "abc" "z"
c1 = code "A"
c2 = code "AB" 1
""", "")
    check toStr(value(eSlice, "s1")) == "el", "slice takes a range of a string"
    check toStr(value(eSlice, "s2")) == "lo", "slice runs to the end without an end"
    check toStr(value(eSlice, "s3")) == "hello", "slice clamps its range"
    check stringify(value(eSlice, "l1")) == "[] 2 3", "slice works on lists"
    check toNumber(value(eSlice, "f1")) == 1.0, "find gives the first position"
    check toNumber(value(eSlice, "f2")) == 3.0, "find starts at the given position"
    check isNothing(value(eSlice, "f3")), "find gives nothing when there is no match"
    check toNumber(value(eSlice, "c1")) == 65.0, "code gives the first byte"
    check toNumber(value(eSlice, "c2")) == 66.0, "code takes a position"

  test "and or see caller names":
    let eAndOr = runOk("""
a = 1
b = 2
x = and (= a 1) (= b 2)
y = or (= b 0) (= a 1)
z = and true false
""", "")
    check toBool(value(eAndOr, "x")), "and sees the caller's a and b"
    check toBool(value(eAndOr, "y")), "or sees the caller's a and b"
    check not toBool(value(eAndOr, "z")), "and is false when an operand is false"

  test "command hygiene":
    let eHygiene = runOk("""
command my-or a b:
  va = eval a
  if va:
    va
    eval b

command twice x:
  n = eval x
  + n n

command let-ten name:
  bind name 10

command run-all body+:
  forms = body
  while (not (= (length forms) 0)):
    eval (pop-front forms)

a = false
b = 7
va = 99
n = 4
got = my-or a b
locals = my-or false va
doubled = twice (+ n 1)
let-ten fresh
forms = 1
run-all:
  made = 5
  forms = + forms 1
""", "")
    check toNumber(value(eHygiene, "got")) == 7.0, "a command's parameters never shadow the caller's a and b"
    check toNumber(value(eHygiene, "locals")) == 99.0, "a command's locals never shadow the caller's names"
    check toNumber(value(eHygiene, "doubled")) == 10.0, "a command's local n does not capture the caller's n"
    check toNumber(value(eHygiene, "fresh")) == 10.0, "bind defines a syntax name in the caller's scope"
    check toNumber(value(eHygiene, "made")) == 5.0, "a command's block runs in the caller's scope"
    check toNumber(value(eHygiene, "forms")) == 2.0, "the block sees the caller's forms, not the command's"

  test "scoped bind and do":
    let eScoped = runOk("""
command each-twice name body+:
  i = 0
  while (< i 2):
    do:
      bind name i
      forms = body
      while (not (= (length forms) 0)):
        eval (pop-front forms)
      do:
        bind name (+ i 100)
        forms = body
        while (not (= (length forms) 0)):
          eval (pop-front forms)
    set i (+ i 1)

seen = ([])
i = 7
each-twice k:
  append seen (+ k i)
  local = k
outer = 1
do:
  outer = 2
  hidden = 3
""", "")
    check stringify(value(eScoped, "seen")) == "[] 7 107 8 108",
      "a do in a command scopes bind on the caller's side; nested dos nest"
    check lookup(eScoped, symbol("k")).isNone, "a name bound in a command's do ends with the do"
    check lookup(eScoped, symbol("local")).isNone, "names the block defines inside a command's do end with it"
    check toNumber(value(eScoped, "outer")) == 1.0, "= inside a do defines a new local"
    check lookup(eScoped, symbol("hidden")).isNone, "a top-level do's names end with it"

  test "block scopes":
    let eBlocks = runOk("""
if true:
  in-then = 1
  in-else = 1
if false:
  in-then2 = 1
  in-else2 = 1
when true:
  in-when = 1
i = 0
fresh = 0
while (< i 3):
  in-while = (+ i 1)
  set fresh (+ fresh in-while)
  set i (+ i 1)
cond:
  true = (in-cond = 1)
try (error "x"):
  in-try = 1
kept = 5
when true:
  kept = 6
""", "")
    for name in ["in-then", "in-else2", "in-when", "in-while", "in-cond", "in-try"]:
      check lookup(eBlocks, symbol(name)).isNone, name & " ends with its block"
    check toNumber(value(eBlocks, "fresh")) == 6.0, "each while pass gets its own scope"
    check toNumber(value(eBlocks, "kept")) == 5.0, "= in a block defines a local, leaving the outer name"

  test "eval-in scopes":
    let eScopes = runOk("""
s = (new-scope)
eval-in s (quote (hidden = 41))
got = eval-in s (quote (+ hidden 1))
""", "")
    check toNumber(value(eScopes, "got")) == 42.0, "eval-in keeps definitions in its scope between calls"
    check lookup(eScopes, symbol("hidden")).isNone, "a new-scope's definitions stay out of the creator's scope"

  test "commands are lexical":
    let eLexical = runOk("""
k = 1
command get-k:
  k
fun shadow:
  k = 2
  (get-k)
inner = (shadow)
""", "")
    check toNumber(value(eLexical, "inner")) == 1.0, "a command's free names resolve where it was defined"

  test "dynamic-command":
    let eDynamic = runOk("""
dynamic-command peek:
  secret

dynamic-command form-of x:
  x

dynamic-command set-here name:
  eval (pair name 3)

fun probe:
  secret = 42
  (peek)

shown = (probe)
code = form-of (+ 1 2)
set-here q
""", "")
    let qFound = lookup(eDynamic, symbol("q"))
    check toNumber(value(eDynamic, "shown")) == 42.0, "a dynamic-command body sees the caller's scope"
    check stringify(value(eDynamic, "code")) == "+ 1 2", "a dynamic-command gets bare forms"
    check qFound.isNone, "a dynamic-command's bindings stay in its own frame"

  test "to-code round trips":
    let printed = runOk("""
tasks = [] ({} (title = "Hello") (descr = "World!")) ({} (title = "Bye") (descr = ""))
quoted = concat "say " (char 34) "hi" (char 34) newline "tab" (char 9) "end"
nested = {} (name = "owl") (tags = ([] "lang" "repl")) (inner = ({} (a = 1) (b = ([] 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20)))) (none = ([])) (empty = ({}))
mixed = [] 1 -2.5 true false nothing "é" ([] ([] 1) ([]))
""", "")
    for name in ["tasks", "quoted", "nested", "mixed"]:
      let v = value(printed, name)
      for width in [20, 40, 80, 200]:
        let text = toCode(v, width)
        check evalText(text) == v, "to-code of " & name & " at width " & $width & " reads back:\n" & text
        if width >= 40 and name != "quoted":
          for line in text.split("\n"):
            check line.len <= width or not line.contains(" = ") or line.startsWith(" "),
              "lines stay within the width where owl can break: " & line
    check toCode(value(printed, "quoted"), 80) == "\"say \\\"hi\\\"\\ntab\\tend\"",
      "quotes and control characters print as escapes: " & toCode(value(printed, "quoted"), 80)
    for raw in ["back\\slash", "\"", "\x01\x7f", "caf\u00e9", "\e[0m\r\0"]:
      check evalText(toCode(str(raw), 80)) == str(raw), "escapes read back: " & toCode(str(raw), 80)
    check toCode(value(printed, "tasks"), 50) == """[]:
    {} (title = "Hello") (descr = "World!")
    {} (title = "Bye") (descr = "")""", "a list that does not fit breaks into a block:\n" & toCode(value(printed, "tasks"), 50)
    check toCode(value(printed, "tasks"), 30) == """[]:
    {}:
        title = "Hello"
        descr = "World!"
    {}:
        title = "Bye"
        descr = """"", "records break into name = value lines:\n" & toCode(value(printed, "tasks"), 30)
    check toCode(str("hi"), 80) == "\"hi\"", "strings are quoted"
    check toCode(list(newSeq[Object]()), 80) == "([])", "the empty list"

  test "parsed source round trips":
    let source = """fun f x (y = 2):
    when (> x y):
        echo "big" x
    + x y

z = [] 1 2

(g)
"""
    let parsedSource = parseOwl(source)
    check parsedSource.isOk, "source parses"
    for form in parsedSource.get(@[]):
      for width in [10, 80]:
        let text = toCode(form, width)
        let back = parseOwl(text)
        check back.isOk and back.get(@[]).len == 1 and back.get(@[])[0] == form and
          stringify(back.get(@[])[0]) == stringify(form),
          "printed code parses back to the same form:\n" & text
    check toCode(parsedSource.get(@[])[0], 80) == """fun f x (y = 2):
    when (> x y):
        echo "big" x
    + x y""", "code keeps its blocks:\n" & toCode(parsedSource.get(@[])[0], 80)

  test "a fun prints as its definition":
    let fnEnv = runOk("fun twice x:\n  * x 2", "")
    check toCode(value(fnEnv, "twice"), 80) == "fun twice x:\n    * x 2",
      "a fun prints as its definition: " & toCode(value(fnEnv, "twice"), 80)

  test "block parameters":
    let blockEnv = runOk("""fun twice-run &body:
    (body)
    (body)
fun wrap label (&inner = empty):
    concat label (pick-or (inner) "")
fun empty:
    nothing
fun pick-or v d:
    if (= v nothing):
        d
        v
n = 0
twice-run:
    set n (+ n 1)
seen = wrap "a":
    "b"
plain = wrap "c"
fun give-e:
    "e"
named = wrap "d" (inner = give-e)
command forms-of x &body:
    length body
count = forms-of 1:
    echo "x"
    echo "y"
none = forms-of 1
""", "")
    check toNumber(value(blockEnv, "n")) == 2.0, "the block closure ran twice and set the caller's n"
    check toStr(value(blockEnv, "seen")) == "ab", "the block's value comes back: " & stringify(value(blockEnv, "seen"))
    check toStr(value(blockEnv, "plain")) == "c", "without a block the default is kept"
    check toStr(value(blockEnv, "named")) == "de", "a block parameter can be passed by name"
    check toNumber(value(blockEnv, "count")) == 2.0, "a command gets the block's forms"
    check toNumber(value(blockEnv, "none")) == 0.0 or value(blockEnv, "none") == nothing(), "no block, no forms"

  test "named arguments leave positional ones the open parameters":
    let e = runOk("""
fun add3 a b (c = 1):
  [] a b c
before = add3 (a = 10) 2
after = add3 2 (a = 10)
command wrap-all xs+ (&body = 5):
  length xs
n = wrap-all 1 2 3
""", "")
    check toCode(value(e, "before")) == "[] 10 2 1", "a named first: " & toCode(value(e, "before"))
    check toCode(value(e, "after")) == "[] 10 2 1", "a named last: " & toCode(value(e, "after"))
    check toNumber(value(e, "n")) == 3.0, "a rest parameter beside a defaulted block takes the arguments"

  test "a missing argument is an error, not an outer binding":
    clearCaptured()
    var failed = false
    try:
      discard runSrc("x = 99\nfun f x:\n  x\ny = (f)\n", "")
    except:
      failed = true
    check failed, "calling f without x fails"
    check find(lastError(), "missing argument x for f") >= 0, "got: " & lastError()

  test "commands are equal only to themselves":
    let e = runOk("""
a = lambda x:
  1
b = lambda x:
  2
same = = a a
different = = a b
builtins = = + +
""", "")
    check toBool(value(e, "same")), "a command equals itself"
    check not toBool(value(e, "different")), "two lambdas from one scope differ"
    check toBool(value(e, "builtins")), "a builtin equals itself"

  test "a Nim exception from a builtin reports its own message":
    clearCaptured()
    try:
      discard runSrc("x = (nope)", "")
    except:
      discard
    let env = newTestEnv()
    define(env, symbol("explode"), newBuiltin("explode", ioFailBuiltin, true))
    var message = ""
    try:
      discard eval(list(@[symbol("explode")]), env)
    except:
      message = errorText()
    check find(message, "disk gone") >= 0, "got: " & message
