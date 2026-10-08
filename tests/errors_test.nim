import std/[syncio, options, strutils]
import owl/[objects, reader, evaluator, modules, errors]
import owl/libraries/[base, math, list, io]
import ./testutils

# Reading, loading and running fail through one error report: an OwlError
# placed where the failing code was written, drawn as a window with the
# source lines and an arrow (errors.nim).

captureStdio()

proc newTestEnv(): ref Environment =
  result = newEnvironment()
  installBase(result)
  installMath(result)
  installList(result)
  installIo(result)

# Runs src as the file "t.owl" and gives whether it failed.
proc fails(src: string): bool =
  clearCaptured()
  result = false
  try:
    let forms = readSource(src, "t.owl")
    runProgram(newTestEnv(), forms)
  except:
    result = true

# line:col of the current error's place, or "" when it has none
proc whereText(): string =
  result = ""
  let src = currentError.place.src
  if src != nil:
    let (line, col) = lineCol(src.text, int(currentError.place.loc.at))
    result = $line & ":" & $col & "+" & $currentError.place.loc.len

proc expectAt(label, want: string) =
  expect whereText() == want, label & ": placed at " & want & ", got " & whereText() &
    "\n" & lastError()

# --- reader -------------------------------------------------------------------

expect fails("x = 1\ny = \"open\n"), "an unterminated string fails"
expect currentError.kind == ReadError, "it is a read error"
expect currentError.message == "unterminated string", "named: " & currentError.message
expectAt("the string's opening quote", "2:5+1")

expect fails("x = (+ 1\n  (* 2 3)\ny = 2\n"), "an open paren fails"
expectAt("the '(' left open", "1:5+1")

expect fails("fun f:\n    1\n        2\n"), "stray indentation fails"
expectAt("the indented line", "3:9+1")

expect fails("f (a: b)\n"), "a ':' inside parentheses fails"
expectAt("the ':'", "1:5+1")

# --- runtime ------------------------------------------------------------------

expect fails("fun f x:\n    (+ x nope)\nf 1\n"), "an unbound name fails"
expect currentError.kind == RuntimeError, "it is a runtime error"
expectAt("the name itself, inside the call", "2:10+4")
expect currentError.trace.len == 1 and currentError.trace[0].name == "f",
  "the trace names the fun it ran in: " & lastError()
expect placeText(currentError.trace[0].place) == "t.owl:3:1",
  "and where it was called: " & lastError()

expect fails("fun f x:\n    result = x\n    resul\nf 1\n"), "a misspelled last line fails"
expectAt("a body form that is a lone name", "3:5+5")

expect fails("x = (+ 1 \"two\")\n"), "a string in arithmetic fails"
expectAt("the argument that is wrong", "1:10+5")

expect fails("fun f a:\n    a\nf 1 2\n"), "too many arguments fail"
expectAt("the argument too many", "3:5+1")

expect fails("x = (nope 1 2)\n"), "an unbound command fails"
expectAt("the command's name", "1:6+4")

expect fails("x = 1\ny = (+ x (* 2 (- \"a\" 1)))\n"), "nested calls"
expectAt("the innermost failing argument", "2:18+3")

expect fails("fun deep:\n    error \"down here\"\nfun mid:\n    (deep)\nfun top:\n    (mid)\n(top)\n"),
  "an error from nested funs"
expectAt("the error call", "2:5+17")
expect currentError.trace.len == 3, "a frame per fun: " & lastError()
expect currentError.trace[0].name == "deep" and currentError.trace[2].name == "top",
  "innermost first: " & lastError()

# --- try and rethrow ----------------------------------------------------------

expect fails("fun risky:\n    nope\nfun safe:\n    try (risky):\n        error failure\n(safe)\n"),
  "error failure raises the caught error again"
expectAt("where it first happened", "2:5+4")

expect not fails("fun risky:\n    nope\nreport = try (risky):\n    (error-report)\n"),
  "error-report runs in a handler"

block:
  clearCaptured()
  var report = ""
  try:
    let env = newTestEnv()
    runProgram(env, readSource("fun risky:\n    nope\nreport = try (risky):\n    (error-report)\n", "t.owl"))
    report = toStr(lookup(env, symbol("report")).get())
  except:
    expect false, "error-report: " & lastError()
  expect "unbound symbol: nope" in report and "t.owl:2:5" in report and "^^^^" in report,
    "error-report gives the whole window:\n" & report

# --- commands report errors at their arguments --------------------------------

let twice = """
command twice name body:
    when (<> (type-of (syntax-form name)) "symbol"):
        error-at name "twice needs a name, not" (syntax-form name)
    eval body
    eval body
"""

expect not fails(twice & "twice x (+ 1 1)\n"), "a command used right runs"
expect fails(twice & "twice (+ 1 2) (+ 1 1)\n"), "error-at fails"
expect currentError.message == "twice needs a name, not + 1 2", "with its message: " & currentError.message
expectAt("the argument as the caller wrote it", "6:7+7")

expect fails(twice & "twice 5 (+ 1 1)\n"), "error-at at an atom argument"
expectAt("the atom argument", "6:7+1")

expect fails("command show-twice x:\n    eval x\n    eval x\nshow-twice nope\n"),
  "a command's argument that fails when evaluated"
expectAt("the argument, not the command's body", "4:12+4")

block:
  clearCaptured()
  var line = 0.0
  try:
    let env = newTestEnv()
    runProgram(env, readSource("command where x:\n    place-of x\n\np = where (+ 1 2)\n", "t.owl"))
    let p = lookup(env, symbol("p")).get()
    line = toNumber(field(p, "line"))
    expect toStr(field(p, "file")) == "t.owl" and toNumber(field(p, "column")) == 11.0,
      "place-of gives file and column: " & stringify(p)
  except:
    expect false, "place-of: " & lastError()
  expect line == 4.0, "place-of gives the line"

# --- compile time (modules) ---------------------------------------------------

block:
  clearCaptured()
  var failed = false
  try:
    let lib = newLibrary("t")
    add(lib, baseModule())
    discard runProgram(lib, readSource("use base\nuse nosuch\nx = 1\n", "prog.owl"))
  except:
    failed = true
  expect failed, "an unknown module fails"
  expect currentError.kind == CompileError, "as a compile error"
  expectAt("the module's name in the use", "2:5+6")

block:
  clearCaptured()
  var failed = false
  try:
    let lib = newLibrary("t")
    add(lib, baseModule())
    add(lib, newModule("m").addSource("use base\nfun f:\n    1\nexport:\n    g = nope\n"))
    discard runProgram(lib, readSource("use m\n", "prog.owl"))
  except:
    failed = true
  expect failed, "exporting an unbound name fails"
  expect currentError.kind == CompileError, "as a compile error"
  expect placeText(currentError.place) == "<m>:5:9", "at the name: " & lastError()

# --- the window ---------------------------------------------------------------

block:
  discard fails("fun f x:\n    (+ x nope)\nf 1\n")
  let text = errorText()
  let lines = text.split('\n')
  expect lines[0] == "╭─ error: unbound symbol: nope", "the title line: " & lines[0]
  expect "at t.owl:2:10" in text, "the place: " & text
  expect "2 │     (+ x nope)" in text, "the source line: " & text
  var arrow = ""
  for l in lines:
    if "^" in l:
      arrow = l
  expect arrow.endsWith("│          ^^^^"), "the arrow under the name: [" & arrow & "]"
  expect "in f, called at t.owl:3:1" in text, "the trace: " & text
  expect lines[^1] == "╰─", "the closing line: " & lines[^1]
  expect "\e[" notin text, "no colors unless asked"
  expect "\e[" in errorText(true), "colors when asked"

block:
  # an error without a place still gets a window
  clearCaptured()
  try:
    err("plain")
  except:
    discard
  expect errorText() == "╭─ error: plain\n╰─", "a placeless error: " & errorText()

block:
  # reportError hands the window to errorReport; raising alone prints nothing
  clearCaptured()
  discard fails("x = nope\n")
  expect errorLines.len == 0, "raising reports nothing"
  reportError()
  expect errorLines.len == 1 and "unbound symbol: nope" in errorLines[0], "reportError reports it"

finish("errors")
