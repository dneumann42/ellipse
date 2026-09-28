import std/[syncio, result, strutils]
import owl/[objects, reader]

var failures = 0

proc expect(cond: bool, msg: string) =
  if not cond:
    failures += 1
    echo "FAILED: ", msg

proc forms(src: string): seq[Object] =
  let r = parseOwl(src)
  expect r.isOk, "parse ok, got error: " & r.error("")
  result = r.get(@[])

# 1. a b c is a call of a with args b c
var fs = forms("a b c")
expect fs.len == 1, "one form"
var items = toSeq(fs[0])
expect items.len == 3, "a b c -> list of 3"
expect toSymbol(items[0]) == "a" and toSymbol(items[2]) == "c", "head and last arg"

# 2. the ephemeral colon: a b:\n  c parses to the exact same list
expect forms("a b:\n  c") == forms("a b c"), "indent block == flat call"
expect forms("a b:\n\tc") == forms("a b c"), "tab indent works too"
expect forms("a:\n  b\n  c") == forms("a b c"), "multi-line block"

# 3. single atoms; numbers vs symbols
expect toNumber(forms("42")[0]) == 42.0 and toSymbol(forms("42")[0]) == "", "42 is a number"
expect toSymbol(forms("-")[0]) == "-", "'-' alone is a symbol"
expect toNumber(forms("2.5")[0]) == 2.5, "2.5 is a float"
expect toNumber(forms("-3")[0]) == -3.0, "-3 is a negative number"
expect toSymbol(forms("5x")[0]) == "5x", "5x is a symbol"

# 4. parens group explicitly
fs = forms("a (b c)")
expect toSeq(fs[0]).len == 2, "group is one argument"
expect toSeq(toSeq(fs[0])[1]).len == 2, "the group is a list"

# 5. bindings produce pairs
fs = forms("x = 5")
expect fs[0] == pair(symbol("x"), number(5)), "a = b is a Pair"
expect toSymbol(car(fs[0])) == "x", "pair key"
expect toNumber(cdr(fs[0])) == 5.0, "pair value"
fs = forms("res = factorial (n = 5)")
expect toSymbol(car(fs[0])) == "res", "binding target"
items = toSeq(cdr(fs[0]))
expect toSymbol(items[0]) == "factorial", "call head"
expect toSymbol(car(items[1])) == "n" and toNumber(cdr(items[1])) == 5.0, "named argument is a pair"

# 6. comments
fs = forms("a b ; trailing comment\nc")
expect fs.len == 2 and toSymbol(toSeq(fs[0])[1]) == "b", "trailing comment cut"
expect toSymbol(fs[1]) == "c", "next line parsed as bare symbol"
fs = forms("; whole line comment\na")
expect fs.len == 1, "comment-only line skipped"

# 7. nested blocks: the design doc example
let program = """
fun factorial n (m = 2):
  if (< n m):
    1
    * n (factorial (- n 1))

res = factorial (n = 5) ; could also just be factorial 5
echo res
"""
fs = forms(program)
expect fs.len == 3, "doc example has 3 top level forms, got " & $fs.len
let funForm = toSeq(fs[0])
expect funForm.len == 5, "fun: head, name, param, default, body"
expect toSymbol(funForm[0]) == "fun" and toSymbol(funForm[1]) == "factorial", "fun head/name"
expect toSymbol(funForm[2]) == "n", "param n"
expect toSymbol(car(funForm[3])) == "m" and toNumber(cdr(funForm[3])) == 2.0, "default arg (m = 2)"
let body = toSeq(funForm[4])
expect body.len == 4 and toSymbol(body[0]) == "if", "body is if with 3 args"
expect toSymbol(toSeq(body[1])[0]) == "<", "condition (< n m)"
expect toNumber(body[2]) == 1.0, "then branch is 1"
let mul = toSeq(body[3])
expect mul.len == 3 and toSymbol(mul[0]) == "*", "else branch is (* ...)"
let fact = toSeq(mul[2])
expect fact.len == 2 and toSymbol(fact[0]) == "factorial", "nested (factorial ...)"
let sub = toSeq(fact[1])
expect sub.len == 3 and toSymbol(sub[0]) == "-", "(- n 1)"
expect toSymbol(car(fs[1])) == "res", "res = ... binding"
expect toSeq(fs[2]).len == 2 and toSymbol(toSeq(fs[2])[1]) == "res", "echo res"

# 8. empty colon block just yields the line's own elements
expect forms("a b:") == forms("a b"), "colon with no block is ephemeral"

# 9. ambiguity and syntax errors are rejected
proc errIs(src, needle: string) =
  let r = parseOwl(src)
  expect r.isErr, "rejection expected for [" & src & "]"
  if r.isErr:
    let e = r.error("")
    expect find(e, needle) >= 0, "error mentions '" & needle & "', got: " & e

errIs("a b\n  c", "indentation")       # indented lines only follow a ':'
errIs("x = a = b", "repeated")         # '=' does not chain
errIs("a b = c", "single name")        # binding target must be one symbol
errIs("(a b", "expected ')'")          # unbalanced group
errIs("a b)", "unexpected ')'")        # stray close
errIs("()", "empty expression")         # empty group
errIs("a = ", "missing value")          # dangling binding
errIs("a : b", "must end the line")     # colon mid-line
errIs("  indented", "indentation")      # program cannot start indented
errIs("a:\n  b\n    c", "indentation")   # block lines must align

if failures == 0:
  echo "reader tests OK"
else:
  quit "reader tests failed: " & $failures
