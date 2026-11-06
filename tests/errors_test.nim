import std/[syncio, options, strutils, unittest]
import owl/[objects, reader, evaluator, modules, errors]
import owl/libraries/[base, math, list, io]
import ./testutils

captureStdio()

proc newTestEnv(): ref Environment =
  result = newEnvironment()
  installBase(result)
  installMath(result)
  installList(result)
  installIo(result)

proc fails(src: string): bool =
  clearCaptured()
  result = false
  try:
    let forms = readSource(src, "t.owl")
    runProgram(newTestEnv(), forms)
  except:
    result = true

proc whereText(): string =
  result = ""
  let src = currentError.place.src
  if src != nil:
    let (line, col) = lineCol(src.text, int(currentError.place.loc.at))
    result = $line & ":" & $col & "+" & $currentError.place.loc.len

template expectAt(label, want: string) =
  check whereText() == want, label & ": placed at " & want & ", got " & whereText() &
    "\n" & lastError()

let twice = """
command twice name body:
    when (<> (type-of (syntax-form name)) "symbol"):
        error-at name "twice needs a name, not" (syntax-form name)
    eval body
    eval body
"""

suite "owl/errors":
  test "an error inside an interpolation points into the string":
    var text = ""
    try:
      let env = newTestEnv()
      runProgram(env, readSource("x = 1\necho \"value: \\(nope)\"\n", "t.owl"))
    except:
      text = lastError()
    check "unbound symbol: nope" in text and "t.owl:2:16" in text, "the place: " & text

  test "reader errors place the window":
    check fails("x = 1\ny = \"open\n"), "an unterminated string fails"
    check currentError.kind == ReadError, "it is a read error"
    check currentError.message == "unterminated string", "named: " & currentError.message
    expectAt("the string's opening quote", "2:5+1")
    check fails("x = (+ 1\n  (* 2 3)\ny = 2\n"), "an open paren fails"
    expectAt("the '(' left open", "1:5+1")
    check fails("fun f:\n    1\n        2\n"), "stray indentation fails"
    expectAt("the indented line", "3:9+1")
    check fails("f (a: b)\n"), "a ':' inside parentheses fails"
    expectAt("the ':'", "1:5+1")

  test "runtime errors place the window":
    check fails("fun f x:\n    (+ x nope)\nf 1\n"), "an unbound name fails"
    check currentError.kind == RuntimeError, "it is a runtime error"
    expectAt("the name itself, inside the call", "2:10+4")
    check currentError.trace.len == 1 and currentError.trace[0].name == "f",
      "the trace names the fun it ran in: " & lastError()
    check placeText(currentError.trace[0].place) == "t.owl:3:1",
      "and where it was called: " & lastError()
    check fails("fun f x:\n    result = x\n    resul\nf 1\n"), "a misspelled last line fails"
    expectAt("a body form that is a lone name", "3:5+5")
    check fails("x = (+ 1 \"two\")\n"), "a string in arithmetic fails"
    expectAt("the argument that is wrong", "1:10+5")
    check fails("fun f a:\n    a\nf 1 2\n"), "too many arguments fail"
    expectAt("the argument too many", "3:5+1")
    check fails("x = (nope 1 2)\n"), "an unbound command fails"
    expectAt("the command's name", "1:6+4")
    check fails("x = 1\ny = (+ x (* 2 (- \"a\" 1)))\n"), "nested calls"
    expectAt("the innermost failing argument", "2:18+3")
    check fails("fun deep:\n    error \"down here\"\nfun mid:\n    (deep)\nfun top:\n    (mid)\n(top)\n"),
      "an error from nested funs"
    expectAt("the error call", "2:5+17")
    check currentError.trace.len == 3, "a frame per fun: " & lastError()
    check currentError.trace[0].name == "deep" and currentError.trace[2].name == "top",
      "innermost first: " & lastError()

  test "try and rethrow":
    check fails("fun risky:\n    nope\nfun safe:\n    try (risky):\n        error failure\n(safe)\n"),
      "error failure raises the caught error again"
    expectAt("where it first happened", "2:5+4")
    check not fails("fun risky:\n    nope\nreport = try (risky):\n    (error-report)\n"),
      "error-report runs in a handler"
    clearCaptured()
    var report = ""
    try:
      let env = newTestEnv()
      runProgram(env, readSource("fun risky:\n    nope\nreport = try (risky):\n    (error-report)\n", "t.owl"))
      report = toStr(lookup(env, symbol("report")).get())
    except:
      check false, "error-report: " & lastError()
    check "unbound symbol: nope" in report and "t.owl:2:5" in report and "^^^^" in report,
      "error-report gives the whole window:\n" & report

  test "commands report errors at their arguments":
    check not fails(twice & "twice x (+ 1 1)\n"), "a command used right runs"
    check fails(twice & "twice (+ 1 2) (+ 1 1)\n"), "error-at fails"
    check currentError.message == "twice needs a name, not + 1 2", "with its message: " & currentError.message
    expectAt("the argument as the caller wrote it", "6:7+7")
    check fails(twice & "twice 5 (+ 1 1)\n"), "error-at at an atom argument"
    expectAt("the atom argument", "6:7+1")
    check fails("command show-twice x:\n    eval x\n    eval x\nshow-twice nope\n"),
      "a command's argument that fails when evaluated"
    expectAt("the argument, not the command's body", "4:12+4")
    clearCaptured()
    var line = 0.0
    try:
      let env = newTestEnv()
      runProgram(env, readSource("command where x:\n    place-of x\n\np = where (+ 1 2)\n", "t.owl"))
      let p = lookup(env, symbol("p")).get()
      line = toNumber(field(p, "line"))
      check toStr(field(p, "file")) == "t.owl" and toNumber(field(p, "column")) == 11.0,
        "place-of gives file and column: " & stringify(p)
    except:
      check false, "place-of: " & lastError()
    check line == 4.0, "place-of gives the line"

  test "compile errors":
    clearCaptured()
    var failed = false
    try:
      let lib = newLibrary("t")
      add(lib, baseModule())
      discard runProgram(lib, readSource("use base\nuse nosuch\nx = 1\n", "prog.owl"))
    except:
      failed = true
    check failed, "an unknown module fails"
    check currentError.kind == CompileError, "as a compile error"
    expectAt("the module's name in the use", "2:5+6")
    clearCaptured()
    var failed2 = false
    try:
      let lib = newLibrary("t")
      add(lib, baseModule())
      add(lib, newModule("m").addSource("use base\nfun f:\n    1\nexport:\n    g = nope\n"))
      discard runProgram(lib, readSource("use m\n", "prog.owl"))
    except:
      failed2 = true
    check failed2, "exporting an unbound name fails"
    check currentError.kind == CompileError, "as a compile error"
    check placeText(currentError.place) == "<m>:5:9", "at the name: " & lastError()

  test "the error window":
    discard fails("fun f x:\n    (+ x nope)\nf 1\n")
    let text = errorText()
    let lines = text.split('\n')
    check lines[0] == "╭─ error: unbound symbol: nope", "the title line: " & lines[0]
    check "at t.owl:2:10" in text, "the place: " & text
    check "2 │     (+ x nope)" in text, "the source line: " & text
    var arrow = ""
    for l in lines:
      if "^" in l:
        arrow = l
    check arrow.endsWith("│          ^^^^"), "the arrow under the name: [" & arrow & "]"
    check "in f, called at t.owl:3:1" in text, "the trace: " & text
    check lines[^1] == "╰─", "the closing line: " & lines[^1]
    check "\e[" notin text, "no colors unless asked"
    check "\e[" in errorText(true), "colors when asked"
    clearCaptured()
    try:
      err("plain")
    except:
      discard
    check errorText() == "╭─ error: plain\n╰─", "a placeless error: " & errorText()
    clearCaptured()
    discard fails("x = nope\n")
    check errorLines.len == 0, "raising reports nothing"
    reportError()
    check errorLines.len == 1 and "unbound symbol: nope" in errorLines[0], "reportError reports it"
