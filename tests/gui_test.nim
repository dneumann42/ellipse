## Owl apps on ellipse_ui, headless: the `widget` command, events bubbling
## through owl and Nim widgets alike (translation, reemit with a changed
## payload, stock events seen as records), the definition-time emit check,
## and a failing view that recovers.

import std/[syncio, envvars, options, strutils]
import owl/[objects, reader, evaluator, library]
from owl/modules import Library, evaluate, runProgram
import owl/libraries/gui
import ellipse_ui/app
import ./testutils

captureStdio()

const program = """
use base
use math
use strings
use io
use gui

clicks = 0
toggled = nothing
seen = ([])

widget Panel &body:
    emits Changed what
    event Toggled e:
        append seen "panel"
        set e (with e (on = (not e.on)))
        reemit
    event Bumped e:
        emit Changed (what = (concat "bump" (to-string e.by)))
    column (padding = 4) (gap = 4):
        (body)

widget focusable Bumper label:
    emits Bumped by
    when (button (concat id ".b") label):
        emit Bumped (by = 2)
    focused id

fun view:
    handle-events:
        event Bumped e:
            set clicks 1000
        event Changed e:
            append seen e.what
            set clicks (+ clicks 1)
        event Toggled e:
            append seen (concat "root " (to-string e.on))
            set toggled e.on
        column (width = grow) (height = grow):
            Panel:
                Bumper "bumper" "Bump"
                switch "sw" "Switch" false

fun broken:
    column:
        text (+ 1 "x")
"""

proc forms(src: string): seq[Object] =
  let r = parseOwl(src)
  expect r.isOk, "parse ok"
  result = r.get(@[])

var lib: Library
var env: ref Environment

proc value(name: string): Object =
  let v = lookup(env, symbol(name))
  expect v.isSome, name & " is bound"
  v.get(nothing())

proc evalText(src: string): Object =
  result = nothing()
  try:
    result = evalForms(env, forms(src))
  except:
    expect false, "should run: " & lastError() & "\n" & src

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
  frame()

proc script() {.raises.} =
  frame()
  frame()
  clickAt("bumper.b")
  expect toNumber(value("clicks")) == 1.0,
    "Bumped was translated by Panel into Changed, which the root caught: clicks " &
    stringify(value("clicks"))
  clickAt("sw")
  expect value("toggled") == boolean(false),
    "the switch's Toggled (on) reached the root flipped by Panel's reemit: " &
    stringify(value("toggled"))
  expect stringify(value("seen")) == "[] bump2 panel root false", "who saw what: " & stringify(value("seen"))
  # a failing view keeps the frame balanced and recovers
  setOwlView(evalText("broken"))
  frame()
  expect isString(evalText("(frame-error)")), "the failure is kept"
  setOwlView(evalText("view"))
  frame()
  expect isNothing(evalText("(frame-error)")), "and cleared once the view works"

try:
  lib = owlLibrary()
  evaluate(lib)
  env = runProgram(lib, forms(program))
except:
  expect false, "program loads: " & lastError()

clearCaptured()
try:
  discard evalForms(env, forms("widget Bad:\n    emit Nope (x = 1)\n"))
  expect false, "an undeclared emit is refused"
except:
  expect lastError().len > 0 and "without declaring" in lastError(),
    "the refusal says why: " & lastError()

expect "widget-frame" in toStr(evalText("widget-code \"Bumper\"")), "widget-code shows the generated fun"

try:
  putEnv("SDL_VIDEODRIVER", "offscreen")
  run(owlApp(evalText("view"), WindowConfig(title: "gui test", width: 400, height: 300)), script)
except:
  expect false, "app ran"

finish "gui"
