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

proc failBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
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
    (eval then)
    (eval else)

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
w = 0
if (< m 5):
  set w 1
  set w 2
""", "")
expect toNumber(value(e7, "w")) == 1.0, "if evaluates only the consequent when true"

let e8 = runOk("""
z = if (> 1 2):
  1
  2
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
expect toNumber(value(e14, "first")) == 10.0, "a dot with a position reads a list"
expect toNumber(value(e14, "last")) == 30.0, "the last position"
expect stringify(value(e14, "mid")) == "e", "a dot reads a string"
expect stringify(value(e14, "fieldName")) == "one", "a dot reads a record field"
expect toNumber(value(e14, "deep")) == 20.0, "a dot chains into a field value"
expect toNumber(value(e14, "chain")) == 7.0, "dot chains through records"
expect toNumber(value(e14, "byGroup")) == 20.0, "a group is a computed key"
expect stringify(value(e14, "afterGroup")) == "two", "a group key chains into a name"
expect stringify(value(e14, "letter")) == "l", "a group key chains into a position"
expect toNumber(value(e14, "byName")) == 20.0, "index chains over several keys"
expect stringify(value(e14, "literal")) == "(a = one)", "a record position is its field"
expect toNumber(value(e14, "lxs")) == 3.0, "length of a list"
expect toNumber(value(e14, "ls")) == 5.0, "length of a string"
expect toNumber(value(e14, "lr")) == 2.0, "length of a record"
expect toNumber(value(e14, "ln")) == 1.0, "length of a one field record"
expect toNumber(value(e14, "lp")) == 2.0, "length of a pair"
expect toSymbol(value(e14, "p0")) == "a", "car of a pair by position"
expect toNumber(value(e14, "p1")) == 2.0, "cdr of a pair by position"

let e15 = runOk("""
fun double x:
  * x 2

ops = {}:
  f = double

v = ops.f 21
w = ops.f (ops.f 3)
named = field ops "f"
""", "")
expect toNumber(value(e15, "v")) == 42.0, "a field is just a command, callable through the dot"
expect toNumber(value(e15, "w")) == 12.0, "a dotted call nests"
expect isCommand(value(e15, "named")), "field reads the record by name"

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
expect toBool(value(e16, "same")), "the equality command compares numbers"
expect toBool(value(e16, "diff")), "the inequality command reports a difference"
expect toBool(value(e16, "words")), "equality compares strings"
expect toBool(value(e16, "kinds")), "a number is not a boolean"
expect toBool(value(e16, "chains")), "equality chains over equal neighbours"
expect toBool(value(e16, "neighbours")), "inequality chains over different neighbours"
expect toBool(value(e16, "recs")), "equality compares records by structure"
expect toBool(value(e16, "mixed")), "equality compares computed values"
expect not toBool(value(e16, "broken")), "one unequal neighbour fails the chain"
expect not toBool(value(e16, "half")), "one equal neighbour fails the inequality chain"

let e17 = runOk("""
xs = [] 1 2
n2 = <> (length xs) 3
ordered = < 1 2 3

branch = if (= (length xs) 2):
  1
  2

flag = not (= 1 2)
""", "")
expect toBool(value(e17, "n2")), "inequality compares computed values"
expect toBool(value(e17, "ordered")), "the ordering commands still chain"
expect toNumber(value(e17, "branch")) == 1.0, "equality works as an if condition"
expect toBool(value(e17, "flag")), "not is installed with base"

var oneArg = false
clearCaptured()
try:
  discard runSrc("x = = 1", "")
except:
  oneArg = true
expect oneArg, "equality needs two values to compare"
expect find(lastError(), "comparisons need at least two arguments") >= 0,
  "equality says what it needs, got: " & lastError()

var textOrder = false
clearCaptured()
try:
  discard runSrc("x = < \"a\" \"b\"", "")
except:
  textOrder = true
expect textOrder, "ordering needs numbers"
expect find(lastError(), "comparison needs numbers") >= 0,
  "ordering reports the value it got, got: " & lastError()

var badNot = false
clearCaptured()
try:
  discard runSrc("x = not 1 2", "")
except:
  badNot = true
expect badNot, "not takes exactly one argument"
expect find(lastError(), "not needs exactly one argument") >= 0,
  "not reports its arity, got: " & lastError()

var noLen = false
clearCaptured()
try:
  discard runSrc("x = length 42", "")
except:
  noLen = true
expect noLen, "length refuses what has no length"
expect find(lastError(), "length needs something with a length") >= 0,
  "length says what it needs, got: " & lastError()

var badRange = false
clearCaptured()
try:
  discard runSrc("xs = [] 1 2\nx = xs.2", "")
except:
  badRange = true
expect badRange, "a position past the end fails"
expect find(lastError(), "index out of range") >= 0,
  "index reports the range, got: " & lastError()

var badPos = false
clearCaptured()
try:
  discard runSrc("xs = [] 1 2\nx = xs.1.5", "")
except:
  badPos = true
expect badPos, "a fractional position fails"
expect find(lastError(), "index needs a whole number position") >= 0,
  "index reports the position, got: " & lastError()

var nameOnList = false
clearCaptured()
try:
  discard runSrc("xs = [] 1 2\nx = xs.a", "")
except:
  nameOnList = true
expect nameOnList, "a name key needs a record"
expect find(lastError(), "index needs a record for a name") >= 0,
  "index says a name needs a record, got: " & lastError()

var noField = false
clearCaptured()
try:
  discard runSrc("x = field 42 \"a\"", "")
except:
  noField = true
expect noField, "field needs a record"
expect find(lastError(), "field needs a record") >= 0,
  "field says it needs a record, got: " & lastError()

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
expect stringify(value(e18, "a")) == "[] 1 2 3 4 5", "append returns the grown list"
expect toNumber(value(e18, "afterAppend")) == 5.0, "append mutates the variable in place"
expect toNumber(value(e18, "p")) == 5.0, "pop returns the last element"
expect toNumber(value(e18, "pf")) == 1.0, "pop-front returns the first element"
expect stringify(value(e18, "i")) == "[] 2 99 3 4", "insert places a value at a position"
expect stringify(value(e18, "pre")) == "[] 0 7 2 99 3 4", "prepend adds values at the front"
expect toNumber(value(e18, "final")) == 6.0, "the commands keep mutating the same list"

var popEmpty = false
clearCaptured()
try:
  discard runSrc("xs = ([])\npop xs", "")
except:
  popEmpty = true
expect popEmpty, "pop from an empty list fails"
expect find(lastError(), "pop from an empty list") >= 0,
  "pop reports the empty list, got: " & lastError()

var appendNoList = false
clearCaptured()
try:
  discard runSrc("n = 4\nappend n 1", "")
except:
  appendNoList = true
expect appendNoList, "append needs a list variable"
expect find(lastError(), "append needs a list variable") >= 0,
  "append says it needs a list, got: " & lastError()

let e19 = runOk("""
n = nothing
e = do 1 2 3
blk = do:
  a1 = 1
  + a1 1
empty = (do)
""", "")
expect isNothing(value(e19, "n")), "nothing evaluates to the nil value"
expect toNumber(value(e19, "e")) == 3.0, "do returns the last value"
expect toNumber(value(e19, "blk")) == 2.0, "do returns the last form of a block"
expect lookup(e19, symbol("a1")).isNone, "names defined in a do end with it"
expect isNothing(value(e19, "empty")), "an empty do is nothing"

let e20 = runOk("""
count = 0
while (< count 3):
  set count (+ count 1)

p = pair (quote x) 5
eval p
""", "")
expect toNumber(value(e20, "count")) == 3.0, "while loops until the condition fails"
expect toNumber(value(e20, "x")) == 5.0, "pair builds syntax that eval binds"

let e21 = runOk("""
command count-forms body+:
  length body

n = count-forms:
  1
  2
  3
empty = count-forms
""", "")
expect toNumber(value(e21, "n")) == 3.0, "a + parameter collects the caller's block"
expect toNumber(value(e21, "empty")) == 0.0, "no block means an empty body list"

var tooMany = false
clearCaptured()
try:
  discard runSrc("command two a b:\n  1\ntwo 1 2 3", "")
except:
  tooMany = true
expect tooMany, "commands without a + parameter still reject extras"

let e22 = runOk("""
count = 0
bump = lambda:
  set count (+ count 1)

(bump)
(bump)
twice = set count 10
""", "")
expect toNumber(value(e22, "count")) == 10.0, "set updates the binding where it was found"
expect toNumber(value(e22, "twice")) == 10.0, "set returns the new value"

var setUnbound = false
clearCaptured()
try:
  discard runSrc("set missing 1", "")
except:
  setUnbound = true
expect setUnbound, "set on an unbound symbol is a runtime error"
expect find(lastError(), "set on an unbound symbol: missing") >= 0,
  "set reports the missing name, got: " & lastError()

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
expect stringify(value(e23, "s")) == "abcde", "concat joins strings"
expect stringify(value(e23, "l")) == "[] 1 2 3 4", "concat joins lists"
expect stringify(value(e23, "r")) == "{} (x = 1) (y = 2)", "concat merges records"
expect toBool(value(e23, "t")), "true is a boolean literal"
expect toBool(value(e23, "f")), "false is a boolean literal"

var concatMix = false
clearCaptured()
try:
  discard runSrc("x = concat \"a\" ([])", "")
except:
  concatMix = true
expect concatMix, "concat refuses to mix a string with a list"
expect find(lastError(), "concat mixes a string with") >= 0,
  "concat names the kind it mixed, got: " & lastError()

var concatBad = false
clearCaptured()
try:
  discard runSrc("x = concat 1 2", "")
except:
  concatBad = true
expect concatBad, "concat rejects operands that are not string/list/record"
expect find(lastError(), "concat needs strings, lists or records") >= 0,
  "concat says what it accepts, got: " & lastError()

var raised = false
clearCaptured()
try:
  discard runSrc("error \"boom\" \"here\"", "")
except:
  raised = true
expect raised, "error raises a runtime error"
expect find(lastError(), "boom here") >= 0,
  "error joins its message parts, got: " & lastError()

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
expect toNumber(value(e24, "o1")) == 5.0, "or returns the first truthy operand"
expect toNumber(value(e24, "o2")) == 6.0, "or skips nothing"
expect toNumber(value(e24, "o3")) == 7.0, "or skips false"
expect toNumber(value(e24, "a1")) == 6.0, "and returns the second when the first is truthy"
expect isNothing(value(e24, "a2")), "and short-circuits on a falsy first operand"
expect toNumber(value(e24, "w")) == 1.0, "when runs its block when the condition holds"
expect toNumber(value(e24, "u")) == 2.0, "unless runs its block when the condition fails"
expect toBool(value(e24, "ie")), "is-empty on an empty list"
expect toBool(value(e24, "ia")), "is-any on a non-empty list"
expect toNumber(value(e24, "f")) == 8.0, "first returns the head"
expect toNumber(value(e24, "mn")) == 3.0, "min picks the smaller"
expect toNumber(value(e24, "mx")) == 5.0, "max picks the larger"
expect toBool(value(e24, "in1")), "is-nothing on nothing"
expect not toBool(value(e24, "in2")), "is-nothing on a value"

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
expect toNumber(value(e25, "w1")) == 1.0, "when runs its block on a grouped true condition"
expect toNumber(value(e25, "w2")) == 0.0, "when skips its block on a grouped false condition"
expect toNumber(value(e25, "c1")) == 20.0, "cond runs the first matching pair only"
expect toNumber(value(e25, "c2")) == 0.0, "cond does nothing when no pair matches"

var condShort = false
clearCaptured()
try:
  discard runSrc("cond:\n  true = 1\n  true = error \"boom\"", "")
except:
  condShort = true
expect not condShort, "cond stops after the first matching pair"

var condBad = false
clearCaptured()
try:
  discard runSrc("cond 5", "")
except:
  condBad = true
expect condBad, "cond rejects arguments that are not pairs"
expect find(lastError(), "cond needs (test = body) pairs") >= 0,
  "cond says what it needs, got: " & lastError()

var orShort = false
clearCaptured()
try:
  discard runSrc("x = or 5 (error \"boom\")", "")
except:
  orShort = true
expect not orShort, "or does not evaluate its second operand when the first is truthy"

var andShort = false
clearCaptured()
try:
  discard runSrc("x = and nothing (error \"boom\")", "")
except:
  andShort = true
expect not andShort, "and does not evaluate its second operand when the first is falsy"

let eParse = runOk("""
forms = parse (concat "x = 2" newline "+ x 3")
n = length forms
a = eval (pop-front forms)
b = eval (pop-front forms)
""", "")
expect toNumber(value(eParse, "n")) == 2.0, "parse returns one form per top-level expression"
expect toNumber(value(eParse, "b")) == 5.0, "parsed forms evaluate in the caller's env"

var parseBad = false
clearCaptured()
try:
  discard runSrc("x = parse \"(\"", "")
except:
  parseBad = true
expect parseBad, "parse fails on malformed source"
expect find(lastError(), "parse error") >= 0, "parse names the failure, got: " & lastError()

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
expect toNumber(value(eTry, "ok")) == 3.0, "try returns the value when nothing fails"
expect toStr(value(eTry, "bad")) == "caught boom", "try runs the handler with failure bound"
expect isNothing(value(eTry, "quiet")), "try without a handler gives nothing on failure"
expect toNumber(value(eTry, "flag")) == 1.0, "the try handler can set outer variables"
expect errorLines.len == 0, "try keeps caught errors from being reported"

var tryRethrow = false
clearCaptured()
try:
  discard runSrc("try (error \"one\"):\n  error \"two\"", "")
except:
  tryRethrow = true
expect tryRethrow, "an error in the try handler propagates"
expect lastError() == "two", "the handler's error is reported, got: " & lastError()

let eChar = runOk("""
a = char 65
n = to-string 42
s = concat "n=" (to-string 1.5)
""", "")
expect toStr(value(eChar, "a")) == "A", "char builds a one-character string from a byte"
expect toStr(value(eChar, "n")) == "42", "to-string writes whole numbers without a fraction"
expect toStr(value(eChar, "s")) == "n=1.5", "to-string output concatenates with strings"

var charBad = false
clearCaptured()
try:
  discard runSrc("x = char 300", "")
except:
  charBad = true
expect charBad, "char rejects numbers outside a byte"

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
expect toStr(value(eSlice, "s1")) == "el", "slice takes a range of a string"
expect toStr(value(eSlice, "s2")) == "lo", "slice runs to the end without an end"
expect toStr(value(eSlice, "s3")) == "hello", "slice clamps its range"
expect stringify(value(eSlice, "l1")) == "[] 2 3", "slice works on lists"
expect toNumber(value(eSlice, "f1")) == 1.0, "find gives the first position"
expect toNumber(value(eSlice, "f2")) == 3.0, "find starts at the given position"
expect isNothing(value(eSlice, "f3")), "find gives nothing when there is no match"
expect toNumber(value(eSlice, "c1")) == 65.0, "code gives the first byte"
expect toNumber(value(eSlice, "c2")) == 66.0, "code takes a position"

let eAndOr = runOk("""
a = 1
b = 2
x = and (= a 1) (= b 2)
y = or (= b 0) (= a 1)
z = and true false
""", "")
expect toBool(value(eAndOr, "x")), "and sees the caller's a and b"
expect toBool(value(eAndOr, "y")), "or sees the caller's a and b"
expect not toBool(value(eAndOr, "z")), "and is false when an operand is false"

# Commands are hygienic: arguments arrive as syntax that evaluates in the
# caller's scope, and the body runs in the scope the command was defined in.
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
expect toNumber(value(eHygiene, "got")) == 7.0, "a command's parameters never shadow the caller's a and b"
expect toNumber(value(eHygiene, "locals")) == 99.0, "a command's locals never shadow the caller's names"
expect toNumber(value(eHygiene, "doubled")) == 10.0, "a command's local n does not capture the caller's n"
expect toNumber(value(eHygiene, "fresh")) == 10.0, "bind defines a syntax name in the caller's scope"
expect toNumber(value(eHygiene, "made")) == 5.0, "a command's block runs in the caller's scope"
expect toNumber(value(eHygiene, "forms")) == 2.0, "the block sees the caller's forms, not the command's"

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
expect stringify(value(eScoped, "seen")) == "[] 7 107 8 108",
  "a do in a command scopes bind on the caller's side; nested dos nest"
expect lookup(eScoped, symbol("k")).isNone, "a name bound in a command's do ends with the do"
expect lookup(eScoped, symbol("local")).isNone, "names the block defines inside a command's do end with it"
expect toNumber(value(eScoped, "outer")) == 1.0, "= inside a do defines a new local"
expect lookup(eScoped, symbol("hidden")).isNone, "a top-level do's names end with it"

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
  expect lookup(eBlocks, symbol(name)).isNone, name & " ends with its block"
expect toNumber(value(eBlocks, "fresh")) == 6.0, "each while pass gets its own scope"
expect toNumber(value(eBlocks, "kept")) == 5.0, "= in a block defines a local, leaving the outer name"

let eScopes = runOk("""
s = (new-scope)
eval-in s (quote (hidden = 41))
got = eval-in s (quote (+ hidden 1))
""", "")
expect toNumber(value(eScopes, "got")) == 42.0, "eval-in keeps definitions in its scope between calls"
expect lookup(eScopes, symbol("hidden")).isNone, "a new-scope's definitions stay out of the creator's scope"

let eLexical = runOk("""
k = 1
command get-k:
  k
fun shadow:
  k = 2
  (get-k)
inner = (shadow)
""", "")
expect toNumber(value(eLexical, "inner")) == 1.0, "a command's free names resolve where it was defined"

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
expect toNumber(value(eDynamic, "shown")) == 42.0, "a dynamic-command body sees the caller's scope"
expect stringify(value(eDynamic, "code")) == "+ 1 2", "a dynamic-command gets bare forms"
expect qFound.isNone, "a dynamic-command's bindings stay in its own frame"

# to-code: printing a value gives owl code that evaluates back to it, at any
# width (narrow widths force every block form), and printing parsed code
# gives text that parses back to the same forms.
proc evalText(text: string): Object =
  let r = parseOwl(text)
  expect r.isOk, "printed code parses: " & r.error("") & "\n" & text
  result = nothing()
  try:
    let env = newTestEnv()
    for f in r.get(@[]):
      result = eval(f, env)
  except:
    expect false, "printed code evaluates: " & lastError() & "\n" & text

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
    expect evalText(text) == v, "to-code of " & name & " at width " & $width & " reads back:\n" & text
    if width >= 40 and name != "quoted":
      for line in text.split("\n"):
        expect line.len <= width or not line.contains(" = ") or line.startsWith(" "),
          "lines stay within the width where owl can break: " & line

expect toCode(value(printed, "quoted"), 80) ==
  "(concat \"say \" (char 34) \"hi\" (char 34) (char 10) \"tab\tend\")",
  "quotes and newlines become char codes: " & toCode(value(printed, "quoted"), 80)
expect toCode(value(printed, "tasks"), 50) == """[]:
    {} (title = "Hello") (descr = "World!")
    {} (title = "Bye") (descr = "")""", "a list that does not fit breaks into a block:\n" & toCode(value(printed, "tasks"), 50)
expect toCode(value(printed, "tasks"), 30) == """[]:
    {}:
        title = "Hello"
        descr = "World!"
    {}:
        title = "Bye"
        descr = """"", "records break into name = value lines:\n" & toCode(value(printed, "tasks"), 30)
expect toCode(str("hi"), 80) == "\"hi\"", "strings are quoted"
expect toCode(list(newSeq[Object]()), 80) == "([])", "the empty list"

let source = """fun f x (y = 2):
    when (> x y):
        echo "big" x
    + x y

z = [] 1 2

(g)
"""
let parsedSource = parseOwl(source)
expect parsedSource.isOk, "source parses"
for form in parsedSource.get(@[]):
  for width in [10, 80]:
    let text = toCode(form, width)
    let back = parseOwl(text)
    expect back.isOk and back.get(@[]).len == 1 and back.get(@[])[0] == form and
      stringify(back.get(@[])[0]) == stringify(form),
      "printed code parses back to the same form:\n" & text
expect toCode(parsedSource.get(@[])[0], 80) == """fun f x (y = 2):
    when (> x y):
        echo "big" x
    + x y""", "code keeps its blocks:\n" & toCode(parsedSource.get(@[])[0], 80)

let fnEnv = runOk("fun twice x:\n  * x 2", "")
expect toCode(value(fnEnv, "twice"), 80) == "fun twice x:\n    * x 2",
  "a fun prints as its definition: " & toCode(value(fnEnv, "twice"), 80)

# A parameter written &name takes the call's `:` block: a fun gets a closure
# over the caller's scope, a command the forms.
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
expect toNumber(value(blockEnv, "n")) == 2.0, "the block closure ran twice and set the caller's n"
expect toStr(value(blockEnv, "seen")) == "ab", "the block's value comes back: " & stringify(value(blockEnv, "seen"))
expect toStr(value(blockEnv, "plain")) == "c", "without a block the default is kept"
expect toStr(value(blockEnv, "named")) == "de", "a block parameter can be passed by name"
expect toNumber(value(blockEnv, "count")) == 2.0, "a command gets the block's forms"
expect toNumber(value(blockEnv, "none")) == 0.0 or value(blockEnv, "none") == nothing(), "no block, no forms"

finish "evaluator"
