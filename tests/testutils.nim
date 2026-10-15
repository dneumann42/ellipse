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

template check*(cond: bool, msg: string) =
  if not cond:
    checkpoint(msg)
    fail()
