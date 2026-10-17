## Tests for `ellipse_ui/dialogs`, through the real app shell, headless
## (`SDL_VIDEODRIVER=offscreen`):
##
##   - inline dialogs: open, the body's first frame, Enter / Escape through
##     the dialog keymap, the result reaching `onDone`, stacking
##   - the quick popups: confirm, ask, prompt (typed text comes back)
##   - window mode: this very executable is started again as a dialog
##     process (`--ellipse-dialog=...`), which answers at once through the
##     `ELLIPSE_DIALOG_AUTOCLOSE` hook; the result crosses the pipe as
##     `Fields` wire form and reaches `onDone` in this process.

import std/[syncio, envvars]

import ellipse_ui/app

var failures = 0
var passed = 0

proc expect(cond: bool, msg: string) =
  if cond:
    passed += 1
  else:
    failures += 1
    echo "FAILED: ", msg

proc SDL_Delay(ms: uint32) {.importc: "SDL_Delay", header: "<SDL3/SDL.h>".}

var
  bodyFrames = 0
  openedSeen = 0
  enterSeen = 0
  lastResult = DialogResult(status: dsOpen)
  results = 0
  draft = ""

dialog echoDialog("test.echo", title = "Echo"):
  inc bodyFrames
  if dialogOpened():
    inc openedSeen
    draft = dialogArgs().get("seed")
  if dialogEnter():
    inc enterSeen
    var r = Fields()
    r.put("draft", draft & "!")
    accept(r, "enter")
  text("echo " & draft)

type
  Rec = object
    title: string
    count: int
    on: bool

var
  formDraft = Rec(count: 1)
  formSeeded = 0
  formIdBad = 0

proc formErr(): string =
  if formDraft.title.len == 0: "A title is required." else: ""

formDialog theForm("test.form", title = "Form", answer = "add",
                   draft = formDraft):
  if dialogOpened():
    inc formSeeded
    if fieldId("title") != elementId("test.form.title"):
      inc formIdBad
    focusField("title", draft.title)
  draft.title = textField(fieldId("title"), draft.title, "title")
  draft.count = intNumberField(fieldId("count"), draft.count, 1, 0, 99)
  draft.on = checkbox(fieldId("on"), "On", draft.on)
  fieldError(formErr())
  footer:
    if formButton("Cancel"): cancel()
  validate:
    formErr()

proc record(r: DialogResult) =
  lastResult = r
  inc results

proc prepare()  =
  ## Runs in the dialog process too: the dialogs above are defined at
  ## module level, so nothing to do but prove the hook runs.
  discard

proc frames(n: int)  =
  var i = 0
  while i < n:
    frame()
    inc i

proc key(kind: KeyEventKind)  =
  pushKeyEvent KeyEvent(kind: kind)
  frame()

proc typeText(s: string)  =
  pushKeyEvent KeyEvent(kind: kevText, text: s)
  frame()

proc script()  =
  frames(2)

  # --- inline: open, Enter accepts with the body's own result -------------
  echoDialog.open(fields({"seed": "hi"}),
                  onDone = proc (r: DialogResult) {.closure.} = record(r))
  expect(anyDialogOpen(), "inline dialog is open")
  frames(2)
  expect(openedSeen == 1, "dialogOpened true exactly once")
  expect(bodyFrames >= 2, "body runs every frame")
  key(kevEnter)
  frame()
  expect(enterSeen == 1, "Enter reached the body")
  expect(results == 1 and lastResult.status == dsAccepted, "accepted")
  expect(lastResult.answer == "enter", "answer carried")
  expect(lastResult.fields.get("draft") == "hi!", "result fields carried")
  expect(not anyDialogOpen(), "closed after accept")

  # --- inline: Escape cancels ----------------------------------------------
  results = 0
  echoDialog.open(onDone = proc (r: DialogResult) {.closure.} = record(r))
  let h = lastOpened()
  frame()
  expect(dialogIsOpen(h), "handle reports open")
  key(kevEscape)
  frame()
  expect(results == 1 and lastResult.status == dsCancelled, "Escape cancels")
  expect(not dialogIsOpen(h), "handle reports closed")

  # --- stacking: the top dialog takes the keys -------------------------------
  results = 0
  var outer = 0
  var inner = 0
  echoDialog.open(onDone = proc (r: DialogResult) {.closure.} = inc outer)
  frame()
  alert("on top", onDone = proc (r: DialogResult) {.closure.} = inc inner)
  frame()
  key(kevEscape)
  frame()
  expect(inner == 1 and outer == 0, "Escape closes only the top dialog")
  key(kevEscape)
  frame()
  expect(outer == 1, "then the one below")

  # --- quick popups ------------------------------------------------------------
  var yes = -1
  confirm("Proceed?", proc (b: bool) {.closure.} =
    yes = (if b: 1 else: 0))
  frame()
  key(kevEnter)
  frame()
  expect(yes == 1, "confirm: Enter answers yes")
  confirm("Proceed?", proc (b: bool) {.closure.} =
    yes = (if b: 1 else: 0))
  frame()
  key(kevEscape)
  frame()
  expect(yes == 0, "confirm: Escape answers no")

  var picked = -2
  ask("Save changes?", ["Save", "Discard", "Cancel"],
      proc (i: int) {.closure.} = picked = i, default = 0, cancelIndex = 2)
  frame()
  key(kevEnter)
  frame()
  expect(picked == 0, "ask: Enter picks the default")

  var got = "<none>"
  prompt("Name?", proc (s: string) {.closure.} = got = s, text = "Ad")
  frames(2)
  typeText("a")
  key(kevEnter)
  frame()
  expect(got == "Ada", "prompt: typed text comes back (got " & got & ")")
  got = "<none>"
  prompt("Name?", proc (s: string) {.closure.} = got = s)
  frames(2)
  key(kevEscape)
  frame()
  expect(got == "<none>", "prompt: Escape never calls back")

  toast("hello")
  frame()
  expect(not anyDialogOpen(), "a toast is not modal")

  # --- forms ---------------------------------------------------------------------
  let bag = fieldsOf(Rec(title: "t", count: 3, on: true))
  expect(bag.get("title") == "t" and bag.getInt("count") == 3 and
         bag.getBool("on"), "fieldsOf stores every field")
  var keep = Rec(count: 9)
  keep.fillFrom(decode("title=x"))
  expect(keep.title == "x" and keep.count == 9,
         "fillFrom keeps defaults for keys the bag lacks")

  results = 0
  lastResult = DialogResult(status: dsOpen)
  formSeeded = 0
  formIdBad = 0
  theForm.open(args = formArgs(Rec(count: 5, on: true)),
                  onDone = proc (r: DialogResult) {.closure.} = record(r))
  frames(2)
  expect(formSeeded == 1 and formIdBad == 0,
         "beginForm seeds once, fieldId namespaces by dialog")
  expect(formDraft.count == 5 and formDraft.on, "the opener's record arrived")
  key(kevEnter)                       # no title: formSubmit only marks the attempt
  frame()
  expect(results == 0 and formTried, "an invalid Enter stays open, errors shown")
  typeText("Hi")
  key(kevEnter)
  frame()
  expect(results == 1 and lastResult.status == dsAccepted,
         "the Enter after a fix accepts")
  expect(lastResult.answer == "add" and
         lastResult.fields.get("title") == "Hi" and
         lastResult.fields.getInt("count") == 5 and
         lastResult.fields.getBool("on"),
         "the draft came back as a record")

  # --- window mode: a real child process --------------------------------------
  results = 0
  lastResult = DialogResult(status: dsOpen)
  var args = Fields()
  args.put("seed", "from parent")
  args.put("odd", "a&b=c %\n done")
  echoDialog.open(args, mode = dmWindow,
    onDone = proc (r: DialogResult) {.closure.} = record(r))
  let wh = lastOpened()
  expect(dialogIsOpen(wh), "window dialog pending")
  expect(anyDialogOpen(), "a modal window dialog counts as open")
  var waited = 0
  while results == 0 and waited < 400:
    frame()
    SDL_Delay(25)
    inc waited
  expect(results == 1, "window dialog delivered a result")
  expect(lastResult.status == dsAccepted, "window dialog accepted")
  expect(lastResult.answer == "auto", "window dialog answer crossed the pipe")
  expect(lastResult.fields.get("seed") == "from parent" and
         lastResult.fields.get("odd") == "a&b=c %\n done",
         "args went out and came back intact")
  expect(not dialogIsOpen(wh), "window dialog no longer pending")

  # an undefined dialog fails cleanly, inline or not
  results = 0
  openDialog("test.nope", mode = dmWindow,
             onDone = proc (r: DialogResult) {.closure.} = record(r))
  expect(results == 1 and lastResult.status == dsFailed, "undefined dialog fails")

  echo "dialogs_test: ", passed, " passed, ", failures, " failed"
  if failures > 0:
    quit 1

when isMainModule:
  # before SDL starts: SDL hands child processes its own snapshot of the
  # environment, taken at init
  try:
    if getEnv("SDL_VIDEODRIVER").len == 0:
      putEnv("SDL_VIDEODRIVER", "offscreen")
    putEnv("ELLIPSE_DIALOG_AUTOCLOSE", "auto")
  except:
    discard
  run(App(window: WindowConfig(title: "dialogs test", width: 800, height: 600),
          log: false, debugMode: false, prepare: prepare), script = script)
