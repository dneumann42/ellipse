## Tests for the vendored kiwiberry solver (Nimony port).
##
## Replaces upstream tests/tsolver.nim et al.; `doAssertRaises` does not exist
## in Nimony, so raises are checked via `except ErrorCode as e:` + the alias
## constants from the errors fragment.

import std/syncio

import kiwiberry

var failures = 0
var passed = 0

proc expect(cond: bool, msg: string) =
  if cond:
    passed += 1
  else:
    failures += 1
    echo "FAILED: ", msg

template expectRaises(code: ErrorCode, body: untyped) =
  block:
    var raised = true
    var got = Success
    try:
      body
      raised = false
    except ErrorCode as e:
      got = e
    expect raised and got == code, "expected " & $code & ", got " & $got

proc approx(a: KiwiScalar, b: float64): bool =
  abs(a.float64 - b) < 1.0e-6

proc runAll() {.raises.} =
  # --- README examples ---

  var solver = initSolver()
  let width = vars"width"

  solver[width] = Strong
  discard solver.constraint(width >= 100)
  solver.suggest(width, 240)
  solver.update()
  expect width.value.approx(240.0), "edit variable suggestion is honored"

  let x = vars"x"
  let y = vars"y"
  discard solver.constraint(x + y == 10)
  discard solver.constraint(x - y == 4)
  solver.update()
  expect x.value.approx(7.0), "system solves x == 7"
  expect y.value.approx(3.0), "system solves y == 3"

  solver.remove(width)
  expect not solver.has(width), "edit variable removed"

  # --- add / has / remove by shape and identity (one shape per solver so
  #     removal is unambiguous) ---

  var s7 = initSolver()
  let w7 = vars"w7"
  let c7 = s7.constraint(w7 >= 100)
  expect s7.has(c7), "identity lookup finds the stored constraint"
  expect s7.has(w7 >= 100), "structurally equal constraint is found"
  s7.remove(w7 >= 100)
  expect not s7.has(c7), "remove by shape removes the stored constraint"
  expect not s7.has(w7 >= 100), "shape is gone after removal"

  # --- duplicate / unknown constraint errors ---

  var s2 = initSolver()
  let v = vars"v"
  let cv = v >= 10
  discard s2.constraint(cv)
  expectRaises DuplicateConstraintError:
    discard s2.constraint(cv)
  expectRaises UnknownConstraintError:
    s2.remove(vars"unused" >= 999)

  # --- unsatisfiable required constraints ---

  var s3 = initSolver()
  let z = vars"z"
  discard s3.constraint(z >= 10)
  expectRaises UnsatisfiableConstraintError:
    discard s3.constraint(z <= 5)

  # --- edit variable rules ---

  var s4 = initSolver()
  let e = vars"e"
  s4.addEditVariable(e, Strong)
  expectRaises DuplicateEditVariableError:
    s4.addEditVariable(e, Strong)
  expectRaises BadRequiredStrengthError:
    s4.addEditVariable(vars"req", Required)
  expectRaises UnknownEditVariableError:
    s4.suggest(vars"none", 5)
  expectRaises UnknownEditVariableError:
    s4.remove(vars"other")

  # --- value validation ---

  var s5 = initSolver()
  let g = vars"g"
  s5.addEditVariable(g, Medium)
  let huge = 1.0 / 0.0
  expectRaises InvalidSolverValueError:
    s5.suggest(g, huge.KiwiScalar)
  expectRaises InvalidSolverValueError:
    g.value = huge.KiwiScalar

  # --- named constructors and soft strengths ---

  var s6 = initSolver()
  let a = vars"a"
  let b = vars"b"
  discard s6.constraint(le(a, b))
  discard s6.constraint(ge(b, 2))
  discard s6.constraint(eq(a, b - 2))
  discard s6.constraint(eq(b, 2))
  s6.update()
  expect a.value.approx(0.0), "le/ge/eq system solves a == 0"
  expect b.value.approx(2.0), "le/ge/eq system solves b == 2"

  let soft = s6.constraint((a >= 100).withStrength(Weak))
  expect s6.has(soft), "withStrength constraint added"
  let piped = (a >= 50) | Weak
  discard s6.constraint(piped)
  expect s6.has(piped), "piped `| Weak` constraint added"

  # --- ref-style solver ---

  let rs = newSolver()
  let r = vars"r"
  rs[r] = Strong
  discard rs.constraint(r >= 0)
  rs.suggest(r, 42)
  rs.update()
  expect r.value.approx(42.0), "ref-style solver solves"

  # --- variable identity ---

  let first = newVariable("x")
  let second = newVariable("x")
  let alias = first
  expect first.sameVariable(alias), "alias keeps identity"
  expect not first.sameVariable(second), "same name, different identity"

  # --- dump smoke test ---

  let text = solver.dumps()
  expect text.len > 0, "dumps produces output"

when isMainModule:
  try:
    runAll()
    if failures == 0:
      echo "kiwiberry tests OK (", passed, " assertions)"
    else:
      quit "kiwiberry tests failed: " & $failures & " of " & $(passed + failures)
  except ErrorCode as err:
    quit "kiwiberry tests aborted: " & $err
