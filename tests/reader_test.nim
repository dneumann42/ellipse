import std/[syncio, result, strutils]
import owl/[lexer, objects, reader]

var failures = 0

proc expect(cond: bool, msg: string) =
  if not cond:
    failures += 1
    echo "FAILED: ", msg

proc forms(src: string): seq[Object] =
  let r = parseOwl(src)
  expect r.isOk, "parse ok, got error: " & r.error("")
  result = r.get(@[])

proc errText(src: string): string =
  let r = parseOwl(src)
  expect r.isErr, "rejection expected for [" & src & "]"
  result = if r.isErr: r.error("") else: ""

proc errIs(src, needle: string) =
  let e = errText(src)
  expect find(e, needle) >= 0, "error for [" & src & "] mentions '" & needle & "', got: " & e

proc kinds(src: string): seq[TokenKind] =
  result = @[]
  for t in tokenize(src):
    result.add t.kind

func isNum(text: string): bool =
  let (yes, val) = tryNumber(text)
  discard val
  result = yes

func numVal(text: string): float64 =
  let (yes, val) = tryNumber(text)
  discard yes
  result = val

expect indentOf("x") == 0, "no indent"
expect indentOf("  x") == 2, "two spaces"
expect indentOf("\t x") == 2, "tab counts as one column"
expect indentOf("") == 0, "empty has no indent"

expect kinds("").len == 0, "empty text has no tokens"
expect kinds("a b") == @[Word, Word], "space splits words"
expect kinds("a\tb") == @[Word, Word], "tab splits words"
expect kinds("a(b)c") == @[Word, Open, Word, Close, Word], "punctuation splits without spaces"
expect kinds("= :") == @[Eq, Colon], "punctuation tokens"
expect kinds("2.5") == @[Word], "dot is part of a word"
expect kinds("a ; comment") == @[Word], "comment cuts the line"
expect kinds(";x").len == 0, "comment-only text"
expect kinds("a")[0] == Word and tokenize("a")[0].text == "a", "word keeps its text"

let ls = scanLines("a\n\n; c\n  b")
expect ls.len == 2, "blank and comment lines skipped"
expect ls[0].num == 1 and ls[1].num == 4, "line numbers count skipped lines"
expect ls[1].indent == 2, "indent recorded per line"
expect ls[0].toks.len == 1, "tokens kept per line"
expect scanLines("").len == 0, "empty source has no lines"
expect scanLines("  ; c").len == 0, "indented comment skipped"

expect isNum("42") and numVal("42") == 42.0, "integer"
expect isNum("+5") and numVal("+5") == 5.0, "leading plus"
expect isNum("-3") and numVal("-3") == -3.0, "negative"
expect isNum("2.5") and numVal("2.5") == 2.5, "decimal"
expect isNum(".5") and numVal(".5") == 0.5, "leading dot"
expect isNum("5.") and numVal("5.") == 5.0, "trailing dot"
expect isNum("-2.25") and numVal("-2.25") == -2.25, "negative decimal"
expect not isNum(""), "empty is not a number"
expect not isNum("-"), "bare sign is not a number"
expect not isNum("+"), "bare plus is not a number"
expect not isNum("."), "bare dot is not a number"
expect not isNum("5x"), "trailing junk"
expect not isNum("1.2.3"), "two dots"
expect not isNum("1e5"), "no exponents"
expect not isNum("0x10"), "no hex"

expect atom("42") == number(42.0), "atom parses numbers"
expect atom("x") == symbol("x"), "atom falls back to symbol"
expect atom("-") == symbol("-"), "bare sign is a symbol"

expect forms("").len == 0, "empty program"
expect forms("  \n ; x").len == 0, "blank and comment program"
expect forms("a").len == 1 and forms("a")[0] == symbol("a"), "bare symbol is one form"
expect forms("a\nb").len == 2, "two lines are two forms"

var fs = forms("a b c")
expect fs.len == 1, "one form"
var items = toSeq(fs[0])
expect items.len == 3, "a b c -> list of 3"
expect toSymbol(items[0]) == "a" and toSymbol(items[2]) == "c", "head and last arg"
expect forms("a") == forms("(a)"), "outer parens are transparent"
expect forms("(a)") == forms("((a))"), "double parens are transparent"

expect toNumber(forms("42")[0]) == 42.0 and toSymbol(forms("42")[0]) == "", "42 is a number"
expect toNumber(forms("2.5")[0]) == 2.5, "2.5 is a float"
expect toNumber(forms("-3")[0]) == -3.0, "-3 is a negative number"
expect toSymbol(forms("5x")[0]) == "5x", "5x is a symbol"
expect forms("42 2.5 -3")[0] == list(@[number(42.0), number(2.5), number(-3.0)]), "numbers as args"

fs = forms("a (b c)")
expect toSeq(fs[0]).len == 2, "group is one argument"
expect toSeq(toSeq(fs[0])[1]).len == 2, "the group is a list"
expect forms("a (b (c))") == forms("a (b c)"), "nested groups flatten"

expect forms("a b:\n  c") == forms("a b c"), "block flattens into the call"
expect forms("a b:\n\tc") == forms("a b c"), "tab indent works too"
expect forms("a:\n  b\n  c") == forms("a b c"), "multi-line block"
expect forms("f:\n  g:\n    h") == forms("f (g h)"), "nested blocks"
expect forms("a b:\n  c d\n  e") == forms("a b (c d) e"), "block lines keep their shape"
expect forms("a:\n  b\n") == forms("a b"), "trailing newline after a block"

fs = forms("x = 5")
expect fs[0] == pair(symbol("x"), number(5)), "a = b is a Pair"
expect toSymbol(car(fs[0])) == "x", "pair key"
expect toNumber(cdr(fs[0])) == 5.0, "pair value"
expect forms("a = b c")[0] == pair(symbol("a"), list(@[symbol("b"), symbol("c")])), "binding with several values"
fs = forms("res = factorial (n = 5)")
expect toSymbol(car(fs[0])) == "res", "binding target"
items = toSeq(cdr(fs[0]))
expect toSymbol(items[0]) == "factorial", "call head"
expect toSymbol(car(items[1])) == "n" and toNumber(cdr(items[1])) == 5.0, "named argument is a pair"
expect forms("x = f:\n  a b")[0] ==
  pair(symbol("x"), list(@[symbol("f"), list(@[symbol("a"), symbol("b")])])), "binding with a block"

fs = forms("a b ; trailing comment\nc")
expect fs.len == 2 and toSymbol(toSeq(fs[0])[1]) == "b", "trailing comment cut"
expect fs[1] == symbol("c"), "next line parsed as bare symbol"
expect forms("; whole line comment\na").len == 1, "comment-only line skipped"

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

errIs("a b:", "missing block")
errIs("a b:\nc", "missing block")
errIs("a b:\n  ; only a comment", "missing block")
errIs(":", "missing block")
errIs("a b\n  c", "indentation")
errIs("  indented", "indentation")
errIs("a:\n  b\n    c", "indentation")
errIs("x = a = b", "repeated")
errIs("a = = b", "repeated")
errIs("a b = c", "single name")
errIs("= c", "single name")
errIs("(a b", "expected ')'")
errIs("a b)", "unexpected ')'")
errIs("()", "empty expression")
errIs("a = ", "missing value")
errIs("a : b", "must end the line")
errIs("(a :)", "must end the line")
errIs("a::", "missing block")
errIs("a::\n  b", "must end the line")

let e = errText("a b\n  c")
expect startsWith(e, "line 2:"), "error names the offending line, got: " & e

proc roundTrips(src: string) =
  let fs = forms(src)
  var outp = ""
  for f in fs:
    outp.add stringify(f)
    outp.add "\n"
  expect forms(strip(outp)) == fs, "round trip [" & src & "]"

roundTrips("a b c")
roundTrips("x = 5")
roundTrips("res = factorial (n = 5)")
roundTrips("a (b c)")
roundTrips("42 2.5 -3")
roundTrips("a b:\n  c")
roundTrips(program)

if failures == 0:
  echo "reader tests OK"
else:
  quit "reader tests failed: " & $failures
