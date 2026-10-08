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
  currentError.message = ""

# The latest error: errors are not printed when raised (the handler that
# ends one reports it), so this is the error window of the last one raised.
proc lastError*(): string =
  result = if currentError.message.len > 0: errorText() else: "(no error reported)"

proc check*(label: string, body: proc () {.raises.}) =
  try:
    body()
  except:
    expect false, label & " raised unexpectedly: " & lastError()

proc finish*(name: string) =
  if failures == 0:
    echo name & " tests OK (" & $passed & " assertions)"
  else:
    quit name & " tests failed: " & $failures & " of " & $(passed + failures)
