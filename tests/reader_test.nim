import std/[syncio, result, strutils]
import owl/[lexer, objects, reader]
import ./testutils

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

proc toks(src: string): seq[Token] =
  var t = Tokenizer(err: "", line: 0)
  result = @[]
  try:
    result = tokenize(t, src)
  except:
    discard  # unterminated input is exercised through parseOwl instead

proc scan(src: string): seq[Line] =
  var t = Tokenizer(err: "", line: 0)
  result = @[]
  try:
    result = scanLines(t, src)
  except:
    discard

proc kinds(src: string): seq[TokenKind] =
  result = @[]
  for t in toks(src):
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
expect kinds("5.") == @[Word], "dot ending a word is part of the number"
expect kinds(".5") == @[Dot, Word], "a number needs its digits before the dot"
expect kinds("a.b") == @[Word, Dot, Word], "dot between words splits them"
expect kinds("a.5") == @[Word, Dot, Word], "dot indexes with a number"
expect kinds("2.b") == @[Word, Dot, Word], "a name after the dot is a key"
expect kinds("r.2.b") == @[Word, Dot, Word, Dot, Word], "a number between dots still chains"
expect kinds("1.2.3") == @[Word, Dot, Word], "only one dot per number"
expect kinds("(f 1).2") == @[Open, Word, Word, Close, Dot, Word], "dot after a group"
expect kinds("\"ab\".1") == @[Str, Dot, Word], "dot after a string"
expect kinds("a ; comment") == @[Word], "comment cuts the line"
expect kinds(";x").len == 0, "comment-only text"
expect kinds("a")[0] == Word and toks("a")[0].text == "a", "word keeps its text"
expect kinds("\"a b\"") == @[Str], "quoted text is one string token"
expect kinds("a \"b\" c") == @[Word, Str, Word], "quotes split surrounding words"
expect kinds("\"a\"")[0] == Str and toks("\"a\"")[0].text == "a", "string keeps its contents"

let ls = scan("a\n\n; c\n  b")
expect ls.len == 2, "blank and comment lines skipped"
expect ls[0].num == 1 and ls[1].num == 4, "line numbers count skipped lines"
expect ls[1].indent == 2, "indent recorded per line"
expect ls[0].toks.len == 1, "tokens kept per line"
expect scan("").len == 0, "empty source has no lines"
expect scan("  ; c").len == 0, "indented comment skipped"

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
expect forms("(a)")[0] == list(@[symbol("a")]), "a one-symbol group is a call"
expect forms("a")[0] == symbol("a"), "a bare symbol stays a reference"
expect forms("(a)") != forms("a"), "a call is not a reference"
expect forms("(a)") == forms("((a))"), "double parens are transparent"

expect toNumber(forms("42")[0]) == 42.0 and toSymbol(forms("42")[0]) == "", "42 is a number"
expect toNumber(forms("2.5")[0]) == 2.5, "2.5 is a float"
expect toNumber(forms("-3")[0]) == -3.0, "-3 is a negative number"
expect toSymbol(forms("5x")[0]) == "5x", "5x is a symbol"
expect forms("42 2.5 -3")[0] == list(@[number(42.0), number(2.5), number(-3.0)]), "numbers as args"
expect forms("x = \"hi there\"")[0] == pair(symbol("x"), str("hi there")), "string literal as a value"
expect forms("\"a b\"")[0] == str("a b"), "bare string is one form"

fs = forms("a (b c)")
expect toSeq(fs[0]).len == 2, "group is one argument"
expect toSeq(toSeq(fs[0])[1]).len == 2, "the group is a list"
expect forms("a ((b c))") == forms("a (b c)"), "double-paren groups flatten"
expect forms("(b (c))")[0] == list(@[symbol("b"), list(@[symbol("c")])]), "a group of one symbol stays a call"

fs = forms("a.b")
expect fs[0] == forms("index a b")[0], "dot is syntax for the index command"
expect toSeq(fs[0]).len == 3, "a.b is one index call"
expect toSymbol(toSeq(fs[0])[0]) == "index", "the head is index"
expect toSymbol(toSeq(fs[0])[2]) == "b", "the key is the name after the dot"
expect forms("a.b.c") == forms("index (index a b) c"), "indexing chains to the left"
expect forms("a.b.c.d") == forms("index (index (index a b) c) d"), "chains keep folding"
expect forms("a.2") == forms("index a 2"), "a dot can carry a position"
expect forms("a.2.b") == forms("index (index a 2) b"), "positions chain with names"
expect forms("a.(+ x 1)") == forms("index a (+ x 1)"), "a group is one key"
expect forms("a.(+ x 1).b") == forms("index (index a (+ x 1)) b"), "a group key chains"
expect forms("a.(+ x 1).(quote b)") == forms("index (index a (+ x 1)) (quote b)"), "a chain ends in a group key"
expect forms("a.\"k\"") == forms("index a \"k\""), "a string is one key"
expect forms("echo a.b") == forms("echo (index a b)"), "a dotted value is one argument"
expect forms("a.b c") == forms("(index a b) c"), "a dotted value heads a call"
expect forms("v = a.b")[0] == pair(symbol("v"), forms("index a b")[0]), "dot in a binding"
expect forms("x = \"a.b\"")[0] == pair(symbol("x"), str("a.b")), "dots inside strings stay"
expect forms("(f a).b") == forms("index (f a) b"), "dot after a group indexes it"
expect forms("a.b:\n  c") == forms("(index a b) c"), "a dotted head takes a block"

fs = forms("xs.0")
expect toNumber(toSeq(fs[0])[2]) == 0.0, "a dotted position is a number"

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
expect forms("(= it 1) = echo \"hi\"")[0] ==
  pair(list(@[symbol("="), symbol("it"), number(1.0)]), list(@[symbol("echo"), str("hi")])),
  "a grouped call may head a binding"
expect forms("(a) = b")[0] == pair(list(@[symbol("a")]), symbol("b")), "a grouped name heads a binding as a call"
expect forms("(<> it 1) = e:\n  f")[0] ==
  pair(list(@[symbol("<>"), symbol("it"), number(1.0)]), list(@[symbol("e"), symbol("f")])),
  "a grouped call binding keeps its block"

fs = forms("= 1 1")
expect fs[0] == list(@[symbol("="), number(1.0), number(1.0)]), "a leading '=' is the equality command"
expect forms("= 1 1") == forms("(= 1 1)"), "parens around a command call are transparent"
expect forms("<> 1 2")[0] == list(@[symbol("<>"), number(1.0), number(2.0)]), "'<>' heads a call"
expect forms("= a b")[0] == list(@[symbol("="), symbol("a"), symbol("b")]), "equality on names"
expect forms("not (= 1 1)")[0] == list(@[symbol("not"), forms("= 1 1")[0]]),
  "an equality call is one argument"
expect forms("= 1 1:\n  2")[0] ==
  list(@[symbol("="), number(1.0), number(1.0), number(2.0)], 3), "the equality command takes a block"
expect forms("x = = 1 1")[0] == pair(symbol("x"), fs[0]),
  "a binding value may start with the equality command"
expect forms("x = <> 1 2")[0] == pair(symbol("x"), forms("<> 1 2")[0]),
  "a binding value may start with the inequality command"

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
errIs("a b = c", "name or a grouped call")
errIs("= a = b", "name or a grouped call")
errIs("(a b", "expected ')'")
errIs("a b)", "unexpected ')'")
errIs("echo \"unclosed", "unterminated string")
errIs("\"", "unterminated string")
errIs("a\nb \"oops", "line 2: unterminated string")
errIs("()", "empty expression")
errIs(".a", "needs a value before")
errIs("a.", "needs a key after")
errIs("x = .a", "needs a value before")
errIs("a.b.", "needs a key after")
errIs("(a.)", "needs a key after")
errIs("a.=b", "needs a key after")
errIs("a..b", "needs a key after")
errIs("a\nb.c.", "needs a key after")
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
roundTrips("a.b")
roundTrips("a.b.c")
roundTrips("a.2.b")
roundTrips("x = 5")
roundTrips("= 1 1")
roundTrips("x = = 1 1")
roundTrips("a = = b")
roundTrips("not (= 1 1)")
roundTrips("<> 1 2")
roundTrips("res = factorial (n = 5)")
roundTrips("a (b c)")
roundTrips("[] 42 2.5 -3")
roundTrips("a b:\n  c")
roundTrips("[] 1 2 3")
roundTrips("{} (x = 100) (y = 200)")
roundTrips("[] 1 ([] 2 3)")
roundTrips("v2 = {}:\n  x = 100\n  y = 200")
roundTrips("xs = []:\n  1\n  2\n  3")
roundTrips(program)

finish "reader"
