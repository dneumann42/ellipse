import std/[syncio, options, unittest]
import owl/objects
import ./testutils

suite "owl/objects":
  test "conversions":
    check toNumber(number(2.5)) == 2.5 and toSymbol(number(2.5)) == "", "total conversions"
    check not toBool(nothing()), "nothing is falsy"
    check toNumber(number(2.5)) == 2.5, "number identity"
    check toNumber(boolean(true)) == 1.0, "true converts to 1"
    check toNumber(boolean(false)) == 0.0, "false converts to 0"
    check toNumber(symbol("x")) == 0.0, "symbol converts to 0"
    check toNumber(nothing()) == 0.0, "nothing converts to 0"
    check not toBool(nothing()), "nothing is falsy"
    check not toBool(boolean(false)), "false is falsy"
    check toBool(boolean(true)), "true is truthy"
    check toBool(number(0)), "only nothing and false are falsy"
    check toSymbol(symbol("hi")) == "hi", "symbol name"
    check toSymbol(number(1)) == "", "non-symbol has no name"

  test "lists and pairs":
    let xs = list(@[number(1), number(2)])
    check toSeq(xs).len == 2, "list converts to its elements"
    check toSeq(nothing()).len == 0, "non-list converts to empty"
    let pr = pair(symbol("k"), number(7))
    check toSymbol(car(pr)) == "k", "car of pair"
    check toNumber(cdr(pr)) == 7.0, "cdr of pair"
    check car(number(1)) == nothing(), "car of non-pair is nothing"
    check pr == pair(symbol("k"), number(7)), "pairs compare by structure"
    check xs != list(@[number(1), number(2), number(3)]), "lists by length"

  test "repr":
    check $nothing() == "(kind: Nothing)", "$ of nothing"
    check $number(2.5) == "(kind: Number, number: 2.5)", "$ of number"
    check $boolean(true) == "(kind: Boolean, isTrue: true)", "$ of boolean"
    check $symbol("hi") == "(kind: Symbol, symbol: \"hi\")", "$ of symbol"
    check $list(@[number(1)]) == "(kind: List, items: @[(kind: Number, number: 1.0)])", "$ of list"
    check $pair(symbol("k"), number(7)) ==
      "(kind: Pair, a: (kind: Symbol, symbol: \"k\"), b: (kind: Number, number: 7.0))", "$ of pair"

  test "stringify":
    check stringify(number(42)) == "42", "stringify whole float without decimals"
    check stringify(number(2.5)) == "2.5", "stringify float"
    check stringify(number(-3)) == "-3", "stringify negative"
    check stringify(symbol("foo")) == "foo", "stringify symbol"
    check stringify(boolean(true)) == "true", "stringify true"
    check stringify(boolean(false)) == "false", "stringify false"
    check stringify(nothing()) == "()", "stringify nothing"
    check stringify(list(newSeq[Object]())) == "[]", "stringify empty list"
    check stringify(list(@[number(1), symbol("x"), list(@[number(2), number(3)])])) ==
      "[] 1 x ([] 2 3)", "stringify nested list"
    check stringify(pair(symbol("k"), number(7))) == "(k = 7)", "stringify pair"
    check stringify(pair(symbol("k"), list(@[number(1), number(2)]))) == "(k = [] 1 2)", "pair with list value"
    check stringify(pair(symbol("k"), pair(symbol("j"), number(1)))) == "(k = (j = 1))", "nested pair"

  test "records":
    let rec = record(@[pair(symbol("x"), number(100)), pair(symbol("y"), number(200))])
    check isRecord(rec), "record predicate"
    check not isRecord(list(@[number(1), number(2)])), "lists are not records"
    check recordFields(rec).len == 2, "record fields"
    check fieldNames(rec) == @["x", "y"], "field names in order"
    check toNumber(field(rec, "y")) == 200.0, "field value"
    check field(rec, "z") == nothing(), "missing field is nothing"
    check hasField(rec, "x"), "hasField finds a field"
    check not hasField(rec, "z"), "hasField misses"
    check rec == record(@[pair(symbol("x"), number(100)), pair(symbol("y"), number(200))]),
      "records compare by structure"
    check rec != record(@[pair(symbol("x"), number(100))]), "records differ by field count"
    check hash(rec) == hash(record(@[pair(symbol("x"), number(100)), pair(symbol("y"), number(200))])),
      "equal records hash equal"
    check $record(newSeq[Object]()) == "(kind: Record, fields: @[])", "$ of empty record"
    check stringify(rec) == "{} (x = 100) (y = 200)", "stringify record as code"
    check stringify(record(newSeq[Object]())) == "{}", "stringify empty record"
    check stringify(record(@[pair(symbol("p"), record(@[pair(symbol("q"), number(7))]))])) ==
      "{} (p = {} (q = 7))", "stringify nested record"

  test "environment":
    let global = newEnvironment()
    let x = symbol("x")
    let y = symbol("y")
    define(global, x, number(1))
    check has(global, x), "binding exists"
    check not has(global, y), "unbound symbol"
    let got = lookup(global, x)
    check got.isSome and toNumber(got.get()) == 1.0, "lookup value"
    check lookup(global, y).isNone, "lookup miss"
    define(global, x, number(2))
    check toNumber(lookup(global, x).get()) == 2.0, "redefinition replaces"
    let inner = newEnvironment(global)
    check has(inner, x), "child inherits"
    define(inner, x, number(1))
    check toNumber(lookup(inner, x).get()) == 1.0, "child shadows"
    check toNumber(lookup(global, x).get()) == 2.0, "parent untouched"
    define(inner, y, number(3))
    check not has(global, y), "no leak upwards"
    let deep = newEnvironment(newEnvironment(inner))
    check toNumber(lookup(deep, x).get()) == 1.0, "deep chain finds innermost"
    check toNumber(lookup(deep, y).get()) == 3.0, "deep chain finds inherited"
    check lookup(deep, symbol("gone")).isNone, "deep miss"
