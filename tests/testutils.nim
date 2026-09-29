import std/[syncio, strutils]
import owl/[evaluator]
import owl/libraries/[io]

var failures = 0
var passed = 0

proc expect*(cond: bool, msg: string) =
  if cond:
    passed += 1
  else:
    failures += 1
    echo "FAILED: ", msg

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

proc lastError*(): string =
  result = if errorLines.len > 0: errorLines[^1] else: "(no error reported)"

proc check*(label: string, body: proc () {.raises.}) =
  let before = errorLines.len
  try:
    body()
  except:
    var reason = ""
    if errorLines.len > before:
      reason = ": " & lastError()
    expect false, label & " raised unexpectedly" & reason

proc finish*(name: string) =
  if failures == 0:
    echo name & " tests OK (" & $passed & " assertions)"
  else:
    quit name & " tests failed: " & $failures & " of " & $(passed + failures)
