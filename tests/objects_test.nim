import std/[syncio, options]
import owl/objects

var failures = 0

proc expect(cond: bool, msg: string) =
  if not cond:
    failures += 1
    echo "FAILED: ", msg

# ----------------------------------------------------- objects: predicates and
# conversions (every object converts to every type; fallbacks are defined)

expect toNumber(number(2.5)) == 2.5 and toSymbol(number(2.5)) == "", "total conversions"
expect not toBool(nothing()), "nothing is falsy"

expect toNumber(number(2.5)) == 2.5, "number identity"
expect toNumber(boolean(true)) == 1.0, "true converts to 1"
expect toNumber(boolean(false)) == 0.0, "false converts to 0"
expect toNumber(symbol("x")) == 0.0, "symbol converts to 0"
expect toNumber(nothing()) == 0.0, "nothing converts to 0"

expect not toBool(nothing()), "nothing is falsy"
expect not toBool(boolean(false)), "false is falsy"
expect toBool(boolean(true)), "true is truthy"
expect toBool(number(0)), "only nothing and false are falsy"

expect toSymbol(symbol("hi")) == "hi", "symbol name"
expect toSymbol(number(1)) == "", "non-symbol has no name"

let xs = list(@[number(1), number(2)])
expect toSeq(xs).len == 2, "list converts to its elements"
expect toSeq(nothing()).len == 0, "non-list converts to empty"

let pr = pair(symbol("k"), number(7))
expect toSymbol(car(pr)) == "k", "car of pair"
expect toNumber(cdr(pr)) == 7.0, "cdr of pair"
expect car(number(1)) == nothing(), "car of non-pair is nothing"
expect pr == pair(symbol("k"), number(7)), "pairs compare by structure"
expect xs != list(@[number(1), number(2), number(3)]), "lists by length"

# ------------------------------------------------------------------ environment

let global = newEnvironment()
let x = symbol("x")
let y = symbol("y")

define(global, x, number(1))
expect has(global, x), "binding exists"
expect not has(global, y), "unbound symbol"
let got = lookup(global, x)
expect got.isSome and toNumber(got.get()) == 1.0, "lookup value"
expect lookup(global, y).isNone, "lookup miss"

define(global, x, number(2))
expect toNumber(lookup(global, x).get()) == 2.0, "redefinition replaces"

let inner = newEnvironment(global)
expect has(inner, x), "child inherits"
define(inner, x, number(1))
expect toNumber(lookup(inner, x).get()) == 1.0, "child shadows"
expect toNumber(lookup(global, x).get()) == 2.0, "parent untouched"
define(inner, y, number(3))
expect not has(global, y), "no leak upwards"

let deep = newEnvironment(newEnvironment(inner))
expect toNumber(lookup(deep, x).get()) == 1.0, "deep chain finds innermost"
expect toNumber(lookup(deep, y).get()) == 3.0, "deep chain finds inherited"
expect lookup(deep, symbol("gone")).isNone, "deep miss"

if failures == 0:
  echo "objects tests OK"
else:
  quit "objects tests failed: " & $failures
