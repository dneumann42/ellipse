## The terminal backend's pure parts: input decoding (bytes -> events) and
## the cell buffer (render commands -> cells -> text / ANSI).

import std/syncio
import std/strutils

import clay
import ellipse/platform/keyevents
import ellipse/terminal/[terminput, cellbuf, cellwidth]

var failures = 0
var passed = 0

proc expect(cond: bool, msg: string) =
  if cond:
    passed += 1
  else:
    failures += 1
    echo "FAILED: ", msg

proc describe(ev: TermEvent): string =
  case ev.kind
  of teKey:
    let k = ev.key
    result = ""
    if k.ctrl: result.add "C-"
    if k.alt: result.add "A-"
    if k.shift: result.add "S-"
    case k.kind
    of kevText: result.add "text:" & k.text
    of kevLetter: result.add "chord:" & $k.ch
    else: result.add $k.kind
  of teMouse:
    result = "mouse " & $ev.button & " " & $ev.col & "," & $ev.row
    if ev.motion: result.add " move"
    result.add(if ev.pressed: " down" else: " up")
  of teWheel:
    result = "wheel " & $int(ev.dy) & " at " & $ev.wcol & "," & $ev.wrow
    if ev.ctrl: result = "C-" & result
  of tePaste:
    result = "paste:" & ev.text
  of teFocus:
    result = if ev.focused: "focus in" else: "focus out"

proc decode(chunks: varargs[string]): string =
  var d = Decoder()
  var parts: seq[string] = @[]
  for c in chunks:
    for ev in d.feed(c):
      parts.add describe(ev)
  parts.join(" | ")

proc testKeys() =
  expect(decode("hé") == "text:h | text:é", "text: " & decode("hé"))
  expect(decode("\r\t\x7f") == "kevEnter | kevTab | kevBackspace",
    "controls: " & decode("\r\t\x7f"))
  expect(decode("\x03") == "C-chord:c", "ctrl+c: " & decode("\x03"))
  expect(decode("\e") == "kevEscape", "lone esc: " & decode("\e"))
  expect(decode("\ex") == "A-chord:x", "alt+x: " & decode("\ex"))
  expect(decode("\e[A\e[1;5C\eOH") == "kevUp | C-kevRight | kevHome",
    "arrows: " & decode("\e[A\e[1;5C\eOH"))
  expect(decode("\e[3~\e[5;2~\e[15~\e[Z") ==
    "kevDelete | S-kevPageUp | kevF5 | S-kevTab",
    "tilde keys: " & decode("\e[3~\e[5;2~\e[15~\e[Z"))
  # kitty: Esc, Ctrl+Shift+A, Tab, plain 'q', Ctrl+I distinct from Tab
  expect(decode("\e[27u\e[97;6u\e[9u\e[113u\e[105;5u") ==
    "kevEscape | C-S-chord:a | kevTab | text:q | C-chord:i",
    "kitty: " & decode("\e[27u\e[97;6u\e[9u\e[113u\e[105;5u"))

proc testSplitReads() =
  expect(decode("\e[1;", "5A") == "C-kevUp", "split csi: " & decode("\e[1;", "5A"))
  expect(decode("\xc3", "\xa9") == "text:é", "split utf-8: " & decode("\xc3", "\xa9"))

proc testMouseAndPaste() =
  expect(decode("\e[<0;5;3M\e[<32;6;3M\e[<0;6;3m") ==
    "mouse mbLeft 4,2 down | mouse mbLeft 5,2 move down | mouse mbLeft 5,2 up",
    "mouse: " & decode("\e[<0;5;3M\e[<32;6;3M\e[<0;6;3m"))
  expect(decode("\e[<35;10;1M") == "mouse mbNone 9,0 move up",
    "hover: " & decode("\e[<35;10;1M"))
  expect(decode("\e[<65;2;2M\e[<80;1;1M") == "wheel -1 at 1,1 | C-wheel 1 at 0,0",
    "wheel: " & decode("\e[<65;2;2M\e[<80;1;1M"))
  expect(decode("\e[200~a\e[Bb\e[2", "01~x") == "paste:a\e[Bb | text:x",
    "paste: " & decode("\e[200~a\e[Bb\e[2", "01~x"))
  expect(decode("\e[I\e[O") == "focus in | focus out", "focus")

proc testWidth() =
  expect(displayWidth("abc") == 3, "width ascii")
  expect(displayWidth("日本") == 4, "width cjk")
  expect(displayWidth("é") == 1, "width combining")

# --- cells -------------------------------------------------------------------

const cw = 8'f32
const ch = 16'f32

proc cellsMeasure(text: string; cfg: TextConfig): Size =
  Size(width: float32(displayWidth(text)) * cw, height: ch)

proc layoutOf(cols, rows: int; body: proc () {.closure.}): CellBuffer =
  let ctx = initContext(size(float32(cols) * cw, float32(rows) * ch))
  ctx.setMeasureText(cellsMeasure)
  ctx.setGrid(size(cw, ch))
  setCurrentContext(ctx)
  beginLayout(ctx)
  body()
  endLayout(ctx)
  result = initCellBuffer(cols, rows, cw, ch, Rgb(r: 0, g: 0, b: 0),
                          Rgb(r: 255, g: 255, b: 255))
  result.paint(ctx.commands)

proc testBoxes() =
  # Boxes with a free cell around their content get every line.
  let pad = Padding(left: 8, right: 8, top: 16, bottom: 16)
  let buf = layoutOf(16, 4, proc () {.closure.} =
    openElement(row(gap = 8))
    openElement(row(padding = pad).border(1, rgb(200, 200, 200)).corner(4))
    textElement("ok")
    closeElement()
    openElement(row(padding = pad).border(2, rgb(200, 200, 200)))
    textElement("hi")
    closeElement()
    closeElement())
  let want = "╭──╮ ┏━━┓\n│ok│ ┃hi┃\n╰──╯ ┗━━┛\n\n"
  expect(buf.toPlain == want, "boxes:\n" & buf.toPlain)

proc testOneRowCaps() =
  # Side lines on a one-row box are caps, a pill's are parentheses; a
  # bottom line alone underlines.
  let side = Padding(left: 8, right: 8)
  let buf = layoutOf(12, 1, proc () {.closure.} =
    openElement(row(gap = 8))
    openElement(row(padding = side).border(1, rgb(1, 1, 1)))
    textElement("x")
    closeElement()
    openElement(row(padding = side).border(1, rgb(1, 1, 1)).corner(12))
    textElement("y")
    closeElement()
    var under = row()
    under.border = BorderConfig(color: rgb(1, 1, 1),
                                width: BorderWidth(bottom: 2))
    openElement(under)
    textElement("tab")
    closeElement()
    closeElement())
  expect(buf.toPlain == "[x] (y) tab\n", "caps: [" & buf.toPlain & "]")
  expect(caUnderline in buf.cells[8].attrs, "bottom line underlines a row")

proc testClipAndWide() =
  let buf = layoutOf(6, 2, proc () {.closure.} =
    openElement(col(width = fixedPx(5 * cw), height = fixedPx(ch)).clip(true, true))
    textElement("ab日本語")
    closeElement())
  # 5 columns: a b 日, then 本 straddles the clip edge and shows blank.
  expect(buf.toPlain == "ab日\n\n",
    "clip wide: [" & buf.toPlain & "]")

proc testTranslucent() =
  var seen = Rgb()
  var glyph = ""
  let buf = layoutOf(4, 1, proc () {.closure.} =
    openElement(row().bg(rgb(100, 100, 100)))
    textElement("ab")
    openElement(row(width = fixedPx(2 * cw), height = fixedPx(ch))
      .bg(rgb(0, 0, 0, 128)).floating(attachParent))
    closeElement()
    closeElement())
  seen = buf.cells[0].bg
  glyph = buf.cells[0].glyph
  expect(glyph == "a", "translucent keeps the glyph, got " & glyph)
  expect(seen.r > 40 and seen.r < 60, "translucent blends the background, got " &
    $seen.r)

proc rfindH(s: string): int =
  result = -1
  for i in 0 ..< s.len:
    if s[i] == 'H':
      result = i

proc testDiff() =
  var a = initCellBuffer(4, 2, cw, ch, Rgb(), Rgb(r: 255, g: 255, b: 255))
  var b = a
  b.putGlyph(2, 1, "x", Rgb(r: 255, g: 0, b: 0), {}, b.full)
  let out1 = toAnsi(b, a, cmTrue, false)
  expect(out1.contains("\e[2;3H") and out1.contains("x") and
    out1.find("H") == out1.rfindH, "diff: one cell moved to and written: " & out1.escape)
  expect(toAnsi(b, b, cmTrue, false).len == 0, "diff: nothing changed, nothing sent")
  let c16 = toAnsi(b, a, cm16, false)
  expect(c16.contains(";91") or c16.contains(";31"), "16 colours: " & c16.escape)

testKeys()
testSplitReads()
testMouseAndPaste()
testWidth()
testBoxes()
testOneRowCaps()
testClipAndWide()
testTranslucent()
testDiff()

echo "terminal: ", passed, " passed, ", failures, " failed"
if failures > 0:
  quit(1)
