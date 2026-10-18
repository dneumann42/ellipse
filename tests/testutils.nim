import std/unittest
import owl/[evaluator, errors]
import owl/libraries/[io]

var outputLines*: seq[string]
var errorLines*: seq[string]

proc collectOutput(s: string) =
  outputLines.add s

proc collectError(msg: string) =
  errorLines.add msg

proc captureStdio*() =
  io.outputWriter = collectOutput
  evaluator.errorReport = collectError

proc clearCaptured*() =
  outputLines = @[]
  errorLines = @[]
  currentError.message = ""

proc lastError*(): string =
  result = if currentError.message.len > 0: errorText() else: "(no error reported)"

var expectPassed* = 0
var expectFailed* = 0

proc expect*(cond: bool, msg: string) =
  ## Assertion counting for the app-driven tests (the GUI tests steer the
  ## frame loop themselves, outside the `unittest` suites).
  if cond:
    expectPassed += 1
  else:
    expectFailed += 1
    echo "FAILED: ", msg

proc finish*(name: string) =
  let total = expectPassed + expectFailed
  if expectFailed == 0:
    echo name, " tests OK (", expectPassed, " assertions)"
  else:
    quit name & " tests failed: " & $expectFailed & " of " & $total

template check*(cond: bool, msg: string) =
  if not cond:
    checkpoint(msg)
    fail()
