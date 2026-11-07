import std/[syncio, strutils, unittest]
import owl/[lexer, objects, reader, resultshim]
import ./testutils

proc forms(src: string): seq[Object] =
  let r = parseOwl(src)
  if not r.isOk:
    raiseAssert("parse ok, got error: " & r.error(""))
  r.get(@[])

proc errText(src: string): string =
  let r = parseOwl(src)
  if not r.isErr:
    raiseAssert("rejection expected for [" & src & "]")
  if r.isErr: r.error("") else: ""

proc errIs(src, needle: string) =
  let e = errText(src)
  if not (find(e, needle) >= 0):
    raiseAssert("error for [" & src & "] mentions '" & needle & "', got: " & e)

proc toks(src: string): seq[Token] =
  var t = Tokenizer(err: "", line: 0)
  result = @[]
  try:
    result = tokenize(t, src)
  except:
    discard

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

let program = """
fun factorial n (m = 2):
  if (< n m):
    1
    * n (factorial (- n 1))

res = factorial (n = 5) ; could also just be factorial 5
echo res
"""

proc roundTrips(src: string) =
  let fs = forms(src)
  var outp = ""
  for f in fs:
    outp.add stringify(f)
    outp.add "\n"
  if not (forms(strip(outp)) == fs):
    raiseAssert("round trip [" & src & "]")

suite "owl/reader":
  test "indentOf":
    check indentOf("x") == 0, "no indent"
    check indentOf("  x") == 2, "two spaces"
    check indentOf("\t x") == 2, "tab counts as one column"
    check indentOf("") == 0, "empty has no indent"

  test "tokenizer":
    check kinds("").len == 0, "empty text has no tokens"
    check kinds("a b") == @[Word, Word], "space splits words"
    check kinds("a\tb") == @[Word, Word], "tab splits words"
    check kinds("a(b)c") == @[Word, Open, Word, Close, Word], "punctuation splits without spaces"
    check kinds("= :") == @[Eq, Colon], "punctuation tokens"
    check kinds("2.5") == @[Word], "dot is part of a word"
    check kinds("5.") == @[Word], "dot ending a word is part of the number"
    check kinds(".5") == @[Dot, Word], "a number needs its digits before the dot"
    check kinds("a.b") == @[Word, Dot, Word], "dot between words splits them"
    check kinds("a.5") == @[Word, Dot, Word], "dot indexes with a number"
    check kinds("2.b") == @[Word, Dot, Word], "a name after the dot is a key"
    check kinds("r.2.b") == @[Word, Dot, Word, Dot, Word], "a number between dots still chains"
    check kinds("1.2.3") == @[Word, Dot, Word], "only one dot per number"
    check kinds("(f 1).2") == @[Open, Word, Word, Close, Dot, Word], "dot after a group"
    check kinds("\"ab\".1") == @[Str, Dot, Word], "dot after a string"
    check kinds("a ; comment") == @[Word], "comment cuts the line"
    check kinds(";x").len == 0, "comment-only text"
    check kinds("a")[0] == Word and toks("a")[0].text == "a", "word keeps its text"
    check kinds("\"a b\"") == @[Str], "quoted text is one string token"
    check kinds("a \"b\" c") == @[Word, Str, Word], "quotes split surrounding words"
    check kinds("\"a\"")[0] == Str and toks("\"a\"")[0].text == "a", "string keeps its contents"

  test "string escapes":
    check toks("\"a\\\"b\"")[0].text == "a\"b", "an escaped quote stays in the string"
    check toks("\"a\\\\b\"")[0].text == "a\\b", "a doubled backslash is one backslash"
    check toks("\"\\n\\t\\r\\0\\e\"")[0].text == "\n\t\r\0\e", "control escapes"
    check toks("\"\\u{e9}\\u{1F600}\"")[0].text == "\u00e9\u{1F600}", "unicode escapes encode as UTF-8"
    check kinds("\"a\\\" b\" c") == @[Str, Word], "an escaped quote does not end the string"
    check kinds("\"\\\\\" b") == @[Str, Word], "a string may end in an escaped backslash"
    check kinds("\"a ; b\"") == @[Str], "a semicolon in a string is not a comment"
    check toks("x \"a\\\"b\"")[1].len == 6, "the token spans the source, escapes included"
    errIs("\"\\q\"", "unknown escape \\q")
    errIs("\"\\u{}\"", "hex digits in braces")
    errIs("\"\\u41\"", "hex code in braces")
    errIs("\"\\u{110000}\"", "is not a unicode character")
    errIs("\"\\u{d800}\"", "is not a unicode character")
    errIs("\"abc\\\"", "unterminated string")
    errIs("\"abc\\", "unterminated string")

  test "string interpolation":
    check kinds("\"a \\(x) b\"") == @[Interp], "an interpolated string is one token"
    check kinds("\"a \\\\(x) b\"") == @[Str], "an escaped backslash before ( is plain text"
    check toks("\"\\\\(x)\"")[0].text == "\\(x)", "the text keeps the backslash"
    proc same(interpolated, plain: string): bool = forms(interpolated) == forms(plain)
    check same("echo \"hi \\(name)!\"", "echo (interpolate \"hi \" name \"!\")"), "a lone name is its value"
    check same("x = \"\\(+ a 1)\"", "x = interpolate (+ a 1)"), "several items are a call"
    check same("x = \"\\(p.name)\"", "x = interpolate p.name"), "a dotted access is one value"
    check same("x = \"\\((f))\"", "x = interpolate (f)"), "parens call a fun"
    check same("x = \"a\\(concat \"b\\(c)\" \")\")d\"",
      "x = interpolate \"a\" (concat (interpolate \"b\" c) \")\") \"d\""),
      "strings nest inside, with their own parens and interpolation"
    check kinds("\"\\(x)\" y ; c") == @[Interp, Word], "the line goes on after the string"
    errIs("\"\\()\"", "needs an expression inside")
    errIs("\"\\(x\"", "unterminated \\(")
    errIs("\"\\(f \"a)\"", "unterminated")
    errIs("\"\\(a = b = c)\"", "repeated")

  test "scanLines":
    let ls = scan("a\n\n; c\n  b")
    check ls.len == 2, "blank and comment lines skipped"
    check ls[0].num == 1 and ls[1].num == 4, "line numbers count skipped lines"
    check ls[1].indent == 2, "indent recorded per line"
    check ls[0].toks.len == 1, "tokens kept per line"
    check scan("").len == 0, "empty source has no lines"
    check scan("  ; c").len == 0, "indented comment skipped"

  test "tryNumber":
    check isNum("42") and numVal("42") == 42.0, "integer"
    check isNum("+5") and numVal("+5") == 5.0, "leading plus"
    check isNum("-3") and numVal("-3") == -3.0, "negative"
    check isNum("2.5") and numVal("2.5") == 2.5, "decimal"
    check isNum(".5") and numVal(".5") == 0.5, "leading dot"
    check isNum("5.") and numVal("5.") == 5.0, "trailing dot"
    check isNum("-2.25") and numVal("-2.25") == -2.25, "negative decimal"
    check not isNum(""), "empty is not a number"
    check not isNum("-"), "bare sign is not a number"
    check not isNum("+"), "bare plus is not a number"
    check not isNum("."), "bare dot is not a number"
    check not isNum("5x"), "trailing junk"
    check not isNum("1.2.3"), "two dots"
    check not isNum("1e5"), "no exponents"
    check numVal("0.3") == 0.3 and numVal("0.7") == 0.7 and numVal("-1.1") == -1.1,
      "decimals read as the nearest double, not a digit-by-digit sum"
    check not isNum("0x10"), "no hex"

  test "atom":
    check atom("42") == number(42.0), "atom parses numbers"
    check atom("x") == symbol("x"), "atom falls back to symbol"
    check atom("-") == symbol("-"), "bare sign is a symbol"

  test "forms basics":
    check forms("").len == 0, "empty program"
    check forms("  \n ; x").len == 0, "blank and comment program"
    check forms("a").len == 1 and forms("a")[0] == symbol("a"), "bare symbol is one form"
    check forms("a\nb").len == 2, "two lines are two forms"
    let fs = forms("a b c")
    check fs.len == 1, "one form"
    let items = toSeq(fs[0])
    check items.len == 3, "a b c -> list of 3"
    check toSymbol(items[0]) == "a" and toSymbol(items[2]) == "c", "head and last arg"
    check forms("(a)")[0] == list(@[symbol("a")]), "a one-symbol group is a call"
    check forms("a")[0] == symbol("a"), "a bare symbol stays a reference"
    check forms("(a)") != forms("a"), "a call is not a reference"
    check forms("(a)") == forms("((a))"), "double parens are transparent"

  test "numbers and strings as forms":
    check toNumber(forms("42")[0]) == 42.0 and toSymbol(forms("42")[0]) == "", "42 is a number"
    check toNumber(forms("2.5")[0]) == 2.5, "2.5 is a float"
    check toNumber(forms("-3")[0]) == -3.0, "-3 is a negative number"
    check toSymbol(forms("5x")[0]) == "5x", "5x is a symbol"
    check forms("42 2.5 -3")[0] == list(@[number(42.0), number(2.5), number(-3.0)]), "numbers as args"
    check forms("x = \"hi there\"")[0] == pair(symbol("x"), str("hi there")), "string literal as a value"
    check forms("\"a b\"")[0] == str("a b"), "bare string is one form"

  test "nested groups":
    let fs = forms("a (b c)")
    check toSeq(fs[0]).len == 2, "group is one argument"
    check toSeq(toSeq(fs[0])[1]).len == 2, "the group is a list"
    check forms("a ((b c))") == forms("a (b c)"), "double-paren groups flatten"
    check forms("(b (c))")[0] == list(@[symbol("b"), list(@[symbol("c")])]), "a group of one symbol stays a call"

  test "spanning groups":
    let spanning = forms("(hello foo\n       bar\n       baz)")
    check spanning.len == 1, "an aligned group over lines is one form"
    check spanning[0] == forms("hello foo bar baz")[0], "aligned lines fold into one call"
    check forms("(hello\n  foo\n  bar\n  baz)")[0] == forms("hello foo bar baz")[0], "a group opened at the head also spans"
    check forms("(hello\n\t\tbar)") == forms("hello bar"), "tabs inside a group are plain space"
    check forms("(hello\n\n  ; just a comment\n  foo)") == forms("hello foo"),
      "blank and comment lines inside a group are skipped"
    check forms("(hello\n  foo) bar") == forms("(hello foo) bar"), "a group can end mid line and carry on"
    check forms("x = (hello\n  foo)") == forms("x = hello foo"), "a group binding spans lines"
    check forms("a (b c\n  d)") == forms("a (b c d)"), "a spanning group is one argument"
    check forms("(a\n  (b\n    c))") == forms("(a (b c))"), "groups span inside groups"
    check forms("(a\n  b):\n  c") == forms("(a b) c"), "a spanning group opens a block and keeps its shape"
    check forms("f:\n  (g a\n    b)\n  c") == forms("f (g a b) c"),
      "a spanning group keeps its place in a block, whatever its own indent"
    check forms("f:\n  (g a\nb)\n  c") == forms("f (g a b) c"),
      "inside a group even a dedent out of the block is just space"
    check forms("(hello\n  a.b)") == forms("(hello a.b)"), "dots still fold across a spanning group"

  test "dot indexing":
    let fs = forms("a.b")
    check fs[0] == forms("index a b")[0], "dot is syntax for the index command"
    check toSeq(fs[0]).len == 3, "a.b is one index call"
    check toSymbol(toSeq(fs[0])[0]) == "index", "the head is index"
    check toSymbol(toSeq(fs[0])[2]) == "b", "the key is the name after the dot"
    check forms("a.b.c") == forms("index (index a b) c"), "indexing chains to the left"
    check forms("a.b.c.d") == forms("index (index (index a b) c) d"), "chains keep folding"
    check cdr(forms("x = (w.f)")[0]) == list(@[forms("index w f")[0]]),
      "a dotted access alone in parentheses is a call, like (f)"
    check cdr(forms("x = (w.f.g)")[0]) == list(@[forms("index (index w f) g")[0]]),
      "a dotted chain alone in parentheses is one call"
    check cdr(forms("x = (w.f 1)")[0]) == list(@[forms("index w f")[0], number(1)]),
      "with arguments it is the usual call"
    check cdr(forms("x = w.f")[0]) == forms("index w f")[0], "without parentheses it is the field"
    check cdr(forms("x = ((index w f))")[0]) == forms("index w f")[0],
      "a group in parentheses stays a group, not a call"
    check forms("a.2") == forms("index a 2"), "a dot can carry a position"
    check forms("a.2.b") == forms("index (index a 2) b"), "positions chain with names"
    check forms("a.(+ x 1)") == forms("index a (+ x 1)"), "a group is one key"
    check forms("a.(+ x 1).b") == forms("index (index a (+ x 1)) b"), "a group key chains"
    check forms("a.(+ x 1).(quote b)") == forms("index (index a (+ x 1)) (quote b)"), "a chain ends in a group key"
    check forms("a.\"k\"") == forms("index a \"k\""), "a string is one key"
    check forms("echo a.b") == forms("echo (index a b)"), "a dotted value is one argument"
    check forms("a.b c") == forms("(index a b) c"), "a dotted value heads a call"
    check forms("v = a.b")[0] == pair(symbol("v"), forms("index a b")[0]), "dot in a binding"
    check forms("x = \"a.b\"")[0] == pair(symbol("x"), str("a.b")), "dots inside strings stay"
    check forms("(f a).b") == forms("index (f a) b"), "dot after a group indexes it"
    check forms("a.b:\n  c") == forms("(index a b) c"), "a dotted head takes a block"
    let fs2 = forms("xs.0")
    check toNumber(toSeq(fs2[0])[2]) == 0.0, "a dotted position is a number"

  test "blocks":
    check forms("a b:\n  c") == forms("a b c"), "block flattens into the call"
    check forms("a b:\n\tc") == forms("a b c"), "tab indent works too"
    check forms("a:\n  b\n  c") == forms("a b c"), "multi-line block"
    check forms("f:\n  g:\n    h") == forms("f (g h)"), "nested blocks"
    check forms("a b:\n  c d\n  e") == forms("a b (c d) e"), "block lines keep their shape"
    check forms("a:\n  b\n") == forms("a b"), "trailing newline after a block"

  test "bindings":
    let fs = forms("x = 5")
    check fs[0] == pair(symbol("x"), number(5)), "a = b is a Pair"
    check toSymbol(car(fs[0])) == "x", "pair key"
    check toNumber(cdr(fs[0])) == 5.0, "pair value"
    check forms("a = b c")[0] == pair(symbol("a"), list(@[symbol("b"), symbol("c")])), "binding with several values"
    let res = forms("res = factorial (n = 5)")
    check toSymbol(car(res[0])) == "res", "binding target"
    let items = toSeq(cdr(res[0]))
    check toSymbol(items[0]) == "factorial", "call head"
    check toSymbol(car(items[1])) == "n" and toNumber(cdr(items[1])) == 5.0, "named argument is a pair"
    check forms("x = f:\n  a b")[0] ==
      pair(symbol("x"), list(@[symbol("f"), list(@[symbol("a"), symbol("b")])])), "binding with a block"
    check forms("(= it 1) = echo \"hi\"")[0] ==
      pair(list(@[symbol("="), symbol("it"), number(1.0)]), list(@[symbol("echo"), str("hi")])),
      "a grouped call may head a binding"
    check forms("(a) = b")[0] == pair(list(@[symbol("a")]), symbol("b")), "a grouped name heads a binding as a call"
    check forms("(<> it 1) = e:\n  f")[0] ==
      pair(list(@[symbol("<>"), symbol("it"), number(1.0)]), list(@[symbol("e"), symbol("f")])),
      "a grouped call binding keeps its block"

  test "equality command":
    let fs = forms("= 1 1")
    check fs[0] == list(@[symbol("="), number(1.0), number(1.0)]), "a leading '=' is the equality command"
    check forms("= 1 1") == forms("(= 1 1)"), "parens around a command call are transparent"
    check forms("<> 1 2")[0] == list(@[symbol("<>"), number(1.0), number(2.0)]), "'<>' heads a call"
    check forms("= a b")[0] == list(@[symbol("="), symbol("a"), symbol("b")]), "equality on names"
    check forms("not (= 1 1)")[0] == list(@[symbol("not"), forms("= 1 1")[0]]),
      "an equality call is one argument"
    check forms("= 1 1:\n  2")[0] ==
      list(@[symbol("="), number(1.0), number(1.0), number(2.0)], 3), "the equality command takes a block"
    check forms("x = = 1 1")[0] == pair(symbol("x"), fs[0]),
      "a binding value may start with the equality command"
    check forms("x = <> 1 2")[0] == pair(symbol("x"), forms("<> 1 2")[0]),
      "a binding value may start with the inequality command"

  test "comments":
    let fs = forms("a b ; trailing comment\nc")
    check fs.len == 2 and toSymbol(toSeq(fs[0])[1]) == "b", "trailing comment cut"
    check fs[1] == symbol("c"), "next line parsed as bare symbol"
    check forms("; whole line comment\na").len == 1, "comment-only line skipped"

  test "doc example":
    let fs = forms(program)
    check fs.len == 3, "doc example has 3 top level forms, got " & $fs.len
    let funForm = toSeq(fs[0])
    check funForm.len == 5, "fun: head, name, param, default, body"
    check toSymbol(funForm[0]) == "fun" and toSymbol(funForm[1]) == "factorial", "fun head/name"
    check toSymbol(funForm[2]) == "n", "param n"
    check toSymbol(car(funForm[3])) == "m" and toNumber(cdr(funForm[3])) == 2.0, "default arg (m = 2)"
    let body = toSeq(funForm[4])
    check body.len == 4 and toSymbol(body[0]) == "if", "body is if with 3 args"
    check toSymbol(toSeq(body[1])[0]) == "<", "condition (< n m)"
    check toNumber(body[2]) == 1.0, "then branch is 1"
    let mul = toSeq(body[3])
    check mul.len == 3 and toSymbol(mul[0]) == "*", "else branch is (* ...)"
    let fact = toSeq(mul[2])
    check fact.len == 2 and toSymbol(fact[0]) == "factorial", "nested (factorial ...)"
    let sub = toSeq(fact[1])
    check sub.len == 3 and toSymbol(sub[0]) == "-", "(- n 1)"
    check toSymbol(car(fs[1])) == "res", "res = ... binding"
    check toSeq(fs[2]).len == 2 and toSymbol(toSeq(fs[2])[1]) == "res", "echo res"

  test "read errors":
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
    errIs("(a\n  b", "expected ')'")
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
    check startsWith(e, "line 2:"), "error names the offending line, got: " & e

  test "round trips":
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

  test "CRLF":
    check forms("fun f x:\r\n  g x \"a b\"\r\n\r\ny = 1\r\n") == forms("fun f x:\n  g x \"a b\"\n\ny = 1\n"),
      "CRLF line ends read like LF ones"
