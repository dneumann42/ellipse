## Tests for the `widget` Nimony plugin DSL.
##
## Defines real widgets through the plugin and lays them out in a clay
## context, so the definition-time rewrite (proc + colon-call template) and
## the call-site slot binding (named args + trailing block -> closure) are
## covered end-to-end.

import std/syncio

import clay
import ellipse/platform/platform
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

# focusable widgets: `id` and `tabIndex` are injected, registration is
# automatic, the body reads the focus edges
var gains = 0
var activations = 0

widget focusable Chip(label: string):
  openElement(id)
  configureOpenElement(row(width = fixedPx(40), height = fixedPx(20))
    .focusRing(id))
  if gainedFocus(id):
    gains += 1
  if keyActivated(id):
    activations += 1
  closeElement()

# a block slot still binds after an explicit `tabIndex`
widget focusable FocusPanel(title: string, body: proc(): void):
  openElement(id)
  configureOpenElement(col(width = fixedPx(60), height = fixedPx(20)))
  body()
  closeElement()

# a declared `id` is reused, not duplicated
widget focusable OwnId(id: ElementId, label: string):
  openElement(id)
  configureOpenElement(row(width = fixedPx(20), height = fixedPx(20)))
  closeElement()

var panelBodyRan = false

proc chips(ctx: Context) =
  beginLayout()
  clay "chips", row(width = grow(), height = fit(), gap = 4):
    Chip(id = hashId("c1"), label = "a")
    Chip(id = hashId("c2"), label = "b", tabIndex = 2)
    Chip(id = hashId("c3"), label = "c", tabIndex = 1)
    Chip(id = hashId("c4"), label = "d", tabIndex = -1)
    FocusPanel(id = hashId("p1"), title = "t", tabIndex = -1):
      panelBodyRan = true
    OwnId(id = hashId("o1"), label = "o", tabIndex = -1)
  endLayout(ctx)

proc keyFrame(ctx: Context, ev: KeyEvent) =
  ## One frame with `ev` queued: Tab folded in before layout, as `updateUI`.
  pushKeyEvent ev
  beginInputFrame()
  stepFocus(keyEvents())
  chips(ctx)

proc tab(ctx: Context, shift = false) =
  keyFrame(ctx, KeyEvent(kind: kevTab, shift: shift))

var picked = ""

proc bar(ctx: Context) =
  beginLayout()
  toolBar("bar") do():
    menu("File") do():
      if menuItem("Open"): picked = "Open"
      menuSeparator()
      if menuItem("Save"): picked = "Save"
    menu("View") do():
      if menuItem("Zoom"): picked = "Zoom"
  endLayout(ctx)

proc barKey(ctx: Context, kind: KeyEventKind, shift = false) =
  pushKeyEvent KeyEvent(kind: kind, shift: shift)
  beginInputFrame()
  stepFocus(keyEvents())
  bar(ctx)

# --- events: Root(handleEvents) > Outer > Middle > Leaf a, Leaf b ----------------

var evLog: seq[string] = @[]
var fire = ""            ## the leaf that emits Toggled this frame
var pingFrom = ""        ## ... Ping
var loseFrom = ""        ## ... Lost (nobody handles it)
var selfPass = false     ## the leaf's own handler reemits
var middlePass = false
var outerPass = false
var emitResult = false
var keyA = WidgetKey(0'u64)
var keyB = WidgetKey(0'u64)
var keyedKey = WidgetKey(0'u64)
var depthInLeaf = 0

defineEvent Ping(n: int)

widget Leaf(tag: string):
  emits Toggled(on: bool)
  emits Ping
  emits Lost()
  event Toggled(e):
    evLog.add "leaf." & tag
    if selfPass:
      reemit
  if tag == "a":
    keyA = currentWidgetKey()
  else:
    keyB = currentWidgetKey()
  depthInLeaf = eventDepth()
  if fire == tag:
    emitResult = emit Toggled(on: true)
  if pingFrom == tag:
    emit Ping(n: 7)
  if loseFrom == tag:
    emitResult = emit Lost()

widget Middle(body: proc(): void):
  emits Renamed(old: string)
  event Toggled(e):
    evLog.add "middle:" & $e.on
    e.on = false                    # travels on with a reemit
    if middlePass:
      reemit
  event Ping(e):
    evLog.add "middle.ping:" & $e.n
    emit Renamed(old: "ping")       # translated: starts at Outer
  event Renamed:
    evLog.add "middle.renamed"      # never: not its own translation
  body()

widget Outer(body: proc(): void):
  event Toggled(e):
    evLog.add "outer:" & $e.on
    if outerPass:
      reemit
  event Renamed(e):
    evLog.add "outer.renamed:" & e.old
  body()

widget focusable Keyed():
  keyedKey = currentWidgetKey()

proc evTree(ctx: Context, extraFirst = false) =
  beginLayout()
  handleEvents:
    event Toggled(e):
      evLog.add "root:" & $e.on
    Outer:
      Middle:
        if extraFirst:
          Spacer()
        Keyed(id = hashId("keyed"), tabIndex = -1)
        Leaf(tag = "a")
        Leaf(tag = "b")
  endLayout(ctx)

proc evRun(ctx: Context, f = "", ping = "", lose = "", sp = false, mp = false,
           op = false) =
  evLog = @[]
  fire = f
  pingFrom = ping
  loseFrom = lose
  selfPass = sp
  middlePass = mp
  outerPass = op
  emitResult = false
  evTree(ctx)
  fire = ""
  pingFrom = ""
  loseFrom = ""

proc shown(xs: seq[string]): string =
  result = "["
  for i in 0 ..< xs.len:
    if i > 0:
      result.add ", "
    result.add xs[i]
  result.add "]"

proc logIs(want: seq[string]): bool =
  if evLog.len != want.len:
    return false
  for i in 0 ..< want.len:
    if evLog[i] != want[i]:
      return false
  return true

proc renderAct() =
  clay "act", row(width = fixedPx(20), height = fixedPx(20)):
    discard

proc main()  =
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

  # 7. focusable: Tab order = positive tabIndex ascending, then 0s in
  #    layout order; negatives stay off the chain; the chain wraps.
  let c1 = hashId("c1")
  let c2 = hashId("c2")
  let c3 = hashId("c3")
  let c4 = hashId("c4")
  # settle clay's pointer state machine (it starts at `pressedThisFrame`)
  setPointerState(vec2(-100.0, -100.0), false)
  setPointerState(vec2(-100.0, -100.0), false)
  blur()
  chips(ctx)
  expect(panelBodyRan, "focusable: block slot binds after tabIndex")
  expect(elementData(hashId("o1")).found, "focusable: declared id is used")
  expect(focusedId() == 0'u32, "focusable: nothing focused to start")
  gains = 0
  tab(ctx)
  expect(focused(c3), "focusable: Tab from nowhere -> tabIndex 1")
  expect(gains == 1, "focusable: gainedFocus fires on arrival, got " & $gains)
  chips(ctx)
  expect(gains == 1, "focusable: gainedFocus is a one-frame edge")
  let ring = elementData(c3)
  expect(ring.found, "focusable: focused chip laid out")
  tab(ctx)
  expect(focused(c2), "focusable: Tab -> tabIndex 2")
  tab(ctx)
  expect(focused(c1), "focusable: Tab -> tabIndex 0 after the positives")
  tab(ctx)
  expect(focused(c3), "focusable: Tab wraps past the negative-index chip")
  tab(ctx, shift = true)
  expect(focused(c1), "focusable: Shift+Tab walks back, wrapping")
  tab(ctx, shift = true)
  expect(focused(c2), "focusable: Shift+Tab steps back once more")

  # Enter / Space activate the focused widget only
  activations = 0
  keyFrame(ctx, KeyEvent(kind: kevEnter))
  keyFrame(ctx, KeyEvent(kind: kevText, text: " "))
  keyFrame(ctx, KeyEvent(kind: kevText, text: "x"))
  expect(activations == 2, "focusable: Enter and Space activate, got " &
    $activations)

  # click focuses a negative-index chip; Tab moves on from the chain start
  let b4 = elementData(c4).box
  setPointerState(vec2(b4.x + 2.0, b4.y + 2.0), true)
  chips(ctx)
  setPointerState(vec2(b4.x + 2.0, b4.y + 2.0), false)
  chips(ctx)
  expect(focused(c4), "focusable: click focuses a tabIndex -1 widget")
  # a press outside every focusable lets go
  setPointerState(vec2(390.0, 290.0), true)
  chips(ctx)
  setPointerState(vec2(390.0, 290.0), false)
  chips(ctx)
  expect(focusedId() == 0'u32, "focusable: click outside blurs")

  # a holder that never registered (a hand-focused editor) keeps its Tab
  setFocus(hashId("editor"))
  tab(ctx)
  expect(focused(hashId("editor")), "focusable: off-chain holder keeps Tab")
  blur()

  # a frame without focusables leaves an empty chain
  beginLayout()
  Spacer()
  endLayout(ctx)
  stepFocus(@[KeyEvent(kind: kevTab)])
  expect(focusedId() == 0'u32, "focusable: empty chain, Tab is a no-op")

  # 8. toolbar menus: Tab stops; Down opens, arrows walk, Enter picks,
  #    Left/Right hop menus, Tab away closes
  let fileId = elementId("menu.File")
  let viewMenuId = elementId("menu.View")
  let filePop = elementId("menu.File.pop")
  let viewPop = elementId("menu.View.pop")
  blur()
  bar(ctx)
  barKey(ctx, kevTab)
  expect(focused(fileId), "menu: Tab focuses the first menu")
  barKey(ctx, kevDown)
  expect(elementData(filePop).found, "menu: Down opens it")
  barKey(ctx, kevDown)                   # Open -> Save (separator skipped)
  barKey(ctx, kevEnter)
  expect(picked == "Save", "menu: Enter picks the highlighted item, got " &
    picked)
  beginInputFrame()                      # the pick closes it next frame
  bar(ctx)
  expect(not elementData(filePop).found, "menu: picking closes it")
  barKey(ctx, kevEnter)
  barKey(ctx, kevRight)
  expect(focused(viewMenuId), "menu: Right moves to the next menu")
  expect(elementData(viewPop).found and not elementData(filePop).found,
    "menu: Right carries the open state over")
  barKey(ctx, kevEnter)
  expect(picked == "Zoom", "menu: the hopped-to menu highlights its first item")
  beginInputFrame()
  bar(ctx)
  barKey(ctx, kevTab, shift = true)
  expect(focused(fileId), "menu: Shift+Tab walks back along the bar")
  barKey(ctx, kevEnter)
  expect(elementData(filePop).found, "menu: Enter opens it")
  barKey(ctx, kevEscape)
  expect(not elementData(filePop).found and focused(fileId),
    "menu: Escape closes it, focus stays")
  barKey(ctx, kevEnter)
  barKey(ctx, kevTab)
  expect(not elementData(filePop).found, "menu: Tab away closes it")

  # 9. events: self-handle first, catch stops bubbling, reemit carries the
  #    changed payload on, translations start at the parent, unhandled
  #    events reach the log, frames are balanced and keyed stably.
  evRun(ctx, f = "a")
  expect(logIs(@["leaf.a"]), "events: the emitter's own handler runs first " &
    "and consumes, got " & shown(evLog))
  expect(emitResult, "events: emit returns true when consumed")
  evRun(ctx, f = "a", sp = true)
  expect(logIs(@["leaf.a", "middle:true"]),
    "events: reemit hands it to the parent, got " & shown(evLog))
  evRun(ctx, f = "b", sp = true, mp = true)
  expect(logIs(@["leaf.b", "middle:true", "outer:false"]),
    "events: a reemit carries the mutated payload, got " & shown(evLog))
  evRun(ctx, f = "a", sp = true, mp = true, op = true)
  expect(logIs(@["leaf.a", "middle:true", "outer:false", "root:false"]),
    "events: handleEvents catches at the root, got " & shown(evLog))
  var log = eventLog()
  expect(log.len == 1, "events: one record per emit, got " & $log.len)
  if log.len == 1:
    let r = log[0]
    expect(r.name == "Toggled" and r.consumed, "events: record names it")
    expect(r.source == keyA, "events: source is the emitting widget")
    expect(r.path.len == 4 and r.handledBy.len == 4,
      "events: path and handledBy span leaf..root, got " & $r.path.len &
      "/" & $r.handledBy.len)
  expect(eventDepth() == 0, "events: frames balanced after layout")
  expect(depthInLeaf == 4, "events: root, outer, middle, leaf frames open, got " &
    $depthInLeaf)

  evRun(ctx, ping = "b")
  expect(logIs(@["middle.ping:7", "outer.renamed:ping"]),
    "events: a translated emit skips the translator's own handler, got " &
    shown(evLog))
  log = eventLog()
  expect(log.len == 2 and log[0].name == "Renamed" and log[1].name == "Ping",
    "events: nested emit recorded inside its parent's dispatch")

  evRun(ctx, lose = "a")
  expect(not emitResult, "events: emit returns false when nobody consumes")
  log = eventLog()
  expect(log.len == 1 and not log[0].consumed and log[0].handledBy.len == 0 and
    log[0].path.len == 4, "events: an unhandled event is logged unconsumed")

  evRun(ctx)
  let a1 = keyA
  let b1 = keyB
  let k1 = keyedKey
  evRun(ctx)
  expect(keyA == a1 and keyB == b1, "events: widget keys stable across frames")
  expect(keyA != keyB, "events: sibling widgets get distinct keys")
  evLog = @[]
  evTree(ctx, extraFirst = true)
  expect(keyA != a1, "events: positional keys follow the sibling index")
  expect(keyedKey == k1, "events: an element id keys a widget independent " &
    "of its siblings")
  expect(eventLog().len == 0, "events: a quiet frame logs nothing")

  echo "widget_test: ", passed, " passed, ", failures, " failed"
  if failures > 0:
    quit 1

when isMainModule:
  try:
    main()
  except CatchableError:
    echo "widget_test aborted by ErrorCode"
    quit 1
