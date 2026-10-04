## Tests for the `widget` Nimony plugin DSL.
##
## Defines real widgets through the plugin and lays them out in a clay
## context, so the definition-time rewrite (proc + colon-call template) and
## the call-site slot binding (named args + trailing block -> closure) are
## covered end-to-end.

import std/syncio

import clay
import ellipse_ui/ui

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

# --- the definitions from docs/ui.org ------------------------------------------

widget Container(body: proc(): void):
  clay "app", col(width = grow(), height = grow(), alignX = centerX):
    body()

widget PageWrapper(title: string, rightAction: proc(): void, body: proc(): void):
  clay "page", col(width = grow(), height = grow(), alignX = centerX)
      .bg(bgColor):
    clay "toolbar", row(width = grow(), height = fixedPx(48), gap = 4,
                        padding = padAll(4)).bg(panelBg):
      textElement(title, TextConfig(fontSize: 20))
      clay col(width = grow(), height = grow()):
        discard
      rightAction()
    Container:
      body()

widget Spacer():
  clay "spacer", row(width = grow(), height = fixedPx(4)):
    discard

# a slot the implementation calls twice: real closure calls, not splicing
var slotCalls = 0

proc countSlot() =
  slotCalls += 1

widget Twice(body: proc(): void):
  body()
  body()

proc renderAct() =
  clay "act", row(width = fixedPx(20), height = fixedPx(20)):
    discard

proc main() {.raises.} =
  let ctx = initContext(size(400, 300))
  ctx.setMeasureText(mono)

  # 1. plain widget call: trailing block fills the `body` slot
  beginLayout()
  Container:
    clay "inner", row(width = fixedPx(100), height = fixedPx(50)):
      discard
  endLayout(ctx)
  let app1 = elementData(hashId("app"))
  let inner = elementData(hashId("inner"))
  expect(app1.found, "widget: Container opens its clay block")
  expect(nearly(app1.box.width, 400) and nearly(app1.box.height, 300),
    "widget: grow sizing reaches the window, got " & $app1.box.width &
    "x" & $app1.box.height)
  expect(inner.found and nearly(inner.box.width, 100),
    "widget: body statements render inside the widget")

  # 2. slots: the `rightAction` closure runs inside the toolBar do-block,
  #    the trailing block reaches `body`, which the widget forwards as a
  #    closure call through a nested Container invocation.
  beginLayout()
  PageWrapper(title = "Home", rightAction = renderAct):
    clay "content", row(width = fixedPx(60), height = fixedPx(30)):
      discard
  endLayout(ctx)
  let page = elementData(hashId("page"))
  let toolbar = elementData(hashId("toolbar"))
  let act = elementData(hashId("act"))
  let content = elementData(hashId("content"))
  expect(page.found, "widget: PageWrapper root laid out")
  expect(toolbar.found and nearly(toolbar.box.height, 48),
    "widget: toolbar slot region laid out")
  expect(act.found and nearly(act.box.width, 20),
    "widget: rightAction closure runs in the toolbar")
  expect(content.found, "widget: body closure runs through nested Container")
  let app2 = elementData(hashId("app"))
  expect(app2.found and nearly(app2.box.width, 400),
    "widget: nested Container still grows full width")

  # 3. defaulted slots: omit the trailing block -> `emptySlot()` runs
  beginLayout()
  PageWrapper(title = "Plain", rightAction = renderAct)
  endLayout(ctx)
  expect(elementData(hashId("page")).found, "widget: omitted body slot defaults")

  # 4. the generated proc is the widget proper: call it directly with do()
  beginLayout()
  PageWrapperImpl(title = "Direct", rightAction = renderAct) do():
    clay "direct", row(width = fixedPx(10), height = fixedPx(10)):
      discard
  endLayout(ctx)
  expect(elementData(hashId("direct")).found, "widget: Impl proc callable with do:")

  # 5. slots are real closures: an implementation may call one twice, and
  #    the Impl proc accepts a plain proc value as the slot argument.
  slotCalls = 0
  Twice:
    countSlot()
  expect(slotCalls == 2, "widget: slot called per invocation site, got " &
    $slotCalls)
  slotCalls = 0
  TwiceImpl(countSlot)
  expect(slotCalls == 2, "widget: Impl proc takes a proc value directly")

  # 6. parameterless widget: `widget Spacer():`
  beginLayout()
  Spacer()
  endLayout(ctx)
  expect(elementData(hashId("spacer")).found, "widget: parameterless definition")

  echo "widget_test: ", passed, " passed, ", failures, " failed"
  if failures > 0:
    quit 1

when isMainModule:
  try:
    main()
  except ErrorCode:
    echo "widget_test aborted by ErrorCode"
    quit 1
