## Clay's character-grid mode (`setGrid`): declarations written in pixels
## land on whole 8x16 cells.

import std/syncio
import std/strutils

import clay

var failures = 0
var passed = 0

proc expect(cond: bool, msg: string) =
  if cond:
    passed += 1
  else:
    failures += 1
    echo "FAILED: ", msg

const cellW = 8'f32
const cellH = 16'f32

## A terminal's measure: one cell per byte (ASCII tests), one row high.
proc cells(text: string; cfg: TextConfig): Size =
  Size(width: float32(text.len) * cellW, height: cellH)

proc fresh(cols, rows: int): Context =
  result = initContext(size(float32(cols) * cellW, float32(rows) * cellH))
  result.setMeasureText(cells)
  result.setGrid(size(cellW, cellH))

proc onGrid(r: Rect): bool =
  r.x / cellW == float32(int(r.x / cellW)) and
    r.y / cellH == float32(int(r.y / cellH)) and
    r.width / cellW == float32(int(r.width / cellW)) and
    r.height / cellH == float32(int(r.height / cellH))

proc cellBox(r: Rect): string =
  $int(r.x / cellW) & "," & $int(r.y / cellH) & " " &
    $int(r.width / cellW) & "x" & $int(r.height / cellH)

proc allOnGrid(ctx: Context): bool =
  for c in ctx.commands:
    if c.kind != renderClipEnd and c.kind != renderOverlayEnd and
        not onGrid(c.box):
      echo "  off grid: ", $c.kind, " ", cellBox(c.box)
      return false
  true

proc testPaddingAndGap() =
  # Pixel insets snap to cells, halves rounding down: 10px -> 1 col,
  # 8px -> 0 rows, gap 6 -> 1 col.
  let ctx = fresh(40, 10)
  beginLayout(ctx)
  openElement(ctx, elementId("r"), row(padding = Padding(left: 10, right: 10,
    top: 8, bottom: 24), gap = 6).bg(rgb(1, 1, 1)))
  textElement(ctx, "ab")
  textElement(ctx, "cd")
  closeElement(ctx)
  endLayout(ctx)
  let box = elementData(ctx, elementId("r")).box
  expect(cellBox(box) == "0,0 7x2", "padding: row is 1+2+1+2+1 cols, 0+1+1 rows, got " &
    cellBox(box))
  var texts: seq[string] = @[]
  for c in ctx.commands:
    if c.kind == renderText:
      texts.add cellBox(c.box)
  expect(texts == @["1,0 2x1", "4,0 2x1"], "padding: text cells, got " & texts.join(" | "))

proc borderOf(ctx: Context; id: ElementId): BorderWidth =
  for c in ctx.commands:
    if c.kind == renderBorder and c.box == elementData(ctx, id).box:
      return c.borderWidth
  BorderWidth()

proc testBordersTakeNoSpace() =
  # A border never changes the layout (a focus ring must not move things);
  # only the sides with a free cell around the content keep their line.
  let ctx = fresh(40, 10)
  beginLayout(ctx)
  openElement(ctx, row(gap = 8))
  openElement(ctx, elementId("tight"), row().border(1, rgb(9, 9, 9)))
  textElement(ctx, "hi")
  closeElement(ctx)
  openElement(ctx, elementId("roomy"), row(padding = Padding(left: 8, right: 8,
    top: 16, bottom: 16)).border(1, rgb(9, 9, 9)))
  textElement(ctx, "hi")
  closeElement(ctx)
  openElement(ctx, elementId("sides"), row(padding = Padding(left: 8, right: 8))
    .border(1, rgb(9, 9, 9)))
  textElement(ctx, "hi")
  closeElement(ctx)
  closeElement(ctx)
  endLayout(ctx)
  let tight = elementData(ctx, elementId("tight")).box
  expect(cellBox(tight) == "0,0 2x1", "border: no space taken, got " & cellBox(tight))
  let tb = borderOf(ctx, elementId("tight"))
  expect(tb.left == 0 and tb.right == 0 and tb.top == 1 and tb.bottom == 1,
    "border: no room for sides leaves rules")
  let rb = borderOf(ctx, elementId("roomy"))
  expect(rb.left == 1 and rb.right == 1 and rb.top == 1 and rb.bottom == 1,
    "border: a padded box keeps every side")
  let sb = borderOf(ctx, elementId("sides"))
  expect(sb.left == 1 and sb.right == 1 and sb.top == 0 and sb.bottom == 0,
    "border: one-row box keeps its sides only")

proc testGrowTiles() =
  # Three growers splitting 40 columns tile edge to edge.
  let ctx = fresh(40, 4)
  beginLayout(ctx)
  openElement(ctx, row(width = grow(), height = grow()))
  for i in 0 ..< 3:
    openElement(ctx, elementIdWithIndex("g", uint32(i)),
                col(width = grow(), height = grow()).bg(rgb(1, 1, 1)))
    closeElement(ctx)
  closeElement(ctx)
  endLayout(ctx)
  var edge = 0'f32
  for i in 0 ..< 3:
    let b = elementData(ctx, elementIdWithIndex("g", uint32(i))).box
    expect(onGrid(b), "grow: on grid " & cellBox(b))
    expect(b.x == edge, "grow: child " & $i & " starts where the last ended, " &
      cellBox(b))
    edge = b.x + b.width
  expect(edge == 40 * cellW, "grow: children fill the row, end " & $edge)

proc testSliversKeepACell() =
  # A 2px caret-like box keeps one cell; fixed sizes round to cells.
  let ctx = fresh(40, 10)
  beginLayout(ctx)
  openElement(ctx, row())
  openElement(ctx, elementId("caret"), row(width = fixedPx(2), height = fixedPx(20))
    .bg(rgb(1, 1, 1)))
  closeElement(ctx)
  openElement(ctx, elementId("field"), row(width = fixedPx(100), height = fixedPx(40))
    .bg(rgb(1, 1, 1)))
  closeElement(ctx)
  closeElement(ctx)
  endLayout(ctx)
  expect(cellBox(elementData(ctx, elementId("caret")).box) == "0,0 1x1",
    "sliver: caret 1x1, got " & cellBox(elementData(ctx, elementId("caret")).box))
  # 100/8 = 12.5 -> 12 cols, 40/16 = 2.5 -> 2 rows
  expect(cellBox(elementData(ctx, elementId("field")).box) == "1,0 12x2",
    "sliver: field 12x2, got " & cellBox(elementData(ctx, elementId("field")).box))

proc testCenteringStaysOnGrid() =
  # Centering odd leftovers and floating attach points still land on cells.
  let ctx = fresh(41, 11)
  beginLayout(ctx)
  openElement(ctx, elementId("page"), col(width = grow(), height = grow(),
    alignX = centerX, alignY = centerY))
  openElement(ctx, elementId("box"), row(padding = padAll(8)).bg(rgb(1, 1, 1)))
  textElement(ctx, "centre")
  openElement(ctx, elementId("pop"), row().bg(rgb(2, 2, 2))
    .floating(attachParent, offset = vec2(3, 5),
              points = AttachPoints(element: pointCenterTop,
                                    parent: pointCenterBottom)))
  textElement(ctx, "pop")
  closeElement(ctx)
  closeElement(ctx)
  closeElement(ctx)
  endLayout(ctx)
  expect(allOnGrid(ctx), "centering: every command on the grid")

proc testLineHeightIsOneRow() =
  # A text's lineHeight cannot stretch rows apart on a grid.
  let ctx = fresh(5, 10)
  beginLayout(ctx)
  openElement(ctx, elementId("t"), col(width = grow()))
  textElement(ctx, "aaa bbb cc", TextConfig(lineHeight: 26))
  closeElement(ctx)
  endLayout(ctx)
  var rows: seq[string] = @[]
  for c in ctx.commands:
    if c.kind == renderText:
      rows.add cellBox(c.box)
  expect(rows == @["0,0 3x1", "0,1 3x1", "0,2 2x1"],
    "line height: one row per line, got " & rows.join(" | "))

proc testOffGridUnchanged() =
  # Without a grid nothing snaps.
  let ctx = initContext(size(400, 300))
  ctx.setMeasureText(cells)
  beginLayout(ctx)
  openElement(ctx, elementId("r"), row(padding = padAll(3), width = fixedPx(13)))
  closeElement(ctx)
  endLayout(ctx)
  let b = elementData(ctx, elementId("r")).box
  expect(b.width == 13, "off grid: untouched, got " &
    $b.width & "x" & $b.height)

testPaddingAndGap()
testBordersTakeNoSpace()
testGrowTiles()
testSliversKeepACell()
testCenteringStaysOnGrid()
testLineHeightIsOneRow()
testOffGridUnchanged()

echo "grid: ", passed, " passed, ", failures, " failed"
if failures > 0:
  quit(1)
