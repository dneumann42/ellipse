## Tests for the Duck Notepad clone: the `editor` document widget driven
## frame-by-frame (typing, click placement, drag, double-click, undo /
## redo, select-all, page turns, the unfocused position mirror), and the
## app's pure modules (search scan, EOL fold/expand, path helpers).
##
## Headless like widgets_test: a clay context with a monospace measure
## (every glyph 18x18 at the default size) and synthetic key events --
## no SDL window is ever opened, which also keeps the clipboard helpers
## safely inert.

import std/[syncio, strutils, os]

import clay
import ellipse/platform/platform
import ellipse_ui/ui
import ellipse_ui/widgets

import ../apps/duck/[doc, search, filelist]

var failures = 0
var passed = 0

proc expect(cond: bool, msg: string) =
  if cond:
    passed += 1
  else:
    failures += 1
    echo "FAILED: ", msg

proc mono(text: string; cfg: TextConfig): Size =
  Size(width: float32(text.len) * float32(cfg.fontSize),
       height: float32(cfg.fontSize))

proc nearly(a, b: float32): bool =
  let d = a - b
  d < 0.51'f32 and d > -0.51'f32

# --- caller state, immediate-mode style ------------------------------------------

var text = ""
var lastSt = EditorStats()
var editOpts = EditorOpts()

let eid = hashId("t.edit")

proc draw() =
  beginLayout()
  clay "root", col(width = grow(), height = grow(), gap = 0):
    lastSt = editor(eid, text, editOpts)
    text = lastSt.text
    discard button(hashId("t.out"), "out")   # a click target outside the editor
  endLayout()

proc frame() =
  beginInputFrame()
  notePressState()
  draw()

proc boxOf(id: ElementId): Rect =
  elementData(id).box

proc clickAt(p: Vec2) =
  setPointerState(p, true)
  frame()
  setPointerState(p, false)
  frame()

proc clickCenter(id: ElementId) =
  let b = boxOf(id)
  clickAt(vec2(b.x + b.width / 2.0, b.y + b.height / 2.0))

proc typeStr(s: string) =
  var i = 0
  while i < s.len:
    var one = ""
    one.add s[i]
    pushKeyEvent KeyEvent(kind: kevText, text: one)
    inc i
  frame()

proc pressKey(kind: KeyEventKind, shift = false, ctrl = false) =
  pushKeyEvent KeyEvent(kind: kind, shift: shift, ctrl: ctrl)
  frame()

proc pressChord(ch: char, ctrl = true, alt = false, shift = false) =
  pushKeyEvent KeyEvent(kind: kevLetter, ch: ch, ctrl: ctrl, alt: alt,
    shift: shift)
  frame()

proc selNow(): tuple[lo, hi: int] =
  editorSel(eid, text)

var tbox = Rect()   # the editor text box, refreshed when laid out

proc pointAt(ci: int): Vec2 =
  vec2(tbox.x + float32(ci) * 18.0 + 4.0, tbox.y + 9.0)

proc main() {.raises.} =
  setCurrentContext(initContext(size(800.0, 600.0)))
  setMeasureText(mono)

  # settle the pointer state machine, as updateUI would
  setPointerState(vec2(-100.0, -100.0), false)
  frame()
  expect(elementData(eid).found, "editor: lays out")
  expect(takeErrors().len == 0, "editor: no clay errors")

  # --- click focuses, typing appends -------------------------------------------------
  clickCenter(eid)
  expect(focused(eid), "editor: click focuses")
  typeStr("hello world")
  expect(text == "hello world",
    "editor: typing lands in the buffer, got " & text)
  let (lo, hi) = selNow()
  expect(lo == hi and lo == 11, "editor: caret sits after the typing")

  # --- double click selects the word ------------------------------------------------
  tbox = boxOf(ElementId(id: textChildId(eid.id)))
  pushDoubleClick()
  setPointerState(pointAt(7), true)   # inside "world"
  frame()
  setPointerState(pointAt(7), false)
  frame()
  let wsel = selNow()
  expect(wsel.lo == 6 and wsel.hi == 11,
    "editor: double click selects the word, got " & $wsel.lo & ".." & $wsel.hi)

  # --- Ctrl+A selects all; typing replaces the selection -----------------------------
  pressChord('a')
  let asel = selNow()
  expect(asel.lo == 0 and asel.hi == 11, "editor: Ctrl+A selects all")
  typeStr("q")
  expect(text == "q", "editor: typing over the selection replaces it, got " & text)

  # --- undo / redo history ------------------------------------------------------------
  pressChord('z')
  expect(text == "hello world", "editor: undo restores the pre-selection text, got " & text)
  pressChord('y')
  expect(text == "q", "editor: redo re-applies, got " & text)

  # keep typing: the new edit starts a fresh undo group (the redo consumed the old)
  typeStr(" hello")
  expect(text == "q hello", "editor: typing continues from the caret, got " & text)
  pressChord('z')
  expect(text == "q", "editor: undo reverts just the new run, got " & text)

  # --- click places the caret mid-text ------------------------------------------------
  text = "one two three"
  frame()
  frame()   # let the new buffer's geometry settle
  pressChord('a')          # select all: Ctrl+A -- then click to place
  clickAt(pointAt(5))      # inside "two"
  let cs = selNow()
  expect(cs.lo == cs.hi and cs.lo >= 4 and cs.lo <= 6,
    "editor: click places the caret between the neighbours, got " & $cs.lo)
  typeStr("X")
  expect(text == "one tXwo three",
    "editor: typing inserts at the clicked caret, got " & text)

  # --- drag selects ------------------------------------------------------------------
  beginInputFrame()
  setPointerState(pointAt(4), true)
  frame()
  beginInputFrame()
  setPointerState(pointAt(4), true)     # held: state -> pressed
  frame()
  beginInputFrame()
  setPointerState(pointAt(9), true)     # sweep right, still held
  frame()
  beginInputFrame()
  setPointerState(pointAt(9), false)
  frame()
  let dsel = selNow()
  expect(dsel.hi > dsel.lo, "editor: click-drag produced a selection")

  # --- page down walks the text a viewport at a time ---------------------------------
  var many = ""
  var k = 0
  while k < 60:
    many.add "line" & $k
    if k < 59: many.add "\n"
    inc k
  text = many
  frame()
  frame()
  clickAt(vec2(tbox.x + 2.0, tbox.y + 2.0))   # caret at the very top
  let before = selNow().lo
  expect(before == 0, "editor: click at the corner lands on the first line")
  pressKey(kevPageDown)
  let after = caretPos()
  expect(after > 0 and after < text.len,
    "editor: PageDown jumps into the middle, got " & $after)

  # --- Ctrl+Home / Ctrl+End -----------------------------------------------------------
  pressChord('0')   # unknown chord: must not move anything by itself
  pressKey(kevHome, ctrl = true)
  expect(selNow().lo == 0, "editor: Ctrl+Home goes to the document start")
  pressKey(kevEnd, shift = true)
  let hs = selNow()
  expect(hs.lo == 0 and hs.hi > 0, "editor: Shift+End extends a selection")

  # --- position mirror: unfocused keeps caret & selection -----------------------------
  setPointerState(vec2(10.0, 570.0), true)   # the "out" button row, past the editor
  frame()
  setPointerState(vec2(10.0, 570.0), false)
  frame()
  expect(not focused(eid), "editor: click outside blurs")
  let ms = editorSel(eid, text)
  expect(ms.hi > ms.lo, "editor: selection survives blur (mirror)")
  editorRestoreFocus(eid, text)
  expect(focused(eid), "editor: restore focus takes the keyboard back")

  # --- Enter is a newline, Escape is inert --------------------------------------------
  text = "ab\ncd"
  frame()
  clickAt(vec2(tbox.x + 30.0, tbox.y + 9.0))  # caret end of "ab"
  pressKey(kevEnter)
  expect(text == "ab\n\ncd",
    "editor: Enter inserts a newline mid-text, got " & text)
  pressKey(kevEscape)
  expect(text == "ab\n\ncd", "editor: Escape does not mutate the document")

  # --- Enter on an empty page moves the caret down a line ----------------------------
  text = ""
  frame()
  editorPlaceCaret(eid, text, 0)
  pressKey(kevEnter)
  pressKey(kevEnter)
  frame()
  let tel = ElementId(id: textChildId(eid.id))
  expect(text == "\n\n" and caretPos() == 2,
    "editor: two Enters on an empty page, got " & $text.len)
  expect(nearly(boxOf(tel).height, 54.0),
    "editor: newline-only text lays out a line each, got " &
    $boxOf(tel).height)

  # --- the view follows the caret past the bottom edge -------------------------------
  var tall = ""
  var j = 0
  while j < 60:
    tall.add "\n"
    inc j
  text = tall
  frame()
  editorPlaceCaret(eid, text, text.len)   # the empty line after the last newline
  frame()
  frame()
  let esd = scrollContainerData(eid)
  let ebox = boxOf(eid)
  expect(esd.found and esd.position.y < 0.0,
    "editor: scrolled down to the caret, got " & $esd.position.y)
  let caretBot = boxOf(tel).y + 61.0'f32 * 18.0'f32
  expect(caretBot <= ebox.y + ebox.height + 0.5,
    "editor: the last line is inside the view, bottom " & $caretBot &
    " vs " & $(ebox.y + ebox.height))
  editorPlaceCaret(eid, text, 0)
  frame()
  frame()
  expect(nearly(scrollContainerData(eid).position.y, 0.0),
    "editor: back at the top scrolls up again, got " &
    $scrollContainerData(eid).position.y)
  # The wheel (or the scrollbar) moves the page while the caret holds still:
  # the caret must not drag the view back.
  setScrollPosition(eid, vec2(0.0, -100.0))
  frame()
  frame()
  frame()
  expect(nearly(scrollContainerData(eid).position.y, -100.0),
    "editor: a still caret lets the page scroll, got " &
    $scrollContainerData(eid).position.y)
  pressKey(kevRight)                      # a moving caret pulls it back
  frame()
  frame()
  expect(nearly(scrollContainerData(eid).position.y, 0.0),
    "editor: moving the caret returns the view to it, got " &
    $scrollContainerData(eid).position.y)
  editorPlaceCaret(eid, text, 3)   # where the Enter test left it: "xyz"'s end below

  # --- stats flags --------------------------------------------------------------------
  text = "xyz"
  frame()
  expect(not lastSt.edited,
    "editor: an external buffer swap is not an edit")
  typeStr("!")
  expect(text == "xyz!" and lastSt.edited,
    "editor: keystrokes report as edits, got " & text)

  # --- the caret rides the text end while typing ------------------------------------
  # Wrapping must use the box's width, not the text box's last-frame width
  # (the old text's): that put a just-typed caret on a phantom next line.
  text = ""
  frame()
  editorPlaceCaret(eid, text, 0)
  let caretEl = ElementId(id: hashNumber(1'u32, tel.id))
  var drift = 0
  for ch in "typing along":
    var one = ""
    one.add ch
    typeStr(one)
    let cb = boxOf(caretEl)
    let tb = boxOf(tel)
    if not nearly(cb.y, tb.y) or not nearly(cb.x, tb.x + tb.width):
      inc drift
  expect(drift == 0, "editor: caret at the text end on typing frames, " &
    $drift & " frames off")

  # --- code editing: Tab, Shift+Tab, auto-indent -------------------------------------
  text = "ab"
  frame()
  editorPlaceCaret(eid, text, 0)
  pressKey(kevTab)
  expect(text == "    ab" and caretPos() == 4,
    "editor: Tab inserts the indent, got '" & text & "'")
  pressKey(kevTab, shift = true)
  expect(text == "ab" and caretPos() == 0,
    "editor: Shift+Tab outdents the line, got '" & text & "'")
  text = "one\ntwo\nthree"
  frame()
  editorSelect(eid, text, 1, 6)            # "ne\ntw": two lines touched
  pressKey(kevTab)
  expect(text == "    one\n    two\nthree",
    "editor: Tab indents every selected line, got '" & text & "'")
  expect(selNow() == (5, 14),
    "editor: the selection follows the indented text, got " & $selNow().lo &
    ".." & $selNow().hi)
  pressKey(kevTab, shift = true)
  expect(text == "one\ntwo\nthree" and selNow() == (1, 6),
    "editor: Shift+Tab outdents them back, got '" & text & "'")
  pressChord('z', ctrl = true)
  expect(text == "    one\n    two\nthree",
    "editor: an outdent undoes on its own, got '" & text & "'")
  pressChord('z', ctrl = true, shift = true)
  expect(text == "one\ntwo\nthree", "editor: Ctrl+Shift+Z redoes, got '" &
    text & "'")
  editOpts.autoIndent = true
  text = "  if x:"
  frame()
  editorPlaceCaret(eid, text, text.len)
  pressKey(kevEnter)
  typeStr("y")
  expect(text == "  if x:\n  y",
    "editor: autoIndent keeps the line's indent, got '" & text & "'")
  editOpts.autoIndent = false
  # keys act in the order pressed: the Tab lands between the two letters
  text = ""
  frame()
  editorPlaceCaret(eid, text, 0)
  pushKeyEvent KeyEvent(kind: kevText, text: "a")
  pushKeyEvent KeyEvent(kind: kevTab)
  pushKeyEvent KeyEvent(kind: kevText, text: "b")
  frame()
  expect(text == "a    b", "editor: same-frame keys keep their order, got '" &
    text & "'")

  # --- word deletes and Shift+Up/Down -------------------------------------------------
  text = "alpha beta gamma"
  frame()
  editorPlaceCaret(eid, text, text.len)
  pressKey(kevBackspace, ctrl = true)
  expect(text == "alpha beta ", "editor: Ctrl+Backspace deletes a word, got '" &
    text & "'")
  editorPlaceCaret(eid, text, 0)
  pressKey(kevDelete, ctrl = true)
  expect(text == " beta ", "editor: Ctrl+Delete deletes a word, got '" & text &
    "'")
  text = "abc\ndef"
  frame()
  editorPlaceCaret(eid, text, 1)
  pressKey(kevDown, shift = true)
  expect(selNow() == (1, 5), "editor: Shift+Down extends the selection, got " &
    $selNow().lo & ".." & $selNow().hi)
  pressKey(kevUp, shift = true)
  expect(selNow() == (1, 1), "editor: Shift+Up shrinks it back, got " &
    $selNow().lo & ".." & $selNow().hi)

  # --- scrollbars stay up, wrap on or off, and the text keeps clear of them --------
  proc barTracks(): seq[Rect] =
    result = @[]
    let cmds = renderCommands()
    for c in cmds:
      if c.kind == renderRectangle and c.zIndex == 220'i16:
        result.add c.box
  for w in [true, false]:
    editOpts.wrap = w
    for n in [3, 400]:
      var doc = ""
      for i in 0 ..< n:
        doc.add "a line of text\n"
      text = doc
      frame()
      frame()
      frame()
      let bars = barTracks()
      let want = if w: 1 else: 2
      expect(bars.len == want, "editor: wrap=" & $w & " lines=" & $n &
        " shows " & $want & " scrollbar(s), got " & $bars.len)
      if bars.len > 0:
        let tb = boxOf(tel)
        expect(tb.x + tb.width <= bars[0].x,
          "editor: wrap=" & $w & " text stops before the vertical bar")
  editOpts.wrap = true

  expect(takeErrors().len == 0, "editor: no clay errors after the session")

  # --- search ------------------------------------------------------------------------
  let hay = "Hello world, hello again"
  var f = findFrom(hay, "hello", 0, true)
  expect(f.found and f.lo == 0, "search: caseless finds the prefix")
  f = findFrom(hay, "hello", 1, true)
  expect(f.found and f.lo == 13, "search: caseless skips to the next hit")
  f = findFrom(hay, "hello", 0, false)
  expect(f.found and f.lo == 13, "search: caseless=false matches lowercase only")
  f = findFrom(hay, "hello", 20, false, false)
  expect(not f.found, "search: no wrap finds nothing past the last hit")
  f = findFrom(hay, "hello", 20, false)
  expect(f.found and f.lo == 13, "search: wrap restarts from the top")
  f = findBack(hay, "hello", 2, false)
  expect(f.found and f.lo == 13, "search: backward wraps to the last hit")
  expect(countMatches(hay, "hello", true) == 2, "search: countMatches")
  var outp = ""
  var n = 0
  replaceAll(hay, "hello", "hi", true, outp, n)
  expect(n == 2 and outp == "hi world, hi again",
    "search: replaceAll rewrites every hit, got " & outp)

  # --- doc: EOL fold / expand -----------------------------------------------------------
  let folded = doc.normalize("a\r\nb\rc\n")
  expect(folded == "a\nb\nc\n", "doc: normalize folds CRLF and CR, got " & folded)
  expect(nameOf("/home/me/notes.txt") == "notes.txt", "doc: nameOf basename")
  expect(dirOf("/home/me/notes.txt") == "/home/me/", "doc: dirOf keeps the sep")
  expect(nameOf("") == "Untitled", "doc: nameOf untitled")
  expect(title().endsWith(" - Duck"), "doc: title carries the app name")

  # --- filelist: path helpers -------------------------------------------------------------
  expect(normDir("/tmp/") == "/tmp", "filelist: normDir trims the tail")
  expect(isRoot("/"), "filelist: root detection")
  expect(parentOf("/tmp/opencode") == "/tmp", "filelist: parentOf")
  expect(parentOf("/") == "/", "filelist: parentOf root is root")
  expect(joinDir("/", "etc") == "/etc", "filelist: join at root")
  expect(joinDir("/tmp", "a.txt") == "/tmp/a.txt", "filelist: join")

  # --- io round trip: CRLF out, LF buffer, style remembered --------------------------------
  let tmp = "/tmp/opencode/duck_io.txt"
  document.text = "one\ntwo\n"
  discard savePath(tmp)
  var raw = "?"
  try:
    raw = readFile(tmp)
  except:
    raw = "?"
  expect(raw == "one\r\ntwo\r\n",
    "io: a new document saves with CRLF like the original, got " & $raw)
  document.text = ""
  document.path = ""
  expect(openPath(tmp).ok, "io: opens back what it wrote")
  expect(document.text == "one\ntwo\n", "io: CR folds to LF in the buffer")
  expect(document.eol == eolCRLF, "io: the file's own EOL style is remembered")
  expect(not document.dirty, "io: loading is clean, not an edit")

  echo "duck_test: ", passed, " passed, ", failures, " failed"
  if failures > 0:
    quit 1

when isMainModule:
  try:
    main()
  except ErrorCode:
    echo "duck_test aborted by ErrorCode"
    quit 1
