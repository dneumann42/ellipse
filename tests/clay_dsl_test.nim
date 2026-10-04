## Tests for the `clay`/`hashId` Nimony plugin DSL.
##
## Compiles real DSL blocks through the template plugin and checks the
## resulting layout, so the plugin expansion is covered end-to-end.

import std/syncio

import clay

var failures = 0
var passed = 0

proc expect(cond: bool, msg: string) =
  if cond:
    passed += 1
  else:
    failures += 1
    echo "FAILED: ", msg

proc nearly(a, b: float32): bool =
  let d = a - b
  d < 0.01'f32 and d > -0.01'f32

proc mono(text: string; cfg: TextConfig): Size =
  Size(width: float32(text.len) * float32(cfg.fontSize), height: float32(cfg.fontSize))

proc main() {.raises.} =
  let ctx = initContext(size(400, 300))
  ctx.setMeasureText(mono)

  beginLayout()
  # named element with a nested auto-id row of coloured cells
  clay "panel", col(width = fixedPx(400), padding = padAll(10), gap = 5):
    clay row(width = grow(), gap = 5):
      clay "a", col(width = fixedPx(100), height = fixedPx(50))
        .withBg(rgb(255, 0, 0))
        .withCorner(4):
        discard
      clay "b", col(width = grow(), height = fixedPx(50)).withBg(rgb(0, 255, 0)):
        discard
    textElement("footer")
  endLayout(ctx)

  # geometry through the DSL (verified against the C original):
  #   panel: 400 wide +10 padding -> row starts at (10,10)
  #   a GROW row fills the column's cross axis (380 inner width),
  #   then a fixed 100 + gap 5 leaves 275 for the grow child b.
  #   (A FIT row would instead wrap tight to 105 and b would get 0.)
  let aBox = elementData(hashId("a"))
  let bBox = elementData(hashId("b"))
  let panelBox = elementData(hashId("panel"))
  expect(aBox.found and bBox.found and panelBox.found, "dsl: named ids resolve")
  expect(nearly(aBox.box.x, 10) and nearly(aBox.box.y, 10), "dsl: padding offset")
  expect(nearly(aBox.box.width, 100), "dsl: fixed width kept")
  expect(nearly(bBox.box.x, 115) and nearly(bBox.box.width, 275),
    "dsl: grow takes the rest, got x=" & $bBox.box.x & " w=" & $bBox.box.width)
  expect(nearly(panelBox.box.height, 91),
    "dsl: panel height = row 50 + gap 5 + footer 16 + padding 20, got " &
    $panelBox.box.height)

  # compile-time hash matches the runtime hash and the ids are distinct
  expect(hashId("a").id == elementId("a").id, "dsl: hashId == elementId")
  expect(hashId("a").id != hashId("b").id, "dsl: distinct labels")
  expect(hashId("a").label == "a", "dsl: label carried through")

  # pointer queries against last frame's boxes
  ctx.setPointerState(vec2(20, 20), true)
  expect(pointerOver(hashId("a")), "dsl: pointer over a")
  expect(not pointerOver(hashId("b")), "dsl: pointer not over b")

  # hovered() inside the declaration of the next frame: "a" was under the
  # pointer in the previous frame, so its id is in the hover list
  beginLayout()
  clay "panel2", col(width = fixedPx(400), padding = padAll(10)):
    clay "a", col(width = fixedPx(100), height = fixedPx(50)):
      expect(hovered(), "dsl: hovered() true for open element under pointer")
  endLayout(ctx)

  # leaf form: body is just `discard`
  beginLayout()
  clay "solid", row(width = fixedPx(30), height = fixedPx(30)).withBg(rgb(1, 2, 3)):
    discard
  endLayout(ctx)
  expect(elementData(hashId("solid")).found, "dsl: element with empty body")
  let cmds = renderCommands()
  var rects = newSeq[RenderCommand]()
  for c in cmds:
    if c.kind == renderRectangle:
      rects.add c
  expect(rects.len == 1 and nearly(rects[0].box.width, 30),
    "dsl: empty body emits its rectangle")

  echo "clay_dsl_test: ", passed, " passed, ", failures, " failed"
  if failures > 0:
    quit 1

when isMainModule:
  try:
    main()
  except ErrorCode:
    echo "clay_dsl_test aborted by ErrorCode"
    quit 1
