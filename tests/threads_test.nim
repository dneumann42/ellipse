## Owl on many threads at once: every thread runs its own interpreter, and
## values cross between threads only as isolated copies.

import std/[unittest, typedthreads, atomics, isolation, options, strutils, locks]
import owl/[objects, reader, evaluator, modules, library, errors]
import owl/libraries/[base, math, list, io, gui]

const
  Workers = 8
  Rounds = 50

var failures: Atomic[int]
  ## Checks that failed on a worker thread (unittest's `check` is not for
  ## threads).

proc expectOn(cond: bool, what: string) =
  if not cond:
    failures.atomicInc
    writeLine(stderr, "worker check failed: " & what)

proc newEnv(): ref Environment =
  result = newEnvironment()
  installBase(result)
  installMath(result)
  installList(result)
  installIo(result)

proc run(env: ref Environment, source: string): Object =
  let parsed = readForms(source, "worker.owl")
  doAssert parsed.isOk
  result = evalForms(env, parsed.get(@[]))

proc lookupOr(env: ref Environment, name: string): Object =
  lookup(env, symbol(name)).get(nothing())

const Program = """
fun fib n:
  if (< n 2):
    n
    + (fib (- n 1)) (fib (- n 2))
answer = fib 15
fun say:
  echo "worker" me answer
shown = capture-output say
handled = try (error (concat "boom " (to-string me))):
  failure
"""

proc worker(id: int) {.thread.} =
  # Its own reporter and writer: neither may see another thread's text.
  var reported {.global, threadvar.}: seq[string]
  errorReport = proc (msg: string) {.gcsafe.} = reported.add msg
  for round in 0 ..< Rounds:
    let env = newEnv()
    define(env, symbol("me"), number(float64(id)))
    discard run(env, Program)
    expectOn(toNumber(lookupOr(env, "answer")) == 610.0, "fib on " & $id)
    expectOn(toStr(lookupOr(env, "shown")) == "worker " & $id & " 610\n",
      "captured output on " & $id & ": " & toStr(lookupOr(env, "shown")))
    expectOn(toStr(lookupOr(env, "handled")) == "boom " & $id,
      "try on " & $id & ": " & toStr(lookupOr(env, "handled")))
    expectOn(captures.len == 0, "capture stack unwound on " & $id)
    # An uncaught error leaves this thread's error state alone to report.
    try:
      discard run(env, "error (concat \"thread \" (to-string me))")
      expectOn(false, "the error escapes on " & $id)
    except OwlFailure:
      expectOn(currentError.message == "thread " & $id,
        "own error on " & $id & ": " & currentError.message)
      reportError()
  expectOn(reported.len == Rounds, "reports on " & $id)
  for r in reported:
    expectOn("thread " & $id in r, "report text on " & $id)

proc libraryWorker(id: int) {.thread.} =
  # A whole owl library -- modules, embedded owl sources, the loader -- per
  # thread.
  outputWriter = proc (s: string) {.gcsafe.} = discard
  for round in 0 ..< 5:
    let lib = owlLibrary()
    let forms = readSource("use strings\nme = " & $id & "\n", "lib.owl")
    let env = runProgram(lib, forms)
    expectOn(toNumber(lookupOr(env, "me")) == float64(id), "library program on " & $id)

type
  Slot = object
    ## A one-value handoff between two threads: the least a channel does.
    lock: Lock
    filled: Cond
    emptied: Cond
    full: bool
    value: Isolated[Object]

proc initSlot(s: var Slot) =
  initLock(s.lock)
  initCond(s.filled)
  initCond(s.emptied)

proc put(s: var Slot, v: sink Isolated[Object]) =
  withLock s.lock:
    while s.full:
      wait(s.emptied, s.lock)
    s.value = v
    s.full = true
    signal(s.filled)

proc take(s: var Slot): Isolated[Object] =
  withLock s.lock:
    while not s.full:
      wait(s.filled, s.lock)
    result = move s.value
    s.full = false
    signal(s.emptied)

type Mail = object
  inbox, outbox: Slot

proc echoWorker(mail: ptr Mail) {.thread.} =
  # Takes values, works on them with its own interpreter, sends a value back.
  while true:
    var msg = mail.inbox.take()
    let value = extract(msg)
    if isNothing(value):
      break
    let env = newEnv()
    define(env, symbol("input"), value)
    let reply = run(env, "concat input.name \" is \" (to-string (+ input.age 1))")
    mail.outbox.put isolateValue(reply)

proc guiWorker(claimed: ptr Atomic[bool]) {.thread.} =
  # Takes the gui for this thread.
  let env = newEnv()
  installGui(env)
  discard run(env, "(grow)")
  claimed[].store true

suite "owl/threads":
  test "an interpreter on every thread":
    failures.store 0
    var threads: array[Workers, Thread[int]]
    for i in 0 ..< Workers:
      createThread(threads[i], worker, i + 1)
    joinThreads(threads)
    check failures.load == 0

  test "a library on every thread":
    failures.store 0
    var threads: array[Workers, Thread[int]]
    for i in 0 ..< Workers:
      createThread(threads[i], libraryWorker, i + 1)
    joinThreads(threads)
    check failures.load == 0

  test "values cross threads as isolated copies":
    let mail = createShared(Mail)
    initSlot(mail.inbox)
    initSlot(mail.outbox)
    var t: Thread[ptr Mail]
    createThread(t, echoWorker, mail)
    let env = newEnv()
    for age in [44, 45, 46]:
      let joe = run(env, "{}:\n  name = \"Joe\"\n  age = " & $age)
      mail.inbox.put isolateValue(joe)
      var back = mail.outbox.take()
      check toStr(extract(back)) == "Joe is " & $(age + 1)
    mail.inbox.put isolateValue(nothing())
    joinThread(t)
    freeShared(mail)

  test "only data crosses":
    let env = newEnv()
    let parsed = readForms("x = [] 1 \"two\" ([] 3 4)\nr = {}:\n  name = \"Joe\"\n  tags = x\n" &
      "fun f:\n  1\n", "data.owl")
    check parsed.isOk
    let forms = parsed.get(@[])
    runProgram(env, forms)
    for name in ["x", "r"]:
      let x = lookupOr(env, name)
      check isData(x)
      var copy = isolateValue(x)
      let y = extract(copy)
      check y == x
      check not sameValue(y, x)
    # A form keeps its place in its source, copied once.
    var code = isolateValue(forms[0])
    let moved = extract(code)
    check placeOf(moved).isKnown
    check placeOf(moved).src != placeOf(forms[0]).src
    check placeText(placeOf(moved)) == placeText(placeOf(forms[0]))
    let f = lookupOr(env, "f")
    check not isData(f)
    expect ValueError:
      discard isolateValue(f)
    expect ValueError:
      discard isolateValue(list(@[number(1), f]))

  test "the gui stays on the thread that took it":
    var claimed: Atomic[bool]
    var t: Thread[ptr Atomic[bool]]
    createThread(t, guiWorker, addr claimed)
    joinThread(t)
    check claimed.load
    let env = newEnv()
    installGui(env)
    expect OwlFailure:
      discard run(env, "(grow)")
    check "the gui belongs to thread" in currentError.message
