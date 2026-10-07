import std/[syncio, strutils, options]
import owl/[objects, reader, evaluator, modules]
import owl/libraries/[base, math, io, term]
import ./testutils

captureStdio()

# tui.owl driven by scripted keys: tui-read-key, tui-write, tui-raw and
# tui-width are replaced, so no terminal is needed.

proc newLib(): Library {.raises.} =
  result = newLibrary("tui-test")
  add(result, baseModule())
  add(result, mathModule())
  add(result, ioModule())
  add(result, termModule())
  add(result, newModule("strings").addFile("src/owl/libraries/strings.owl"))
  add(result, newModule("ansi").addFile("src/owl/libraries/ansi.owl"))
  add(result, newModule("keys").addFile("src/owl/libraries/keys.owl"))
  add(result, newModule("tui").addFile("src/owl/libraries/tui.owl"))
  evaluate(result)

const harness = """
use io
use base
use math
use ansi
use tui

script = ([])
frames = ([])
fun fake-key:
    if (is-empty script):
        "<EOF>"
        pop-front script
fun fake-write s:
    append frames s
fun fake-raw on:
    nothing
fun fake-width:
    40
set tui-read-key fake-key
set tui-write fake-write
set tui-raw fake-raw
set tui-width fake-width

fun keys xs:
    set script xs
    set frames ([])

; The last frame drawn, without styling.
fun last-frame:
    i = (- (length frames) 1)
    found = nothing
    while (and (= found nothing) (> i -1)):
        f = index frames (+ i 0)
        when (<> (find f "┌") nothing):
            set found (strip f)
        set i (- i 1)
    found
"""

proc run(src: string): ref Environment =
  clearCaptured()
  try:
    let r = parseOwl(harness & src)
    if not r.isOk:
      expect false, "parse: " & r.error("")
    result = runProgram(newLib(), r.get(@[]))
  except:
    expect false, "program should run: " & lastError()
    result = newEnvironment()

proc show(env: ref Environment, name: string): string =
  let v = lookup(env, symbol(name))
  expect v.isSome, name & " is bound"
  result = stringify(v.get(nothing()))

proc formWorks() {.raises.} =
  let env = run("""
keys ([] " " "<down>" " " "<TAB>" "<right>" "<left>" "<RET>")
verbose = checkbox "Verbose"
color = checkbox "Color" true
r = run-screen "Options" ([] (label "Pick some") verbose color (button-row ([] "OK" "Cancel")))
v = (verbose.value)
c = (color.value)
frame = (last-frame)
""")
  expect show(env, "r") == "OK", "the button row closes the screen with its text"
  expect show(env, "v") == "true", "space toggles the focused checkbox"
  expect show(env, "c") == "false", "down moves focus to the next checkbox"
  let frame = show(env, "frame")
  expect frame.contains("┌─ Options ─") and frame.contains("│ [x] Verbose") and
    frame.contains("│ [ ] Color") and frame.contains("[ OK ]  [ Cancel ]"),
    "the form is drawn in a box:\n" & frame
  for line in frame.replace("\r", "").split("\n"):
    if line.startsWith("│"):
      expect line.endsWith("│"), "box lines are padded to the width: " & line

proc cancelWorks() {.raises.} =
  let env = run("""
keys ([] "<ESC>")
a = confirm "Leave?" "Unsaved: scratch"
keys ([] "<C-g>")
b = choose "Pick" ([] "a" "b")
by = closed-by
erased = index frames (- (length frames) 2)
""")
  expect show(env, "a") == "()", "esc cancels with nothing"
  expect show(env, "b") == "()", "C-g cancels too"
  expect show(env, "by") == "()", "nothing closed the screen"
  expect show(env, "erased").contains("\e[6A\r\e[J"),
    "the screen's 6 rows are erased when it closes: " & show(env, "erased").escape

proc menuWorks() {.raises.} =
  let env = run("""
cmds = [] (entry "open" "open" "open a module") (entry "show" "show" "print an item") (entry "save" "save" "write the document") (entry "shell" "sh-value" "run a shell")
keys ([] "s" "h" "<down>" "<RET>")
filtered = choose "Commands" cmds
keys ([] "M" "O" "D" "<RET>")
by-hint = choose "Commands" cmds
keys ([] "o" "p" "<RET>")
ranked = choose "Commands" ([] (entry "docs" "docs" "list open documents") (entry "drop" "drop" "remove") (entry "open" "open" "open a module"))
keys ([] "z" "z" "<RET>" "<DEL>" "<DEL>" "<end>" "<RET>")
none-then-last = choose "Commands" cmds
many = ([])
n = 0
while (< n 30):
    append many (concat "item" (to-string n))
    set n (+ n 1)
keys ([] "<next>" "<next>" "<down>")
scrolled = choose "Many" many 5
frame = (last-frame)
""")
  expect show(env, "filtered") == "sh-value", "typing filters, the value is the entry's"
  expect show(env, "by-hint") == "open", "the filter matches hints, ignoring case"
  expect show(env, "ranked") == "open", "a label that starts with the text ranks before other matches"
  expect show(env, "none-then-last") == "sh-value", "enter on no match does nothing; end goes last"
  let frame = show(env, "frame")
  expect frame.contains("› item11") and frame.contains("item7") and not frame.contains("item6 "),
    "a long menu scrolls with the selection:\n" & frame
  expect frame.contains("… 18 more"), "and says how many are below:\n" & frame

proc askWorks() {.raises.} =
  let env = run("""
keys ([] "a" "b" "<DEL>" "c" "<RET>")
typed = ask "Name" "name" "x-"
keys ([] "C" "a" "n" "c" "e" "l" "<RET>")
literal = ask "Name" "name"
keys ([] "q" "<TAB>" "<right>" "<RET>")
cancelled = ask "Name" "name"
keys ([] "é" "<DEL>" "ü" "<RET>")
utf = ask "Name" "name"
""")
  expect show(env, "typed") == "x-ac", "a text field edits and enter accepts"
  expect show(env, "literal") == "Cancel", "typing the word Cancel is still text"
  expect show(env, "cancelled") == "()", "the Cancel button gives nothing"
  expect show(env, "utf") == "ü", "DEL removes a whole UTF-8 character"

proc fitWorks() {.raises.} =
  let env = run("""
a = fit "hello world" 5
b = fit "héllo" 5
w = width-of (concat (bold "ab") "│")
""")
  expect show(env, "a") == "hell…", "fit cuts with an ellipsis"
  expect show(env, "b") == "héllo", "fit counts characters, not bytes"
  expect show(env, "w") == "3", "width-of ignores styling and counts characters"

check("form", formWorks)
check("cancel", cancelWorks)
check("menu", menuWorks)
check("ask", askWorks)
proc lineEditingWorks() {.raises.} =
  let env = run("""
keys ([] "<C-a>" "X" "<C-e>" "Y" "<RET>")
ends = ask "Name" "name" "abc"
keys ([] "<C-b>" "<C-b>" "<C-d>" "<left>" "<DEL>" "<RET>")
deletes = ask "Name" "name" "abcde"
keys ([] "<M-b>" "<C-k>" "<C-a>" "<C-y>" "<RET>")
killed = ask "Path" "file" "/home/me/src/scratch.owl"
keys ([] "<C-w>" "<RET>")
word-back = ask "Path" "file" "one two-three"
keys ([] "<C-w>" "<C-w>" "<RET>")
words-back = ask "Path" "file" "one two-three"
keys ([] "<C-a>" "<M-f>" "<M-d>" "<RET>")
word-fwd = ask "Path" "file" "one two three"
keys ([] "<C-u>" "n" "e" "w" "<RET>")
cleared = ask "Path" "file" "old"
keys ([] "<C-t>" "<RET>")
swapped = ask "Name" "name" "ab"
keys ([] "<C-a>" "<C-f>" "é" "<C-f>" "<DEL>" "<RET>")
utf = ask "Name" "name" "aüz"
keys ([] "<C-a>" "<RET>")
long = ask "Path" "file" "/a/very/long/path/that/does/not/fit/in/the/box/at/all/scratch.owl"
frame = (last-frame)
""")
  expect show(env, "ends") == "XabcY", "C-a and C-e move to the start and end"
  expect show(env, "deletes") == "ace", "C-b, C-d, left and DEL edit inside the text: " & show(env, "deletes")
  expect show(env, "killed") == "owl/home/me/src/scratch.", "M-b, C-k kill to the end, C-y yanks it back: " & show(env, "killed")
  expect show(env, "word-back") == "one two-", "C-w kills a word back: " & show(env, "word-back")
  expect show(env, "words-back") == "one ", "and again takes the word before with its separator: " & show(env, "words-back")
  expect show(env, "word-fwd") == "one three", "M-f and M-d work by words: " & show(env, "word-fwd")
  expect show(env, "cleared") == "new", "C-u kills to the start"
  expect show(env, "swapped") == "ba", "C-t transposes at the end"
  expect show(env, "utf") == "aéz", "moving and deleting go by UTF-8 characters: " & show(env, "utf")
  let frame = show(env, "frame")
  expect frame.contains("file: /a/very") and frame.contains("…"),
    "a long text shows its start when point is there, cut with an ellipsis:\n" & frame
  for line in frame.replace("\r", "").split("\n"):
    if line.startsWith("│"):
      expect line.endsWith("│"), "the field stays inside the box: " & line

check("fit", fitWorks)
check("line editing", lineEditingWorks)

finish "tui"
