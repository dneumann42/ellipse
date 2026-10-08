## The repl app in a window (SDL, offscreen): typing and running code, the
## item view with its cursor and edit, F2 results, the F1 menu into the
## settings form, Escape out of a screen, the document panel, and Ctrl+D
## with an unsaved document asking first. The terminal face is tests/repl_screens_test.py.
## Screenshots of each screen land in nimcache/repl_gui_*.bmp.

import std/[syncio, envvars, options, strutils, os]

# The session starts in the current directory (the repo root, no project:
# nothing it does here touches a file).
import owl/[objects, reader, evaluator, library]
from owl/modules import Library, evaluate, runProgram
import owl/libraries/gui
import ellipse_ui/app
import ./testutils

captureStdio()

var lib: Library
var env: ref Environment

proc forms(src: string): seq[Object] =
  let r = parseOwl(src)
  expect r.isOk, "parse ok"
  result = r.get(@[])

proc evalText(src: string): Object =
  result = nothing()
  try:
    result = evalForms(env, forms(src))
  except:
    expect false, "should run: " & lastError() & "\n" & src

proc appVar(name: string): Object =
  evalText("eval-in (module-scope \"repl-app\") (quote " & name & ")")

proc transcriptText(): string {.raises.} =
  result = ""
  # every entry's text, one per line
  for e in toSeq(evalText("(repl-transcript)")):
    result.add toStr(field(e, "text"))
    result.add "\n"

proc screenTitle(): string {.raises.} =
  let s = evalText("(repl-screen)")
  if isNothing(s): "" else: toStr(field(s, "title"))

proc frames(n = 3) {.raises.} =
  for i in 0 ..< n:
    frame()

proc key(ev: KeyEvent) {.raises.} =
  pushKeyEvent(ev)
  frames()

proc typeText(s: string) {.raises.} =
  pushKeyEvent(KeyEvent(kind: kevText, text: s))
  frames()

proc run(code: string) {.raises.} =
  typeText(code)
  key(KeyEvent(kind: kevEnter, ctrl: true))

proc clickAt(label: string) {.raises.} =
  let d = elementData(elementId(label))
  expect d.found, label & " was laid out"
  let x = d.box.x + d.box.width / 2
  let y = d.box.y + d.box.height / 2
  setPointer(x, y, false)
  frame()
  setPointer(x, y, true)
  frame()
  setPointer(x, y, false)
  frames()

let root = parentDir(parentDir(getAppFilename()))  # bin/ is in the repo root

proc shot(name: string) {.raises.} =
  discard saveScreenshot(root & "/nimcache/repl_gui_" & name & ".bmp")

proc script() {.raises.} =
  frames()
  run("(+ 40 2)")
  expect "42" in transcriptText(), "code runs and its value is shown:\n" & transcriptText()
  # Enter adds a line, one deeper after a colon; Ctrl+Enter runs it all
  typeText("fun double x:")
  key(KeyEvent(kind: kevEnter))
  expect toStr(appVar("draft")) == "fun double x:\n    ", "Enter indents after ':': " &
    stringify(appVar("draft"))
  run("* x 2")
  expect "defined double in scratch" in transcriptText(), "a definition is recorded:\n" & transcriptText()
  shot("transcript")

  run("items")
  expect screenTitle() == "scratch · 6 items", "items opens the item view: " & screenTitle()
  key(KeyEvent(kind: kevDown))
  key(KeyEvent(kind: kevDown))
  expect toNumber(appVar("selected")) == 2.0, "the cursor moves down the items"
  shot("items")
  key(KeyEvent(kind: kevText, text: "e"))
  expect screenTitle() == "", "e closes the view"
  expect toStr(appVar("draft")) == "use math", "e puts the item into the prompt: " &
    stringify(appVar("draft"))
  expect "editing in scratch" in transcriptText(), "and says so"
  # clear the prompt (select all, delete)
  key(KeyEvent(kind: kevLetter, ch: 'a', ctrl: true))
  key(KeyEvent(kind: kevBackspace))
  expect toStr(appVar("draft")) == "", "the prompt is cleared: " & stringify(appVar("draft"))

  key(KeyEvent(kind: kevF2))
  expect screenTitle() == "results · 1", "F2 shows the results: " & screenTitle()
  shot("results")
  key(KeyEvent(kind: kevEscape))
  expect screenTitle() == "", "Escape closes it"

  key(KeyEvent(kind: kevF1))
  expect screenTitle() == "Commands · scratch", "F1 opens the menu: " & screenTitle()
  typeText("sett")
  shot("menu")
  key(KeyEvent(kind: kevEnter))
  expect screenTitle() == "Settings", "choosing settings opens the form: " & screenTitle()
  shot("settings")
  key(KeyEvent(kind: kevEscape))
  expect screenTitle() == "", "Escape cancels the form"

  run("show")
  expect screenTitle() == "show: which item of scratch?", "show picks an item: " & screenTitle()
  typeText("double")
  key(KeyEvent(kind: kevEnter))
  expect "* x 2" in transcriptText(), "the picked item is shown"
  expect "show double" in transcriptText(), "with the command it stood for:\n" & transcriptText()

  # the menu bar, made from the commands: F10, Down opens File, Right steps
  # to Items, and picking show asks for its item
  key(KeyEvent(kind: kevF10))
  key(KeyEvent(kind: kevDown))
  shot("menubar")
  key(KeyEvent(kind: kevRight))
  key(KeyEvent(kind: kevDown))
  key(KeyEvent(kind: kevDown))
  key(KeyEvent(kind: kevEnter))
  expect screenTitle() == "show: which item of scratch?", "the menu bar runs show: " & screenTitle()
  key(KeyEvent(kind: kevEscape))
  # a click opens a menu, which stays open: the prompt must not take the
  # focus back in the frame of the click
  clickAt("menu.Project")
  expect toBool(appVar("(focused \"menu.Project\")")), "a clicked menu keeps the focus"
  shot("menu_clicked")
  key(KeyEvent(kind: kevEscape))
  expect toBool(appVar("(focused \"prompt\")")), "Escape gives it back to the prompt"

  # the document panel: a tab per document; Ctrl+PgUp/PgDn switch, F3 hides it
  run("new other")
  expect "other" in stringify(appVar("status")), "the panel lists the new document"
  key(KeyEvent(kind: kevPageUp, ctrl: true))
  expect "switch scratch" in transcriptText(), "Ctrl+PgUp switches:\n" & transcriptText()
  shot("documents")
  key(KeyEvent(kind: kevF3))
  expect not toBool(appVar("show-docs")), "F3 hides the panel"
  key(KeyEvent(kind: kevF3))
  # Alt+O gives the panel the keys; it works the items like the items view
  key(KeyEvent(kind: kevLetter, ch: 'o', alt: true))
  expect toBool(appVar("in-docs")), "Alt+O focuses the panel"
  key(KeyEvent(kind: kevLetter, ch: '<', alt: true))
  key(KeyEvent(kind: kevLetter, ch: 'n', ctrl: true))
  expect toNumber(appVar("doc-selected")) == 1.0, "M-< then C-n selects the second item"
  shot("panel")
  key(KeyEvent(kind: kevText, text: "e"))
  expect not toBool(appVar("in-docs")) and toStr(appVar("draft")) == "use base",
    "e edits the item in the prompt: " & stringify(appVar("draft"))
  key(KeyEvent(kind: kevLetter, ch: 'a', ctrl: true))
  key(KeyEvent(kind: kevBackspace))

  key(KeyEvent(kind: kevLetter, ch: 'd', ctrl: true))
  expect screenTitle() == "Leave the repl?", "Ctrl+D with an unsaved document asks: " & screenTitle()
  shot("leave")
  key(KeyEvent(kind: kevEscape))
  expect isNothing(evalText("(repl-screen)")) and not toBool(evalText("(repl-over)")),
    "Escape stays"

try:
  putEnv("SDL_VIDEODRIVER", "offscreen")
  lib = owlLibrary()
  evaluate(lib)
  env = runProgram(lib, forms("use base\nuse modules\nuse repl\nuse repl-app\n"))
except:
  expect false, "program loads: " & lastError()

guiScript = script
try:
  discard evalText("(repl-app)")
except:
  expect false, "the repl app ran: " & lastError()

finish "repl gui"
