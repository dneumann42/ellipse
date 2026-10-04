## Tests for the Nimony clay port: layout algorithm behaviour.
##
## Exercises the ported Clay pipeline end-to-end with a deterministic
## monospace measure function (every glyph is `fontSize` wide and tall), so
## all expected geometry is exact float32 arithmetic. Mirrors the assertion
## style of the repo's other tests (expect/summary, `try`/`except ErrorCode`).

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

proc nearly(a, b: float32): bool =
  let d = a - b
  d < 0.01'f32 and d > -0.01'f32

## Deterministic monospace font: width = chars * fontSize (spaces included),
## height = fontSize.
proc mono(text: string; cfg: TextConfig): Size =
  Size(width: float32(text.len) * float32(cfg.fontSize), height: float32(cfg.fontSize))

proc fresh(w, h: float32): Context =
  result = initContext(size(w, h))
  result.setMeasureText(mono)

proc boxOk(c: RenderCommand; x, y, w, h: float32): bool =
  nearly(c.box.x, x) and nearly(c.box.y, y) and nearly(c.box.width, w) and
    nearly(c.box.height, h)

proc textCmds(ctx: Context): seq[RenderCommand] =
  result = @[]
  for c in ctx.commands:
    if c.kind == renderText:
      result.add c

proc kinds(ctx: Context): seq[RenderKind] =
  result = @[]
  for c in ctx.commands:
    result.add c.kind

# ---------------------------------------------------------------------------

proc testBasics() =
  let ctx = fresh(400, 300)
  beginLayout(ctx)
  openElement(ctx, elementId("col"), col(width = fixedPx(200), gap = 4))
  textElement(ctx, "aa")
  textElement(ctx, "bb")
  closeElement(ctx)
  endLayout(ctx)
  let t = ctx.textCmds()
  expect(t.len == 2, "basics: 2 text commands, got " & $t.len)
  expect(boxOk(t[0], 0, 0, 32, 16), "basics: first line at 0,0 32x16")
  expect(boxOk(t[1], 0, 20, 32, 16), "basics: second line at 0,20 (gap 4)")
  let ed = elementData(ctx, elementId("col"))
  expect(ed.found and nearly(ed.box.width, 200) and nearly(ed.box.height, 36),
    "basics: col fixed width 200, height folds 16+16+4")

proc testGrowSplit() =
  let ctx = fresh(400, 300)
  beginLayout(ctx)
  openElement(ctx, row(width = fixedPx(400), height = fixedPx(100)))
  openElement(ctx, col(width = grow()).bg(rgb(1, 1, 1)))
  textElement(ctx, "aa")
  closeElement(ctx)
  openElement(ctx, col(width = grow()).bg(rgb(2, 2, 2)))
  textElement(ctx, "bb")
  closeElement(ctx)
  closeElement(ctx)
  endLayout(ctx)
  # inner content 32+32 = 64; surplus 336 shared equally -> +168 each
  var rects = newSeq[Rect]()
  for c in ctx.commands:
    if c.kind == renderRectangle:
      rects.add c.box
  expect(rects.len == 2, "grow: two container rects")
  if rects.len == 2:
    expect(nearly(rects[0].width, 200) and nearly(rects[1].width, 200),
      "grow: children grow to 200 each, got " & $rects[0].width)
    expect(nearly(rects[0].x, 0) and nearly(rects[1].x, 200),
      "grow: second child starts at 200")

proc testPercent() =
  let ctx = fresh(1000, 300)
  beginLayout(ctx)
  openElement(ctx, row(width = fixedPx(1000), height = fixedPx(100)))
  openElement(ctx, col(width = pct(0.25)).bg(rgb(1, 1, 1)))
  closeElement(ctx)
  openElement(ctx, col(width = grow()).bg(rgb(2, 2, 2)))
  closeElement(ctx)
  closeElement(ctx)
  endLayout(ctx)
  var rects = newSeq[Rect]()
  for c in ctx.commands:
    if c.kind == renderRectangle:
      rects.add c.box
  expect(rects.len == 2, "percent: two rects")
  if rects.len == 2:
    expect(nearly(rects[0].width, 250),
      "percent: quarter of 1000 is 250, got " & $rects[0].width)
    expect(nearly(rects[1].x, 250) and nearly(rects[1].width, 750),
      "percent+grow: grow child takes the remainder")

proc testCompression() =
  let ctx = fresh(300, 300)
  beginLayout(ctx)
  # three texts of preferred width 176 ("hello world" = 11 chars * 16)
  openElement(ctx, row(width = fixedPx(300), height = fixedPx(20)))
  textElement(ctx, "hello world")
  textElement(ctx, "hello world")
  textElement(ctx, "hello world")
  closeElement(ctx)
  endLayout(ctx)
  # deficit 528-300 = 228; tied frontier -> even share -76 each -> 100
  # (above the word-minimum 80), and each 176-wide text now wraps to two lines
  let t = ctx.textCmds()
  expect(t.len == 6, "compress: 3 texts wrap to 6 lines, got " & $t.len)
  if t.len == 6:
    expect(ctx.lineText(t[0]) == "hello" and ctx.lineText(t[1]) == "world",
      "compress: first text wraps on the word boundary")
    for i in 0 ..< 3:
      expect(nearly(t[2*i].box.x, float32(i * 100)),
        "compress: text " & $i & " placed at " & $(i * 100) &
        ", got " & $t[2*i].box.x)
      expect(nearly(t[2*i+1].box.y, 16), "compress: wrapped second line")

proc testWrap() =
  let ctx = fresh(200, 200)
  beginLayout(ctx)
  # parent col 100 wide: text cross-axis clamped to 100 -> wraps to two lines
  openElement(ctx, col(width = fixedPx(100)))
  textElement(ctx, "hello world")
  closeElement(ctx)
  endLayout(ctx)
  let t = ctx.textCmds()
  expect(t.len == 2, "wrap: two lines, got " & $t.len)
  if t.len == 2:
    expect(nearly(t[0].box.width, 80) and nearly(t[0].box.y, 0),
      "wrap: 'hello' 80 wide, trailing space dropped")
    expect(nearly(t[1].box.width, 80) and nearly(t[1].box.y, 16),
      "wrap: 'world' on the second line")
    expect(ctx.lineText(t[0]) == "hello" and ctx.lineText(t[1]) == "world",
      "wrap: line payloads sliced correctly")

proc testNewlines() =
  let ctx = fresh(400, 400)
  beginLayout(ctx)
  openElement(ctx, col(width = fit()))
  textElement(ctx, "ab\ncd")
  closeElement(ctx)
  endLayout(ctx)
  let t = ctx.textCmds()
  expect(t.len == 2, "newlines: explicit break makes two lines")
  if t.len == 2:
    expect(ctx.lineText(t[0]) == "ab" and ctx.lineText(t[1]) == "cd",
      "newlines: payloads")
    expect(nearly(t[1].box.y, 16), "newlines: second line below first")

proc testAlignAndJustify() =
  let ctx = fresh(400, 400)
  beginLayout(ctx)
  # row 400x200 with a single 100x50 fixed child: center on both axes
  openElement(ctx, row(width = fixedPx(400), height = fixedPx(200),
    alignX = centerX, alignY = centerY))
  openElement(ctx, col(width = fixedPx(100), height = fixedPx(50))
    .bg(rgb(1, 2, 3)))
  closeElement(ctx)
  closeElement(ctx)
  endLayout(ctx)
  var rs = newSeq[RenderCommand]()
  for c in ctx.commands:
    if c.kind == renderRectangle:
      rs.add c
  expect(rs.len == 1, "justify: one rectangle for the child")
  if rs.len == 1:
    expect(boxOk(rs[0], 150, 75, 100, 50),
      "justify: centered in 400x200 -> (150,75), got (" &
      $rs[0].box.x & "," & $rs[0].box.y & ")")

  # right justify on the main axis
  let ctx2 = fresh(400, 400)
  beginLayout(ctx2)
  openElement(ctx2, row(width = fixedPx(400), height = fixedPx(200), alignX = right))
  openElement(ctx2, col(width = fixedPx(100), height = fixedPx(50))
    .bg(rgb(1, 2, 3)))
  closeElement(ctx2)
  closeElement(ctx2)
  endLayout(ctx2)
  for c in ctx2.commands:
    if c.kind == renderRectangle:
      expect(nearly(c.box.x, 300), "justify right: child at 400-100")

proc testBorder() =
  let ctx = fresh(200, 200)
  beginLayout(ctx)
  openElement(ctx, col(width = fit(), height = fit()).border(2, rgb(9, 9, 9)))
  textElement(ctx, "xy")
  closeElement(ctx)
  endLayout(ctx)
  var sawBorder = false
  for c in ctx.commands:
    if c.kind == renderBorder:
      sawBorder = true
      expect(c.borderWidth.left == 2 and nearly(c.borderColor.a, 255),
        "border: widths and colour carried to the command")
  expect(sawBorder, "border: BORDER command emitted")

proc testClipAndScroll() =
  let ctx = fresh(200, 200)
  let scrollId = elementId("scroll")
  # frame 1: a clipped column (100 tall) with 300 of content
  beginLayout(ctx)
  openElement(ctx, scrollId)
  configureOpenElement(ctx, col(height = fixedPx(100), width = fixedPx(100))
    .clip(true, true, childOffset = ctx.currentScrollOffset()))
  openElement(ctx, col(width = fixedPx(100), height = fixedPx(300))
    .bg(rgb(4, 5, 6)))
  closeElement(ctx)
  closeElement(ctx)
  endLayout(ctx)
  var ks = ctx.kinds()
  expect(renderClipStart in ks and renderClipEnd in ks, "clip: scissor pair emitted")
  let sd = ctx.scrollContainerData(scrollId)
  expect(sd.found, "clip: scroll container registered")
  expect(nearly(sd.contentDimensions.height, 300), "clip: content size published")
  expect(nearly(sd.containerDimensions.height, 100), "clip: viewport size")

  # pointer over the container, wheel scroll down 1 line: momentum applies
  ctx.setPointerState(vec2(50, 50), false)
  ctx.updateScrollContainers(false, vec2(0, -1), 0.016'f32)
  let sd2 = ctx.scrollContainerData(scrollId)
  expect(nearly(sd2.position.y, -10),
    "scroll: wheel delta scaled by 10, got " & $sd2.position.y)

  # frame 2: same declaration picks up the new offset via currentScrollOffset
  beginLayout(ctx)
  openElement(ctx, scrollId)
  configureOpenElement(ctx, col(height = fixedPx(100), width = fixedPx(100))
    .clip(true, true, childOffset = ctx.currentScrollOffset()))
  openElement(ctx, col(width = fixedPx(100), height = fixedPx(300))
    .bg(rgb(4, 5, 6)))
  closeElement(ctx)
  closeElement(ctx)
  endLayout(ctx)
  var inner = ElementData()
  for c in ctx.commands:
    if c.kind == renderRectangle:
      inner.box = c.box
  expect(nearly(inner.box.y, -10),
    "scroll: child rendered at scrolled offset, got " & $inner.box.y)

  # clamp: never scroll past the content. One wheel tick per frame; the
  # container must be re-declared each frame (Clay culls stale scroll data).
  for i in 0 ..< 40:
    beginLayout(ctx)
    openElement(ctx, scrollId)
    configureOpenElement(ctx, col(height = fixedPx(100), width = fixedPx(100))
      .clip(true, true, childOffset = ctx.currentScrollOffset()))
    openElement(ctx, col(width = fixedPx(100), height = fixedPx(300))
      .bg(rgb(4, 5, 6)))
    closeElement(ctx)
    closeElement(ctx)
    endLayout(ctx)
    ctx.setPointerState(vec2(50, 50), false)
    ctx.updateScrollContainers(false, vec2(0, -10), 0.016'f32)
  let sd3 = ctx.scrollContainerData(scrollId)
  expect(nearly(sd3.position.y, -200),
    "scroll: clamped to -(content-viewport), got " & $sd3.position.y)

proc testFloating() =
  let ctx = fresh(400, 400)
  let anchorId = elementId("anchor")
  let tipId = elementId("tip")
  beginLayout(ctx)
  openElement(ctx, row(width = fixedPx(400), height = fixedPx(400)))
  openElement(ctx, anchorId, col(width = fixedPx(50), height = fixedPx(50)))
  closeElement(ctx)
  # tooltip: left-top of tip attaches to right-center of anchor, offset (2, 0)
  openElement(ctx, tipId)
  configureOpenElement(ctx,
    col(width = fixedPx(30), height = fixedPx(10))
      .bg(rgb(7, 7, 7))
      .floating(attachElementId,
        offset = vec2(2, 0),
        points = AttachPoints(element: pointLeftTop, parent: pointRightCenter),
        parentId = anchorId.id))
  closeElement(ctx)
  closeElement(ctx)
  endLayout(ctx)
  var tipBox = Rect()
  var seen = 0
  for c in ctx.commands:
    if c.kind == renderRectangle:
      seen += 1
      tipBox = c.box
  expect(seen == 1, "floating: exactly one rect (the tooltip)")
  # anchor is (0,0,50,50); parent right-center = (50, 25); element left-top
  # subtracts nothing; + offset -> (52, 25)
  expect(nearly(tipBox.x, 52) and nearly(tipBox.y, 25) and
    nearly(tipBox.width, 30) and nearly(tipBox.height, 10),
    "floating: attach-point mapping -> (52,25), got (" & $tipBox.x & "," &
    $tipBox.y & ")")

proc testFloatingViewportFit() =
  # (a) A panel under a top anchor that fits: position untouched by the fit.
  block:
    let ctx = fresh(400, 400)
    let anchorId = elementId("anchor")
    let popId = elementId("pop")
    beginLayout(ctx)
    openElement(ctx, row(width = fixedPx(400), height = fixedPx(400)))
    openElement(ctx, anchorId, col(width = fixedPx(50), height = fixedPx(20)))
    closeElement(ctx)
    openElement(ctx, popId)
    configureOpenElement(ctx,
      col(width = fixedPx(60), height = fixedPx(40))
        .floating(attachElementId, offset = vec2(0, 6),
          points = AttachPoints(element: pointLeftTop, parent: pointLeftBottom),
          parentId = anchorId.id, fitViewport = true))
    closeElement(ctx)
    closeElement(ctx)
    endLayout(ctx)
    let b = ctx.elementMap.getOrDefault(popId.id, MapItem(elementIndex: -1)).box
    expect(nearly(b.x, 0) and nearly(b.y, 26),
      "fit: panel that fits is not moved, got (" & $b.x & "," & $b.y & ")")

  # (b) Bottom-edge anchor: the panel would hang off-screen, so it flips up,
  # keeping the 6px gap above the anchor instead of below.
  block:
    let ctx = fresh(400, 400)
    let anchorId = elementId("anchor")
    let popId = elementId("pop")
    beginLayout(ctx)
    openElement(ctx, col(width = fixedPx(400), height = fixedPx(400),
                         alignY = bottom))
    openElement(ctx, anchorId, row(width = fixedPx(50), height = fixedPx(20)))
    closeElement(ctx)
    openElement(ctx, popId)
    configureOpenElement(ctx,
      col(width = fixedPx(60), height = fixedPx(40))
        .floating(attachElementId, offset = vec2(0, 6),
          points = AttachPoints(element: pointLeftTop, parent: pointLeftBottom),
          parentId = anchorId.id, fitViewport = true))
    closeElement(ctx)
    closeElement(ctx)
    endLayout(ctx)
    let b = ctx.elementMap.getOrDefault(popId.id, MapItem(elementIndex: -1)).box
    # anchor is (0,380,50,20); flipped: panel bottom = anchor top - 6 gap,
    # so y = 380 - 6 - 40 = 334.
    expect(nearly(b.y, 334) and nearly(b.x, 0),
      "fit: panel flips above the anchor, got (" & $b.x & "," & $b.y & ")")

  # (c) Right-edge anchor: attach is left-to-left so a horizontal flip is a
  # no-op; the shift clamps the panel inside with the fit margin.
  block:
    let ctx = fresh(400, 400)
    let anchorId = elementId("anchor")
    let popId = elementId("pop")
    beginLayout(ctx)
    openElement(ctx, row(width = fixedPx(400), height = fixedPx(400),
                         alignX = right))
    openElement(ctx, anchorId, col(width = fixedPx(50), height = fixedPx(20)))
    closeElement(ctx)
    openElement(ctx, popId)
    configureOpenElement(ctx,
      col(width = fixedPx(60), height = fixedPx(40))
        .floating(attachElementId, offset = vec2(0, 6),
          points = AttachPoints(element: pointLeftTop, parent: pointLeftBottom),
          parentId = anchorId.id, fitViewport = true))
    closeElement(ctx)
    closeElement(ctx)
    endLayout(ctx)
    let b = ctx.elementMap.getOrDefault(popId.id, MapItem(elementIndex: -1)).box
    expect(nearly(b.x, 332) and nearly(b.y, 26),
      "fit: panel shifts inside the right edge, got (" & $b.x & "," & $b.y & ")")

proc testZIndexOrdering() =
  let ctx = fresh(400, 400)
  beginLayout(ctx)
  # main tree first, but a high-z floating root must paint last
  openElement(ctx, elementId("hi"))
  configureOpenElement(ctx, col(width = fixedPx(10), height = fixedPx(10))
    .bg(rgb(1, 1, 1))
    .floating(attachRoot, zIndex = 5))
  closeElement(ctx)
  openElement(ctx, elementId("lo"), col(width = fixedPx(10), height = fixedPx(10))
    .bg(rgb(2, 2, 2)))
  closeElement(ctx)
  endLayout(ctx)
  var lastColorA: float32 = -1
  var count = 0
  for c in ctx.commands:
    if c.kind == renderRectangle:
      count += 1
      lastColorA = c.fill.r
  expect(count == 2, "zindex: two rects")
  expect(nearly(lastColorA, 1), "zindex: higher-z element painted last")

proc testPointerStates() =
  let ctx = fresh(400, 400)
  let btnId = elementId("btn")
  beginLayout(ctx)
  openElement(ctx, btnId, row(width = fixedPx(100), height = fixedPx(50)))
  closeElement(ctx)
  endLayout(ctx)
  # prime: an up frame settles the state machine into a released state
  ctx.setPointerState(vec2(10, 10), false)
  expect(ctx.pointerData().state == releasedThisFrame, "pointer: initial release edge")
  ctx.setPointerState(vec2(10, 10), false)
  expect(ctx.pointerData().state == released, "pointer: held release")
  ctx.setPointerState(vec2(10, 10), true)
  expect(ctx.pointerData().state == pressedThisFrame, "pointer: press edge")
  expect(ctx.pointerOver(btnId), "pointer: over the button")
  ctx.setPointerState(vec2(10, 10), true)
  expect(ctx.pointerData().state == pressed, "pointer: held press")
  ctx.setPointerState(vec2(300, 300), false)
  expect(ctx.pointerData().state == releasedThisFrame, "pointer: release edge")
  expect(not ctx.pointerOver(btnId), "pointer: not over after moving away")

proc testErrors() =
  let ctx = fresh(400, 400)
  beginLayout(ctx)
  openElement(ctx, elementId("dup"), row(width = fixedPx(10), height = fixedPx(10)))
  closeElement(ctx)
  openElement(ctx, elementId("dup"), row(width = fixedPx(10), height = fixedPx(10)))
  closeElement(ctx)
  openElement(ctx, row(width = pct(2)))   # percent over 1
  closeElement(ctx)
  endLayout(ctx)
  let errs = ctx.takeErrors()
  var sawDup = false
  var sawPct = false
  for e in errs:
    if e.kind == duplicateId: sawDup = true
    if e.kind == percentOverOne: sawPct = true
  expect(sawDup, "errors: duplicate id reported")
  expect(sawPct, "errors: percent over 1 reported")

  let ctx2 = fresh(400, 400)
  beginLayout(ctx2)
  openElement(ctx2, row(width = fixedPx(10)))  # never closed
  endLayout(ctx2)
  var sawUnbalanced = false
  for e in ctx2.takeErrors():
    if e.kind == unbalancedOpenClose: sawUnbalanced = true
  expect(sawUnbalanced, "errors: unbalanced open/close reported")

proc testHashStability() =
  # ids must match Clay's own hash for the same label
  expect(hashString("Clay__RootContainer", 0) == elementId("Clay__RootContainer").id,
    "hash: elementId agrees with hashString")
  expect(elementId("tab").id != elementId("tab2").id, "hash: distinct labels")
  let a = elementIdWithIndex("item", 3)
  let b = elementIdWithIndex("item", 4)
  expect(a.id != b.id and a.offset == 3 and b.offset == 4,
    "hash: indexed ids differ and carry the offset")

proc main() {.raises.} =
  testBasics()
  testGrowSplit()
  testPercent()
  testCompression()
  testWrap()
  testNewlines()
  testAlignAndJustify()
  testBorder()
  testClipAndScroll()
  testFloating()
  testFloatingViewportFit()
  testZIndexOrdering()
  testPointerStates()
  testErrors()
  testHashStability()
  echo "clay_test: ", passed, " passed, ", failures, " failed"
  if failures > 0:
    quit 1

when isMainModule:
  try:
    main()
  except ErrorCode:
    echo "clay_test aborted by ErrorCode"
    quit 1
