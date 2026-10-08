import std/[syncio, strutils, tables, os, envvars]
import owl/[objects, evaluator, modules, errors]
import ellipse_ui/app

# The ellipse_ui toolkit as owl sees it: layout elements, the stock
# widgets, the widget event frames and the app loop. This is a bridge, not
# a second toolkit: every widget here is the Nim one, and owl widgets
# (`widget` in gui.owl) open the same event frames as Nim widgets, so an
# event bubbles through both alike. ellipse_ui knows nothing of owl.
#
# Ids are strings, hashed with clay's `elementId`; an id that comes back
# from Nim (an event's `id`) is its label again. Colours are theme palette
# names ("accent", "panel", "text", ...), "#rrggbb[aa]" or records of r g
# b (a). Sizes are numbers (pixels) or the records `grow`, `fit` and `pct`
# give.
#
# Owl code runs inside Nim callbacks (slots, event handlers) that cannot
# raise. A failure there is kept and raised again once the Nim call it ran
# under returns (`rethrow`), so clay elements and event frames still close
# in order.

# --- errors across Nim callbacks ------------------------------------------------

var pending = owlError(RuntimeError, "")
var hasPending = false

proc stash() =
  if not hasPending:
    hasPending = true
    pending = currentError

proc rethrow() {.raises.} =
  if hasPending:
    hasPending = false
    raiseError(pending)

proc runQuietly(fn: Object) =
  try:
    discard invoke(fn, @[])
  except:
    stash()

proc slotOf(fn: Object): proc () {.closure.} =
  result = proc () {.closure.} =
    runQuietly(fn)

# --- arguments --------------------------------------------------------------------

type
  Args = object
    pos: seq[Object]
    named: Table[string, Object]
    blk: seq[Object]
    env: ref Environment

proc parseArgs(env: ref Environment, args: seq[Object], bodyStart: int): Args {.raises.} =
  # Positional values, (name = value) options and the `:` block's forms.
  result = Args(pos: @[], named: initTable[string, Object](), blk: @[], env: env)
  let stop = if bodyStart >= 0 and bodyStart < args.len: bodyStart else: args.len
  for i in 0 ..< stop:
    let a = args[i]
    if isPair(a) and isSymbol(car(a)):
      result.named[toSymbol(car(a))] = eval(cdr(a), env)
    else:
      result.pos.add eval(a, env)
  for i in stop ..< args.len:
    result.blk.add args[i]

proc has(a: Args, name: string): bool = a.named.hasKey(name)

proc arg(a: Args, name: string, at: int): Object =
  # The option `name`, else positional `at` (-1: none), else nothing.
  if a.named.hasKey(name):
    result = a.named.getOrDefault(name, nothing())
  elif at >= 0 and at < a.pos.len:
    result = a.pos[at]
  else:
    result = nothing()

proc need(a: Args, name: string, at: int, what: string): Object {.raises.} =
  result = arg(a, name, at)
  if isNothing(result) and not a.has(name):
    err(what & " needs " & name)

proc textOf(o: Object, what: string): string {.raises.} =
  if isString(o):
    result = toStr(o)
  elif isNothing(o):
    result = ""
  else:
    result = stringify(o)

proc numOf(o: Object, what: string): float64 {.raises.} =
  if not isNumber(o):
    err(what & " needs a number, got " & stringify(o))
  toNumber(o)

proc numOr(a: Args, name: string, at: int, fallback: float64, what: string): float64 {.raises.} =
  let v = arg(a, name, at)
  result = if isNothing(v): fallback else: numOf(v, what)

proc strOr(a: Args, name: string, at: int, fallback: string, what: string): string {.raises.} =
  let v = arg(a, name, at)
  result = if isNothing(v): fallback else: textOf(v, what)

proc idOf(o: Object): ElementId =
  if isString(o) and toStr(o).len > 0:
    result = elementId(toStr(o))
  elif isNumber(o):
    result = elementIdFromId(uint32(toNumber(o)))
  else:
    result = ElementId()

proc idValue(id: ElementId): Object =
  if id.label.len > 0:
    result = str(id.label)
  else:
    result = number(float64(id.id))

proc stringsOf(o: Object, what: string): seq[string] {.raises.} =
  if not isList(o):
    err(what & " needs a list of strings, got " & stringify(o))
  result = @[]
  for x in toSeq(o):
    result.add textOf(x, what)

proc blockFn(a: Args): Object =
  # The `:` block as a fun over the caller's scope.
  newCommand("", newSeq[Object](), a.blk, a.env, true)

proc runBlock(a: Args): Object {.raises.} =
  result = evalForms(newEnvironment(a.env), a.blk)

# --- values: colours, sizes, spacing ---------------------------------------------

proc hexDigit(c: char): int =
  case c
  of '0'..'9': ord(c) - ord('0')
  of 'a'..'f': ord(c) - ord('a') + 10
  of 'A'..'F': ord(c) - ord('A') + 10
  else: 0

proc paletteColor(name: string, found: var bool): Color =
  let p = activeTheme.palette
  found = true
  case name
  of "bg": result = p.bg
  of "panel": result = p.panelBg
  of "panel-border": result = p.panelBorder
  of "button": result = p.buttonBg
  of "button-hover": result = p.buttonHoverBg
  of "button-press": result = p.buttonPressBg
  of "field": result = p.fieldBg
  of "selected": result = p.selectedBg
  of "accent": result = p.accent
  of "text": result = p.textColor
  of "dim": result = p.dimColor
  of "label": result = p.labelColor
  of "on-accent": result = p.onAccent
  of "shadow": result = p.shadow
  of "none", "transparent": result = Color()
  else:
    found = false
    result = Color()

proc colorOf(o: Object): Color {.raises.} =
  if isString(o):
    let s = toStr(o)
    if s.len > 0 and s[0] == '#' and (s.len == 7 or s.len == 9):
      let a = if s.len == 9: hexDigit(s[7]) * 16 + hexDigit(s[8]) else: 255
      return rgb(float32(hexDigit(s[1]) * 16 + hexDigit(s[2])),
        float32(hexDigit(s[3]) * 16 + hexDigit(s[4])),
        float32(hexDigit(s[5]) * 16 + hexDigit(s[6])), float32(a))
    var found = false
    result = paletteColor(s, found)
    if not found:
      err("unknown colour " & s & " (a palette name such as accent, panel, text, or #rrggbb)")
  elif isRecord(o):
    let a = if hasField(o, "a"): toNumber(field(o, "a")) else: 255.0
    result = rgb(float32(toNumber(field(o, "r"))), float32(toNumber(field(o, "g"))),
      float32(toNumber(field(o, "b"))), float32(a))
  else:
    err("a colour is a palette name, #rrggbb or a record of r g b, got " & stringify(o))
    result = Color()

proc sizingOf(o: Object): SizingAxis {.raises.} =
  var v = o
  if isCommand(v):
    v = invoke(v, @[])
  if isNumber(v):
    result = fixedPx(float32(toNumber(v)))
  elif isString(v) and toStr(v) == "grow":
    result = grow()
  elif isString(v) and toStr(v) == "fit":
    result = fit()
  elif isRecord(v):
    let kind = toStr(field(v, "sizing"))
    let lo = float32(toNumber(field(v, "min")))
    let hi = float32(toNumber(field(v, "max")))
    case kind
    of "grow": result = grow(lo, hi)
    of "fit": result = fit(lo, hi)
    of "pct": result = pct(float32(toNumber(field(v, "fraction"))))
    else:
      err("unknown sizing " & stringify(v))
      result = fit()
  else:
    err("a size is a number, grow, fit or (pct f), got " & stringify(v))
    result = fit()

proc sizingOr(a: Args, name: string, at: int, fallback: SizingAxis): SizingAxis {.raises.} =
  let v = arg(a, name, at)
  result = if isNothing(v): fallback else: sizingOf(v)

proc paddingOf(o: Object): Padding {.raises.} =
  if isNumber(o):
    result = padAll(int(toNumber(o)))
  elif isList(o) and itemCount(o) == 2:
    let x = int(toNumber(itemAt(o, 0)))
    let y = int(toNumber(itemAt(o, 1)))
    result = Padding(left: x, right: x, top: y, bottom: y)
  elif isList(o) and itemCount(o) == 4:
    result = Padding(left: int(toNumber(itemAt(o, 0))), right: int(toNumber(itemAt(o, 1))),
      top: int(toNumber(itemAt(o, 2))), bottom: int(toNumber(itemAt(o, 3))))
  elif isRecord(o):
    result = Padding(left: int(toNumber(field(o, "left"))), right: int(toNumber(field(o, "right"))),
      top: int(toNumber(field(o, "top"))), bottom: int(toNumber(field(o, "bottom"))))
  else:
    err("padding is a number, [] x y, [] left right top bottom or a record, got " & stringify(o))
    result = Padding()

proc alignXOf(o: Object): AlignX {.raises.} =
  case textOf(o, "align-x")
  of "left", "": result = left
  of "center": result = centerX
  of "right": result = right
  else:
    err("align-x is left, center or right, got " & stringify(o))
    result = left

proc alignYOf(o: Object): AlignY {.raises.} =
  case textOf(o, "align-y")
  of "top", "": result = top
  of "center": result = centerY
  of "bottom": result = bottom
  else:
    err("align-y is top, center or bottom, got " & stringify(o))
    result = top

proc textSizeOf(o: Object, fallback: uint16): uint16 {.raises.} =
  result = if isNothing(o): fallback else: uint16(numOf(o, "size"))

# --- layout -----------------------------------------------------------------------

proc axes(o: Object): (bool, bool) {.raises.} =
  if isBoolean(o):
    result = (false, toBool(o))
  else:
    case textOf(o, "scroll")
    of "x": result = (true, false)
    of "y": result = (false, true)
    of "both": result = (true, true)
    else:
      err("scroll and clip take true, x, y or both, got " & stringify(o))
      result = (false, false)

proc declOf(a: Args, vertical: bool): ElementDeclaration {.raises.} =
  # A row or column declaration from its options. Built while the element
  # is open, so hover-bg and scroll can read this element's state.
  let w = sizingOr(a, "width", -1, fit())
  let h = sizingOr(a, "height", -1, fit())
  let gap = int(numOr(a, "gap", -1, 0.0, "gap"))
  let pad = if a.has("padding"): paddingOf(arg(a, "padding", -1)) else: Padding()
  let ax = alignXOf(arg(a, "align-x", -1))
  let ay = alignYOf(arg(a, "align-y", -1))
  result = if vertical:
    col(gap = gap, padding = pad, width = w, height = h, alignX = ax, alignY = ay)
  else:
    row(gap = gap, padding = pad, width = w, height = h, alignX = ax, alignY = ay)
  if a.has("bg"):
    result = result.bg(colorOf(arg(a, "bg", -1)))
  if a.has("hover-bg") and hovered():
    result = result.bg(colorOf(arg(a, "hover-bg", -1)))
  if a.has("corner"):
    result = result.corner(float32(numOr(a, "corner", -1, 0.0, "corner")))
  if a.has("border"):
    let c = if a.has("border-color"): colorOf(arg(a, "border-color", -1))
      else: activeTheme.palette.panelBorder
    result = result.border(int(numOr(a, "border", -1, 1.0, "border")), c)
  if a.has("clip"):
    let (x, y) = axes(arg(a, "clip", -1))
    result = result.clip(x, y)
  if a.has("scroll"):
    let (x, y) = axes(arg(a, "scroll", -1))
    result = result.clip(x, y, currentScrollOffset())
  if a.has("focus-ring"):
    result = result.focusRing(idOf(arg(a, "focus-ring", -1)))

proc element(env: ref Environment, args: seq[Object], bodyStart: int,
    vertical: bool): Object {.raises.} =
  let a = parseArgs(env, args, bodyStart)
  var idv = arg(a, "id", -1)
  if isNothing(idv) and a.pos.len > 0 and isString(a.pos[0]):
    idv = a.pos[0]
  let id = idOf(idv)
  if id.id != 0'u32:
    openElement(id)
  else:
    openElement()
  result = nothing()
  try:
    configureOpenElement(declOf(a, vertical))
    result = runBlock(a)
    if a.has("scroll") and id.id != 0'u32:
      scrollbar(elementId(id.label & ".bar"), id)
  finally:
    closeElement()

proc rowBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # row ("id") (options...): children left to right.
  element(env, args, bodyStart, false)

proc columnBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # column ("id") (options...): children top to bottom.
  element(env, args, bodyStart, true)

proc fontIdOf(o: Object): uint16 {.raises.} =
  # (font = "mono") picks the monospaced font; anything else the UI font.
  if isNothing(o): 0'u16
  elif textOf(o, "font") == "mono": MonoFont
  elif textOf(o, "font") == "ui" or textOf(o, "font") == "": 0'u16
  else:
    err("font is ui or mono, got " & stringify(o))
    0'u16

proc textBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # text value (size = n) (color = c)
  let a = parseArgs(env, args, bodyStart)
  let t = activeTheme
  let c = if a.has("color"): colorOf(arg(a, "color", -1)) else: t.palette.textColor
  let wrap = if a.has("wrap") and not toBool(arg(a, "wrap", -1)): noWrap else: wordWrap
  textElement(textOf(arg(a, "value", 0), "text"),
    TextConfig(fontSize: textSizeOf(arg(a, "size", 1), t.text.control), color: c,
      fontId: fontIdOf(arg(a, "font", -1)), wrap: wrap))
  nothing()

proc sizingRecord(kind: string, a: Args): Object {.raises.} =
  record(@[pair(symbol("sizing"), str(kind)),
    pair(symbol("min"), number(numOr(a, "min", 0, 0.0, kind))),
    pair(symbol("max"), number(numOr(a, "max", 1, 0.0, kind)))])

proc growBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # grow (min) (max): fill the space left over.
  sizingRecord("grow", parseArgs(env, args, bodyStart))

proc fitBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # fit (min) (max): hug the content.
  sizingRecord("fit", parseArgs(env, args, bodyStart))

proc pctBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # pct f: a fraction of the parent.
  let a = parseArgs(env, args, bodyStart)
  record(@[pair(symbol("sizing"), str("pct")), pair(symbol("min"), number(0.0)),
    pair(symbol("max"), number(0.0)),
    pair(symbol("fraction"), number(numOr(a, "fraction", 0, 1.0, "pct")))])

# --- interaction --------------------------------------------------------------------

proc idArg(env: ref Environment, args: seq[Object], what: string): ElementId {.raises.} =
  if args.len < 1:
    err(what & " needs an id")
  idOf(eval(args[0], env))

proc hoveredBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # hovered (id): the pointer is over the element (or the open one).
  if args.len == 0:
    return boolean(hovered())
  boolean(pointerOver(idArg(env, args, "hovered")))

proc clickedBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  boolean(clickedIn(idArg(env, args, "clicked")))

proc activatedBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # activated id: Enter or Space on it while it holds focus.
  boolean(keyActivated(idArg(env, args, "activated")))

proc focusedBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  boolean(focused(idArg(env, args, "focused")))

proc gainedFocusBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  boolean(gainedFocus(idArg(env, args, "gained-focus")))

proc pressingBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  boolean(pressing(idArg(env, args, "pressing")))

proc registerFocusBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # register-focus id (tab-index): a Tab stop this frame.
  let a = parseArgs(env, args, bodyStart)
  registerFocus(idOf(arg(a, "id", 0)), int(numOr(a, "tab-index", 1, 0.0, "register-focus")))
  nothing()

proc setFocusBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  setFocus(idArg(env, args, "set-focus"))
  nothing()

proc keyPressedBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # key-pressed "ctrl+s": the chord was pressed this frame.
  if args.len != 1:
    err("key-pressed needs a chord such as ctrl+s")
  boolean(pressed(textOf(eval(args[0], env), "key-pressed")))

proc requestFrameBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  requestFrame()
  nothing()

proc refreshDueBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # refresh-due label ms: true on the first frame and then every ms, and
  # the loop wakes for it (a clock's tick).
  let a = parseArgs(env, args, bodyStart)
  boolean(refreshDue(textOf(arg(a, "label", 0), "refresh-due"),
    every(int(numOr(a, "ms", 1, 1000.0, "refresh-due")))))

proc invalidateBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  if args.len == 0:
    invalidate()
  else:
    invalidate(textOf(eval(args[0], env), "invalidate"))
  nothing()

# --- events ---------------------------------------------------------------------------
#
# Owl events and Nim events share the frames and the dispatcher of
# ellipse_ui/events. An owl event's payload is an owl record, its kind the
# hash of "owl.<Name>". The stock events of ellipse_ui (Pressed, Toggled,
# ...) keep their Nim kinds and payloads: an owl handler sees them as
# records, and an owl `emit` of one builds the Nim payload, so Nim handlers
# catch it too.

proc fnv1a(s: string): uint32 =
  result = 2166136261'u32
  for c in s:
    result = (result xor uint32(ord(c))) * 16777619'u32

var eventFields = initTable[string, seq[string]]()

proc stockFields(name: string): seq[string] =
  case name
  of "Pressed": @["id"]
  of "Toggled": @["id", "on"]
  of "Picked": @["id", "index"]
  of "TextChanged", "TextCommitted": @["id", "text"]
  of "NumberChanged": @["id", "value"]
  of "MenuPicked": @["label"]
  of "SelectionChanged": @["id", "selection"]
  of "IntChanged": @["id", "value"]
  else: @["-"]

proc isStock(name: string): bool = stockFields(name) != @["-"]

proc kindOf(name: string): EventKind =
  case name
  of "Pressed": result = PressedKind
  of "Toggled": result = ToggledKind
  of "Picked": result = PickedKind
  of "TextChanged": result = TextChangedKind
  of "TextCommitted": result = TextCommittedKind
  of "NumberChanged": result = NumberChangedKind
  of "MenuPicked": result = MenuPickedKind
  of "SelectionChanged": result = SelectionChangedKind
  of "IntChanged": result = IntChangedKind
  else:
    result = EventKind(fnv1a("owl." & name))
    registerEventKind(result, "owl." & name)

proc selectionValue(sel: Selection): Object =
  # A multiselect's bitmask as the list of chosen indices.
  var items: seq[Object] = @[]
  for i in 0 ..< 64:
    if (sel and (1'u64 shl uint64(i))) != 0'u64:
      items.add number(float64(i))
  list(items)

proc selectionOf(o: Object): Selection =
  result = Selection(0)
  for x in toSeq(o):
    if isNumber(x):
      let i = int(toNumber(x))
      if i >= 0 and i < 64:
        result = result or (1'u64 shl uint64(i))

proc fieldOf(r: Object, name: string): Object = field(r, name)

proc toRecord(name: string, payload: pointer): Object =
  case name
  of "Pressed":
    let p = cast[ptr Pressed](payload)
    result = record(@[pair(symbol("id"), idValue(p[].id))])
  of "Toggled":
    let p = cast[ptr Toggled](payload)
    result = record(@[pair(symbol("id"), idValue(p[].id)), pair(symbol("on"), boolean(p[].on))])
  of "Picked":
    let p = cast[ptr Picked](payload)
    result = record(@[pair(symbol("id"), idValue(p[].id)),
      pair(symbol("index"), number(float64(p[].index)))])
  of "TextChanged":
    let p = cast[ptr TextChanged](payload)
    result = record(@[pair(symbol("id"), idValue(p[].id)), pair(symbol("text"), str(p[].text))])
  of "TextCommitted":
    let p = cast[ptr TextCommitted](payload)
    result = record(@[pair(symbol("id"), idValue(p[].id)), pair(symbol("text"), str(p[].text))])
  of "NumberChanged":
    let p = cast[ptr NumberChanged](payload)
    result = record(@[pair(symbol("id"), idValue(p[].id)), pair(symbol("value"), number(p[].value))])
  of "MenuPicked":
    let p = cast[ptr MenuPicked](payload)
    result = record(@[pair(symbol("label"), str(p[].label))])
  of "SelectionChanged":
    let p = cast[ptr SelectionChanged](payload)
    result = record(@[pair(symbol("id"), idValue(p[].id)),
      pair(symbol("selection"), selectionValue(p[].selection))])
  of "IntChanged":
    let p = cast[ptr IntChanged](payload)
    result = record(@[pair(symbol("id"), idValue(p[].id)),
      pair(symbol("value"), number(float64(p[].value)))])
  else:
    result = cast[ptr Object](payload)[]

proc fromRecord(name: string, r: Object, payload: pointer) =
  # Write a handler's (possibly changed) record back into the payload.
  case name
  of "Pressed":
    cast[ptr Pressed](payload)[].id = idOf(fieldOf(r, "id"))
  of "Toggled":
    let p = cast[ptr Toggled](payload)
    p[].id = idOf(fieldOf(r, "id"))
    p[].on = toBool(fieldOf(r, "on"))
  of "Picked":
    let p = cast[ptr Picked](payload)
    p[].id = idOf(fieldOf(r, "id"))
    p[].index = int(toNumber(fieldOf(r, "index")))
  of "TextChanged":
    let p = cast[ptr TextChanged](payload)
    p[].id = idOf(fieldOf(r, "id"))
    p[].text = toStr(fieldOf(r, "text"))
  of "TextCommitted":
    let p = cast[ptr TextCommitted](payload)
    p[].id = idOf(fieldOf(r, "id"))
    p[].text = toStr(fieldOf(r, "text"))
  of "NumberChanged":
    let p = cast[ptr NumberChanged](payload)
    p[].id = idOf(fieldOf(r, "id"))
    p[].value = toNumber(fieldOf(r, "value"))
  of "MenuPicked":
    cast[ptr MenuPicked](payload)[].label = toStr(fieldOf(r, "label"))
  of "SelectionChanged":
    let p = cast[ptr SelectionChanged](payload)
    p[].id = idOf(fieldOf(r, "id"))
    p[].selection = selectionOf(fieldOf(r, "selection"))
  of "IntChanged":
    let p = cast[ptr IntChanged](payload)
    p[].id = idOf(fieldOf(r, "id"))
    p[].value = int(toNumber(fieldOf(r, "value")))
  else:
    cast[ptr Object](payload)[] = r

proc emitNamed(name: string, r: Object): bool =
  case name
  of "Pressed": result = emit(Pressed(id: idOf(fieldOf(r, "id"))))
  of "Toggled": result = emit(Toggled(id: idOf(fieldOf(r, "id")), on: toBool(fieldOf(r, "on"))))
  of "Picked": result = emit(Picked(id: idOf(fieldOf(r, "id")), index: int(toNumber(fieldOf(r, "index")))))
  of "TextChanged": result = emit(TextChanged(id: idOf(fieldOf(r, "id")), text: toStr(fieldOf(r, "text"))))
  of "TextCommitted": result = emit(TextCommitted(id: idOf(fieldOf(r, "id")), text: toStr(fieldOf(r, "text"))))
  of "NumberChanged": result = emit(NumberChanged(id: idOf(fieldOf(r, "id")), value: toNumber(fieldOf(r, "value"))))
  of "MenuPicked": result = emit(MenuPicked(label: toStr(fieldOf(r, "label"))))
  of "SelectionChanged": result = emit(SelectionChanged(id: idOf(fieldOf(r, "id")),
    selection: selectionOf(fieldOf(r, "selection"))))
  of "IntChanged": result = emit(IntChanged(id: idOf(fieldOf(r, "id")),
    value: int(toNumber(fieldOf(r, "value")))))
  else:
    var payload = r
    result = dispatchEvent(kindOf(name), name, addr payload)

type
  OwlHandler = object
    kind: EventKind
    name: string
    fn: Object

proc handlerOf(hs: seq[OwlHandler]): EventHandler =
  result = proc (kind: EventKind, payload: pointer): EventFlow {.closure.} =
    result = efPass
    for h in hs:
      if h.kind == kind:
        try:
          let changed = invoke(h.fn, @[toRecord(h.name, payload)])
          if isRecord(changed):
            fromRecord(h.name, changed, payload)
        except:
          stash()
        return efConsumed

proc handlersOf(list: Object): seq[OwlHandler] {.raises.} =
  # [] ([] "Name" fn)...
  result = @[]
  for h in toSeq(list):
    if not isList(h) or itemCount(h) != 2:
      err("event handlers are [] name fun pairs, got " & stringify(h))
    let name = textOf(itemAt(h, 0), "event")
    result.add OwlHandler(kind: kindOf(name), name: name, fn: itemAt(h, 1))

proc withFrame(name: string, id: ElementId, hs: seq[OwlHandler], body: Object,
    env: ref Environment, forms: seq[Object]): Object {.raises.} =
  var kinds: seq[EventKind] = @[]
  for h in hs:
    kinds.add h.kind
  pushEventFrame(name, fnv1a("owl." & name), id.id, handlerOf(hs), kinds)
  result = nothing()
  try:
    if isCommand(body):
      result = invoke(body, @[])
    else:
      result = evalForms(newEnvironment(env), forms)
  finally:
    popEventFrame()
  rethrow()

proc widgetFrameBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # widget-frame name id handlers body: run body inside a widget's event
  # frame (what `widget` generates; see gui.owl).
  if args.len != 4:
    err("widget-frame needs a name, an id, handlers and a body")
  let name = textOf(eval(args[0], env), "widget-frame")
  let id = idOf(eval(args[1], env))
  let hs = handlersOf(eval(args[2], env))
  withFrame(name, id, hs, eval(args[3], env), env, @[])

proc eventSection(form: Object): bool =
  isList(form) and itemCount(form) >= 2 and toSymbol(itemAt(form, 0)) == "event" and
    bodyStart(form) >= 2

proc callReemit(form: Object): Object =
  # As in the Nim macro, a bare `reemit` statement is the call (reemit),
  # in the handler's body and in the blocks inside it.
  if toSymbol(form) == "reemit":
    return list(@[form])
  let bs = bodyStart(form)
  if isList(form) and bs >= 1:
    var items = toSeq(form)
    for i in bs ..< items.len:
      items[i] = callReemit(items[i])
    return list(items, bs)
  form

proc handlerFromSection(form: Object, env: ref Environment): OwlHandler {.raises.} =
  # (event Name e: body...) -> a fun of e that gives e back after the body,
  # so `set e (with e ...)` changes what a reemit passes on.
  let it = toSeq(form)
  let bs = bodyStart(form)
  let name = toSymbol(it[1])
  if name.len == 0:
    err("event needs a name: event Name e:")
  let param = if bs > 2: it[2] else: symbol("e")
  var body: seq[Object] = @[]
  for i in bs ..< it.len:
    body.add callReemit(it[i])
  body.add param
  OwlHandler(kind: kindOf(name), name: name, fn: newCommand("", @[param], body, env, true))

proc handleEventsBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # handle-events: a block whose `event Name e:` sections catch what the
  # rest of the block emits and does not consume.
  var hs: seq[OwlHandler] = @[]
  var rest: seq[Object] = @[]
  let start = if bodyStart >= 0: bodyStart else: args.len
  for i in start ..< args.len:
    if eventSection(args[i]):
      hs.add handlerFromSection(args[i], env)
    else:
      rest.add args[i]
  withFrame("handle-events", ElementId(), hs, nothing(), env, rest)

proc defineEventBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # define-event "Name" ([] "field" ...): declare an event's fields.
  if args.len != 2:
    err("define-event needs a name and a list of field names")
  let name = textOf(eval(args[0], env), "define-event")
  if isStock(name):
    err(name & " is a stock event of ellipse_ui; its fields are " & stockFields(name).join(", "))
  eventFields[name] = stringsOf(eval(args[1], env), "define-event")
  discard kindOf(name)
  nothing()

proc knownEventBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  let name = textOf(eval(args[0], env), "known-event")
  boolean(isStock(name) or eventFields.hasKey(name))

proc emitBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # emit Name (field = value)...: send an event up the widget frames; true
  # when a handler consumed it.
  if args.len < 1:
    err("emit needs an event name")
  var name = toSymbol(args[0])
  if name.len == 0:
    name = textOf(eval(args[0], env), "emit")
  var fields: seq[Object] = @[]
  for i in 1 ..< args.len:
    let f = args[i]
    if not isPair(f) or not isSymbol(car(f)):
      err("emit " & name & " needs (field = value) forms")
    fields.add pair(car(f), eval(cdr(f), env))
  let r = record(fields)
  let declared = if isStock(name): stockFields(name) else: eventFields.getOrDefault(name, @[])
  if isStock(name) or eventFields.hasKey(name):
    for f in fieldNames(r):
      if f notin declared:
        err("event " & name & " has no field " & f & " (it has " & declared.join(", ") & ")")
  result = boolean(emitNamed(name, r))
  rethrow()

proc reemitBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # reemit, inside an event handler: pass the event on, changed or not.
  reemit()
  nothing()

proc eventLogBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # event-log: the last complete frame's emits.
  var records: seq[Object] = @[]
  let log = eventLog()
  for rec in log:
    records.add record(@[pair(symbol("name"), str(rec.name)),
      pair(symbol("consumed"), boolean(rec.consumed)),
      pair(symbol("passed"), number(float64(rec.path.len))),
      pair(symbol("handled"), number(float64(rec.handledBy.len)))])
  list(records)

# --- the stock widgets ------------------------------------------------------------------

proc buttonBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # button id label (width) (height) (font-size) (tab-index): true when pressed.
  let a = parseArgs(env, args, bodyStart)
  let r = button(id = idOf(need(a, "id", 0, "button")),
    label = textOf(arg(a, "label", 1), "button"),
    width = sizingOr(a, "width", -1, fit()), height = sizingOr(a, "height", -1, fit()),
    fontSize = uint16(numOr(a, "font-size", -1, 0.0, "button")),
    tabIndex = int(numOr(a, "tab-index", -1, 0.0, "button")))
  rethrow()
  boolean(r)

proc checkboxBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # checkbox id label checked: the state to store back.
  let a = parseArgs(env, args, bodyStart)
  let r = checkbox(id = idOf(need(a, "id", 0, "checkbox")),
    label = textOf(arg(a, "label", 1), "checkbox"), checked = toBool(arg(a, "checked", 2)),
    tabIndex = int(numOr(a, "tab-index", -1, 0.0, "checkbox")))
  rethrow()
  boolean(r)

proc switchBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # switch id label on: the state to store back.
  let a = parseArgs(env, args, bodyStart)
  let r = switch(id = idOf(need(a, "id", 0, "switch")),
    label = textOf(arg(a, "label", 1), "switch"), on = toBool(arg(a, "on", 2)),
    tabIndex = int(numOr(a, "tab-index", -1, 0.0, "switch")))
  rethrow()
  boolean(r)

proc textFieldBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # text-field id text (placeholder) (width): the text to store back.
  let a = parseArgs(env, args, bodyStart)
  let r = textField(id = idOf(need(a, "id", 0, "text-field")),
    text = textOf(arg(a, "text", 1), "text-field"),
    placeholder = strOr(a, "placeholder", 2, "", "text-field"),
    width = sizingOr(a, "width", -1, grow()),
    tabIndex = int(numOr(a, "tab-index", -1, 0.0, "text-field")))
  rethrow()
  str(r)

proc multilineFieldBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # multiline-field id text (placeholder) (rows) (max-lines): the text to
  # store back.
  let a = parseArgs(env, args, bodyStart)
  let r = multilineField(id = idOf(need(a, "id", 0, "multiline-field")),
    text = textOf(arg(a, "text", 1), "multiline-field"),
    placeholder = strOr(a, "placeholder", 2, "", "multiline-field"),
    rows = int(numOr(a, "rows", -1, 4.0, "multiline-field")),
    maxLines = int(numOr(a, "max-lines", -1, 8.0, "multiline-field")),
    width = sizingOr(a, "width", -1, grow()),
    tabIndex = int(numOr(a, "tab-index", -1, 0.0, "multiline-field")))
  rethrow()
  str(r)

proc numberFieldBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # number-field id value (step) (min) (max) (whole): the number to store back.
  let a = parseArgs(env, args, bodyStart)
  let r = numberField(id = idOf(need(a, "id", 0, "number-field")),
    value = numOr(a, "value", 1, 0.0, "number-field"),
    step = numOr(a, "step", 2, 1.0, "number-field"),
    minVal = numOr(a, "min", 3, -1.0e9, "number-field"),
    maxVal = numOr(a, "max", 4, 1.0e9, "number-field"),
    whole = toBool(arg(a, "whole", -1)),
    width = sizingOr(a, "width", -1, grow()),
    tabIndex = int(numOr(a, "tab-index", -1, 0.0, "number-field")))
  rethrow()
  number(r)

proc comboBoxBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # combo-box id options selected (placeholder): the index to store back.
  let a = parseArgs(env, args, bodyStart)
  let r = comboBox(id = idOf(need(a, "id", 0, "combo-box")),
    options = stringsOf(arg(a, "options", 1), "combo-box"),
    selected = int(numOr(a, "selected", 2, -1.0, "combo-box")),
    placeholder = strOr(a, "placeholder", 3, "", "combo-box"),
    width = sizingOr(a, "width", -1, grow()),
    tabIndex = int(numOr(a, "tab-index", -1, 0.0, "combo-box")))
  rethrow()
  number(float64(r))

proc tabStripBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # tab-strip id labels selected: the tab to store back.
  let a = parseArgs(env, args, bodyStart)
  let r = tabStrip(id = idOf(need(a, "id", 0, "tab-strip")),
    labels = stringsOf(arg(a, "labels", 1), "tab-strip"),
    selected = int(numOr(a, "selected", 2, 0.0, "tab-strip")),
    tabIndex = int(numOr(a, "tab-index", -1, 0.0, "tab-strip")))
  rethrow()
  number(float64(r))

proc textLinkBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # text-link id text: true when clicked.
  let a = parseArgs(env, args, bodyStart)
  let r = textLink(id = idOf(need(a, "id", 0, "text-link")),
    text = textOf(arg(a, "text", 1), "text-link"),
    tabIndex = int(numOr(a, "tab-index", -1, 0.0, "text-link")))
  rethrow()
  boolean(r)

proc menuItemBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # menu-item label (shortcut): true when chosen.
  let a = parseArgs(env, args, bodyStart)
  let r = menuItem(label = textOf(arg(a, "label", 0), "menu-item"),
    shortcut = strOr(a, "shortcut", 1, "", "menu-item"))
  rethrow()
  boolean(r)

proc oneText(env: ref Environment, args: seq[Object], what: string): string {.raises.} =
  if args.len < 1:
    err(what & " needs a text")
  textOf(eval(args[0], env), what)

proc headingBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # heading text (level)
  let a = parseArgs(env, args, bodyStart)
  heading(textOf(arg(a, "text", 0), "heading"), int(numOr(a, "level", 1, 1.0, "heading")))
  nothing()

proc labelBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  label(oneText(env, args, "label"))
  nothing()

proc bodyTextBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  bodyText(oneText(env, args, "body-text"))
  nothing()

proc captionBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  caption(oneText(env, args, "caption"))
  nothing()

proc overlineBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  overline(oneText(env, args, "overline"))
  nothing()

proc badgeBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  badge(oneText(env, args, "badge"))
  nothing()

proc spacerBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # spacer: push the next sibling to the far edge.
  spacer()
  nothing()

proc menuSeparatorBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  menuSeparator()
  nothing()

proc slotArg(a: Args, name: string): Object =
  # A slot: the named fun, else the `:` block, else nothing to draw.
  if a.has(name):
    result = arg(a, name, -1)
  elif a.blk.len > 0:
    result = blockFn(a)
  else:
    result = nothing()

proc slotProc(fn: Object): proc () {.closure.} =
  if isCommand(fn):
    result = slotOf(fn)
  else:
    result = proc () {.closure.} =
      discard

proc cardBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # card title (actions = fun): body -- a framed panel.
  let a = parseArgs(env, args, bodyStart)
  let actions = if a.has("actions"): arg(a, "actions", -1) else: nothing()
  CardImpl(textOf(arg(a, "title", 0), "card"), slotProc(actions), slotProc(slotArg(a, "body")))
  rethrow()
  nothing()

proc statCardBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # stat-card label value (hint)
  let a = parseArgs(env, args, bodyStart)
  StatCardImpl(textOf(arg(a, "label", 0), "stat-card"), textOf(arg(a, "value", 1), "stat-card"),
    strOr(a, "hint", 2, "", "stat-card"))
  rethrow()
  nothing()

proc cardRowBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  let a = parseArgs(env, args, bodyStart)
  CardRowImpl(slotProc(slotArg(a, "body")))
  rethrow()
  nothing()

proc sectionBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # section title: body -- a titled group.
  let a = parseArgs(env, args, bodyStart)
  SectionImpl(textOf(arg(a, "title", 0), "section"), slotProc(slotArg(a, "body")))
  rethrow()
  nothing()

proc proseBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  let a = parseArgs(env, args, bodyStart)
  ProseImpl(slotProc(slotArg(a, "body")))
  rethrow()
  nothing()

proc labeledBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # labeled label: control -- a field label above its control.
  let a = parseArgs(env, args, bodyStart)
  LabeledImpl(textOf(arg(a, "label", 0), "labeled"), slotProc(slotArg(a, "control")))
  rethrow()
  nothing()

proc tabbedViewBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # tabbed-view id tabs: body -- the body reads (active-tab id).
  let a = parseArgs(env, args, bodyStart)
  TabbedViewImpl(idOf(need(a, "id", 0, "tabbed-view")),
    stringsOf(arg(a, "tabs", 1), "tabbed-view"), slotProc(slotArg(a, "body")))
  rethrow()
  nothing()

proc activeTabBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  number(float64(activeTab(idArg(env, args, "active-tab"))))

proc toolBarBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # tool-bar id: menus -- a menu bar.
  let a = parseArgs(env, args, bodyStart)
  toolBar(textOf(arg(a, "id", 0), "tool-bar"), slotProc(slotArg(a, "body")))
  rethrow()
  nothing()

proc menuBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # menu label: items -- one menu of a tool-bar.
  let a = parseArgs(env, args, bodyStart)
  menu(textOf(arg(a, "label", 0), "menu"), slotProc(slotArg(a, "body")))
  rethrow()
  nothing()


proc intNumberFieldBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # int-number-field id value (step) (min) (max): the whole number to store back.
  let a = parseArgs(env, args, bodyStart)
  let r = intNumberField(id = idOf(need(a, "id", 0, "int-number-field")),
    value = int(numOr(a, "value", 1, 0.0, "int-number-field")),
    step = int(numOr(a, "step", 2, 1.0, "int-number-field")),
    minVal = int(numOr(a, "min", 3, -1.0e9, "int-number-field")),
    maxVal = int(numOr(a, "max", 4, 1.0e9, "int-number-field")),
    width = sizingOr(a, "width", -1, grow()),
    tabIndex = int(numOr(a, "tab-index", -1, 0.0, "int-number-field")))
  rethrow()
  number(float64(r))

proc multiSelectBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # multi-select id options selection (placeholder): the chosen indices,
  # as a list, to store back.
  let a = parseArgs(env, args, bodyStart)
  let sel = arg(a, "selection", 2)
  var mask = Selection(0)
  if isList(sel):
    mask = selectionOf(sel)
  let r = multiSelect(id = idOf(need(a, "id", 0, "multi-select")),
    options = stringsOf(arg(a, "options", 1), "multi-select"),
    selection = mask,
    placeholder = strOr(a, "placeholder", 3, "Select...", "multi-select"),
    width = sizingOr(a, "width", -1, grow()),
    tabIndex = int(numOr(a, "tab-index", -1, 0.0, "multi-select")))
  rethrow()
  selectionValue(r)

proc listItem(env: ref Environment, args: seq[Object], bodyStart: int,
    card: bool): Object {.raises.} =
  let a = parseArgs(env, args, bodyStart)
  let label = textOf(arg(a, "label", 0), "list-row")
  let index = uint32(numOr(a, "index", 1, 0.0, "list-row"))
  openElement(localIdWithIndex(label, index))
  result = nothing()
  try:
    if card:
      configureOpenElement(listCardDecl(sizingOr(a, "width", 2, fixedPx(150))))
    else:
      configureOpenElement(listRowDecl())
    result = runBlock(a)
  finally:
    closeElement()

proc listRowBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # list-row label index: body -- a themed hover row of a list panel.
  listItem(env, args, bodyStart, false)

proc listCardBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # list-card label index (width): body -- a themed hover card of a strip.
  listItem(env, args, bodyStart, true)

proc setScrollPositionBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # set-scroll-position id (x) (y): scroll a container (to the top by default).
  let a = parseArgs(env, args, bodyStart)
  setScrollPosition(idOf(arg(a, "id", 0)),
    vec2(float32(numOr(a, "x", 1, 0.0, "set-scroll-position")),
      float32(numOr(a, "y", 2, 0.0, "set-scroll-position"))))
  nothing()

proc focusAtBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # focus-at id text (pos): give a text field focus, the caret at pos
  # (default: the end).
  let a = parseArgs(env, args, bodyStart)
  let t = textOf(arg(a, "text", 1), "focus-at")
  focusAt(idOf(arg(a, "id", 0)), t, int(numOr(a, "pos", 2, float64(t.len), "focus-at")))
  nothing()

# --- themes --------------------------------------------------------------------------
#
# (theme) is the live theme as records: palette (colours), text (sizes),
# radii, metrics and scrollbar, named as in ellipse_ui/theme in kebab case.
# set-theme overrides starts from the default theme and changes what
# overrides names, so a preset is just the differences.

proc colorValue(c: Color): Object =
  record(@[pair(symbol("r"), number(float64(c.r))), pair(symbol("g"), number(float64(c.g))),
    pair(symbol("b"), number(float64(c.b))), pair(symbol("a"), number(float64(c.a)))])

proc entry(name: string, v: Object): Object = pair(symbol(name), v)
proc num(v: float32): Object = number(float64(v))
proc num(v: int): Object = number(float64(v))
proc num(v: uint16): Object = number(float64(v))

proc paletteValue(p: Palette): Object =
  record(@[entry("bg", colorValue(p.bg)), entry("panel", colorValue(p.panelBg)),
    entry("panel-border", colorValue(p.panelBorder)), entry("button", colorValue(p.buttonBg)),
    entry("button-hover", colorValue(p.buttonHoverBg)),
    entry("button-press", colorValue(p.buttonPressBg)), entry("field", colorValue(p.fieldBg)),
    entry("selected", colorValue(p.selectedBg)), entry("accent", colorValue(p.accent)),
    entry("text", colorValue(p.textColor)), entry("dim", colorValue(p.dimColor)),
    entry("label", colorValue(p.labelColor)), entry("on-accent", colorValue(p.onAccent)),
    entry("shadow", colorValue(p.shadow))])

proc setPalette(p: var Palette, r: Object) {.raises.} =
  for f in recordFields(r):
    let c = colorOf(cdr(f))
    case toSymbol(car(f))
    of "bg": p.bg = c
    of "panel": p.panelBg = c
    of "panel-border": p.panelBorder = c
    of "button": p.buttonBg = c
    of "button-hover": p.buttonHoverBg = c
    of "button-press": p.buttonPressBg = c
    of "field": p.fieldBg = c
    of "selected": p.selectedBg = c
    of "accent": p.accent = c
    of "text": p.textColor = c
    of "dim": p.dimColor = c
    of "label": p.labelColor = c
    of "on-accent": p.onAccent = c
    of "shadow": p.shadow = c
    else: err("the palette has no colour " & toSymbol(car(f)))

proc textValue(t: TextSizes): Object =
  record(@[entry("h1", num(t.h1)), entry("h2", num(t.h2)), entry("h3", num(t.h3)),
    entry("h4", num(t.h4)), entry("h5", num(t.h5)), entry("h6", num(t.h6)),
    entry("button", num(t.button)), entry("menu", num(t.menu)),
    entry("control", num(t.control)), entry("option", num(t.option)),
    entry("chevron", num(t.chevron)), entry("card-title", num(t.cardTitle)),
    entry("stat-label", num(t.statLabel)), entry("stat-value", num(t.statValue)),
    entry("stat-hint", num(t.statHint)), entry("label", num(t.label)),
    entry("caption", num(t.caption)), entry("overline", num(t.overline)),
    entry("badge", num(t.badge))])

proc setText(t: var TextSizes, r: Object) {.raises.} =
  for f in recordFields(r):
    let v = uint16(numOf(cdr(f), "set-theme"))
    case toSymbol(car(f))
    of "h1": t.h1 = v
    of "h2": t.h2 = v
    of "h3": t.h3 = v
    of "h4": t.h4 = v
    of "h5": t.h5 = v
    of "h6": t.h6 = v
    of "button": t.button = v
    of "menu": t.menu = v
    of "control": t.control = v
    of "option": t.option = v
    of "chevron": t.chevron = v
    of "card-title": t.cardTitle = v
    of "stat-label": t.statLabel = v
    of "stat-value": t.statValue = v
    of "stat-hint": t.statHint = v
    of "label": t.label = v
    of "caption": t.caption = v
    of "overline": t.overline = v
    of "badge": t.badge = v
    else: err("the text sizes have no " & toSymbol(car(f)))

proc radiiValue(r: Radii): Object =
  record(@[entry("button", num(r.button)), entry("field", num(r.field)),
    entry("check", num(r.check)), entry("tick", num(r.tick)), entry("inner", num(r.inner)),
    entry("item", num(r.item)), entry("panel", num(r.panel)), entry("popover", num(r.popover)),
    entry("popover-shadow", num(r.popoverShadow)), entry("tab", num(r.tab)),
    entry("tab-panel", num(r.tabPanel)), entry("card", num(r.card)), entry("pill", num(r.pill)),
    entry("switch", num(r.switch)), entry("switch-knob", num(r.switchKnob))])

proc setRadii(r: var Radii, o: Object) {.raises.} =
  for f in recordFields(o):
    let v = float32(numOf(cdr(f), "set-theme"))
    case toSymbol(car(f))
    of "button": r.button = v
    of "field": r.field = v
    of "check": r.check = v
    of "tick": r.tick = v
    of "inner": r.inner = v
    of "item": r.item = v
    of "panel": r.panel = v
    of "popover": r.popover = v
    of "popover-shadow": r.popoverShadow = v
    of "tab": r.tab = v
    of "tab-panel": r.tabPanel = v
    of "card": r.card = v
    of "pill": r.pill = v
    of "switch": r.switch = v
    of "switch-knob": r.switchKnob = v
    else: err("the radii have no " & toSymbol(car(f)))

proc metricsValue(m: Metrics): Object =
  record(@[entry("control-height", num(m.controlHeight)),
    entry("toolbar-height", num(m.toolbarHeight)), entry("check-size", num(m.checkSize)),
    entry("tick-size", num(m.tickSize)), entry("switch-width", num(m.switchWidth)),
    entry("switch-height", num(m.switchHeight)), entry("stepper-size", num(m.stepperSize)),
    entry("text-row-height", num(m.textRowHeight)),
    entry("pad-button", num(m.padButton)), entry("pad-card", num(m.padCard)),
    entry("pad-panel", num(m.padPanel)), entry("pad-minor", num(m.padMinor)),
    entry("pad-item", num(m.padItem)), entry("gap-card", num(m.gapCard)),
    entry("gap-card-row", num(m.gapCardRow)), entry("gap-prose", num(m.gapProse)),
    entry("gap-tight", num(m.gapTight)), entry("gap-list", num(m.gapList)),
    entry("border-raised", num(m.borderRaised)),
    entry("border-hairline", num(m.borderHairline)), entry("border-tab", num(m.borderTab)),
    entry("press-offset", num(m.pressOffset))])

proc setMetrics(m: var Metrics, o: Object) {.raises.} =
  for f in recordFields(o):
    let v = numOf(cdr(f), "set-theme")
    case toSymbol(car(f))
    of "control-height": m.controlHeight = float32(v)
    of "toolbar-height": m.toolbarHeight = float32(v)
    of "check-size": m.checkSize = float32(v)
    of "tick-size": m.tickSize = float32(v)
    of "switch-width": m.switchWidth = float32(v)
    of "switch-height": m.switchHeight = float32(v)
    of "stepper-size": m.stepperSize = float32(v)
    of "text-row-height": m.textRowHeight = float32(v)
    of "pad-button": m.padButton = int(v)
    of "pad-card": m.padCard = int(v)
    of "pad-panel": m.padPanel = int(v)
    of "pad-minor": m.padMinor = int(v)
    of "pad-item": m.padItem = int(v)
    of "gap-card": m.gapCard = int(v)
    of "gap-card-row": m.gapCardRow = int(v)
    of "gap-prose": m.gapProse = int(v)
    of "gap-tight": m.gapTight = int(v)
    of "gap-list": m.gapList = int(v)
    of "border-raised": m.borderRaised = int(v)
    of "border-hairline": m.borderHairline = int(v)
    of "border-tab": m.borderTab = int(v)
    of "press-offset": m.pressOffset = int(v)
    else: err("the metrics have no " & toSymbol(car(f)))

proc scrollbarValue(b: ScrollbarStyle): Object =
  record(@[entry("width", num(b.width)), entry("margin", num(b.margin)),
    entry("radius", num(b.radius)), entry("min-thumb", num(b.minThumb)),
    entry("track", colorValue(b.track)), entry("thumb", colorValue(b.thumb)),
    entry("thumb-hot", colorValue(b.thumbHot))])

proc setScrollbar(b: var ScrollbarStyle, o: Object) {.raises.} =
  for f in recordFields(o):
    let v = cdr(f)
    case toSymbol(car(f))
    of "width": b.width = float32(numOf(v, "set-theme"))
    of "margin": b.margin = float32(numOf(v, "set-theme"))
    of "radius": b.radius = float32(numOf(v, "set-theme"))
    of "min-thumb": b.minThumb = float32(numOf(v, "set-theme"))
    of "track": b.track = colorOf(v)
    of "thumb": b.thumb = colorOf(v)
    of "thumb-hot": b.thumbHot = colorOf(v)
    else: err("the scrollbar style has no " & toSymbol(car(f)))

proc themeBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # (theme): the live theme as records.
  let t = activeTheme
  record(@[entry("palette", paletteValue(t.palette)), entry("text", textValue(t.text)),
    entry("radii", radiiValue(t.radii)), entry("metrics", metricsValue(t.metrics)),
    entry("scrollbar", scrollbarValue(t.scrollbar))])

proc setThemeBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # set-theme (overrides): the default theme with overrides' palette, text,
  # radii, metrics and scrollbar records applied; every widget takes it on
  # from the next one drawn.
  var t = defaultTheme()
  if args.len > 0:
    let o = eval(args[0], env)
    if not isRecord(o):
      err("set-theme needs a record, got " & stringify(o))
    for f in recordFields(o):
      let v = cdr(f)
      case toSymbol(car(f))
      of "palette": setPalette(t.palette, v)
      of "text": setText(t.text, v)
      of "radii": setRadii(t.radii, v)
      of "metrics": setMetrics(t.metrics, v)
      of "scrollbar": setScrollbar(t.scrollbar, v)
      else: err("a theme has palette, text, radii, metrics and scrollbar, not " & toSymbol(car(f)))
  setTheme(t)
  nothing()

# --- dialogs ---------------------------------------------------------------------------
#
# ellipse_ui/dialogs as owl sees it. Arguments and results are records of
# strings (they cross into a dialog's own process as text); numbers and
# booleans passed in are written as text. A body, footer or callback
# written as a bare name is looked up by that name each time it runs, so
# redefining it from a repl changes an open dialog.

proc lateBound(form: Object, env: ref Environment, params: int): Object {.raises.} =
  # A fun that calls the fun form names, looked up when called.
  if isSymbol(form):
    var ps: seq[Object] = @[]
    var call = @[form]
    for i in 0 ..< params:
      ps.add symbol("late-arg" & $i)
      call.add symbol("late-arg" & $i)
    result = newCommand("", ps, @[list(call)], env, true)
  else:
    result = eval(form, env)

proc fieldsOf(o: Object): Fields {.raises.} =
  result = Fields()
  if isNothing(o):
    return
  if not isRecord(o):
    err("dialog fields are a record, got " & stringify(o))
  for f in recordFields(o):
    let v = cdr(f)
    let key = toSymbol(car(f))
    if isString(v):
      result.put(key, toStr(v))
    elif isBoolean(v):
      result.put(key, toBool(v))
    elif isList(v):
      var items: seq[string] = @[]
      for x in toSeq(v):
        items.add stringify(x)
      result.putList(key, items)
    else:
      result.put(key, stringify(v))

proc fieldsValue(f: Fields): Object =
  var items: seq[Object] = @[]
  for i in 0 ..< f.len:
    items.add pair(symbol(f.keyAt(i)), str(f.valueAt(i)))
  record(items)

proc resultValue(r: DialogResult): Object =
  var status = "open"
  if r.status == dsAccepted:
    status = "accepted"
  elif r.status == dsCancelled:
    status = "cancelled"
  elif r.status == dsFailed:
    status = "failed"
  record(@[entry("status", str(status)), entry("accepted", boolean(r.accepted)),
    entry("answer", str(r.answer)), entry("fields", fieldsValue(r.fields))])

proc callLater(fn: Object, args: seq[Object]) =
  # A callback from ellipse (a dialog closed): no frame is running owl code
  # to hand an error to, so it is printed.
  if isCommand(fn):
    try:
      discard invoke(fn, args)
    except:
      errorReport("owl error in a dialog callback:\n" & errorText(colorErrors))

proc dialogFnOf(fn: Object): DialogFn =
  result = proc () {.closure, raises.} =
    discard invoke(fn, @[])

proc modeOf(o: Object): DialogMode {.raises.} =
  case textOf(o, "mode")
  of "", "inline": result = dmInline
  of "window": result = dmWindow
  else:
    err("a dialog mode is inline or window, got " & stringify(o))
    result = dmInline

proc rawArg(args: seq[Object], name: string): Object =
  # The unevaluated value of option `name`, or nothing.
  result = nothing()
  for a in args:
    if isPair(a) and toSymbol(car(a)) == name:
      return cdr(a)

proc callbackArg(args: seq[Object], name: string, at: int, env: ref Environment,
    params: int, required: bool): Object {.raises.} =
  # A callback option, by name or position, late-bound when it is a name.
  var form = rawArg(args, name)
  if isNothing(form) and at >= 0 and at < args.len and not isPair(args[at]):
    form = args[at]
  if isNothing(form):
    if required:
      err("missing the " & name & " fun")
    return nothing()
  lateBound(form, env, params)

proc defineDialogBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # define-dialog name (title) (width) (max-height) (scroll) (dismissable)
  #   (header = {} (enabled) (draggable) (fullscreen) (close-button))
  #   (body = f) (footer = g)
  # Define it at module level: a dialog in its own window runs the program
  # again, and that run must define it too.
  let a = parseArgs(env, args, bodyStart)
  let name = textOf(arg(a, "name", 0), "define-dialog")
  var spec = DialogSpec(title: strOr(a, "title", -1, "", "define-dialog"))
  if a.has("width"):
    spec.width = float32(numOr(a, "width", -1, 420.0, "define-dialog"))
  if a.has("max-height"):
    spec.maxHeight = float32(numOr(a, "max-height", -1, 640.0, "define-dialog"))
  spec.scroll = toBool(arg(a, "scroll", -1))
  if a.has("dismissable"):
    spec.dismissable = toBool(arg(a, "dismissable", -1))
  let h = arg(a, "header", -1)
  if isRecord(h):
    spec.header.enabled = not hasField(h, "enabled") or toBool(field(h, "enabled"))
    if hasField(h, "draggable"):
      spec.header.draggable = toBool(field(h, "draggable"))
    if hasField(h, "fullscreen"):
      spec.header.fullscreen = toBool(field(h, "fullscreen"))
    if hasField(h, "close-button"):
      spec.header.closeButton = toBool(field(h, "close-button"))
  if not a.has("body"):
    err("define-dialog " & name & " needs (body = fun)")
  spec.body = dialogFnOf(lateBound(rawArg(args, "body"), env, 0))
  if a.has("footer"):
    spec.footer = dialogFnOf(lateBound(rawArg(args, "footer"), env, 0))
  discard defineDialog(name, spec)
  str(name)

proc openDialogBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # open-dialog name (args = {}) (mode = "inline" | "window")
  #   (on-done = f) (title): f gets {} status accepted answer fields.
  let a = parseArgs(env, args, bodyStart)
  let done = callbackArg(args, "on-done", -1, env, 1, false)
  let cb = proc (r: DialogResult) {.closure.} =
    callLater(done, @[resultValue(r)])
  openDialog(textOf(arg(a, "name", 0), "open-dialog"), fieldsOf(arg(a, "args", -1)),
    modeOf(arg(a, "mode", -1)), cb, strOr(a, "title", -1, "", "open-dialog"))
  nothing()

proc dialogArgsBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  fieldsValue(dialogArgs())

proc dialogOpenedBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # dialog-opened: true on a dialog body's first frame (seed state there).
  boolean(dialogOpened())

proc dialogEnterBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  boolean(dialogEnter())

proc passEnterBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # pass-enter: this frame Enter reaches the focused widget (a multiline
  # field) instead of dialog-enter.
  passEnter()
  nothing()

proc dialogInWindowBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  boolean(dialogInWindow())

proc acceptBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # accept (fields) (answer = "ok"): close the dialog with a result.
  let a = parseArgs(env, args, bodyStart)
  accept(fieldsOf(arg(a, "fields", 0)), strOr(a, "answer", 1, "ok", "accept"))
  nothing()

proc cancelBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  cancel()
  nothing()

proc anyDialogOpenBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  boolean(anyDialogOpen())

proc alertBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # alert message (title) (detail) (mode) (on-done = f)
  let a = parseArgs(env, args, bodyStart)
  let done = callbackArg(args, "on-done", -1, env, 1, false)
  let cb = proc (r: DialogResult) {.closure.} =
    callLater(done, @[resultValue(r)])
  alert(textOf(arg(a, "message", 0), "alert"), strOr(a, "title", -1, "", "alert"),
    strOr(a, "detail", -1, "", "alert"), modeOf(arg(a, "mode", -1)), cb)
  nothing()

proc confirmBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # confirm message f (title) (yes) (no) (detail) (mode): f gets true or false.
  let a = parseArgs(env, args, bodyStart)
  let done = callbackArg(args, "on-answer", 1, env, 1, true)
  let cb = proc (yes: bool) {.closure.} =
    callLater(done, @[boolean(yes)])
  confirm(textOf(arg(a, "message", 0), "confirm"), cb,
    strOr(a, "title", -1, "", "confirm"), strOr(a, "yes", -1, "OK", "confirm"),
    strOr(a, "no", -1, "Cancel", "confirm"), strOr(a, "detail", -1, "", "confirm"),
    modeOf(arg(a, "mode", -1)))
  nothing()

proc askBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # ask message buttons f (title) (detail) (default) (cancel-index) (mode):
  # f gets the chosen button's index, -1 when dismissed.
  let a = parseArgs(env, args, bodyStart)
  let done = callbackArg(args, "on-answer", 2, env, 1, true)
  let cb = proc (i: int) {.closure.} =
    callLater(done, @[number(float64(i))])
  ask(textOf(arg(a, "message", 0), "ask"), stringsOf(arg(a, "buttons", 1), "ask"), cb,
    strOr(a, "title", -1, "", "ask"), strOr(a, "detail", -1, "", "ask"),
    int(numOr(a, "default", -1, 0.0, "ask")), int(numOr(a, "cancel-index", -1, -1.0, "ask")),
    modeOf(arg(a, "mode", -1)))
  nothing()

proc promptBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # prompt message f (title) (text) (placeholder) (mode): f gets the text, on OK.
  let a = parseArgs(env, args, bodyStart)
  let done = callbackArg(args, "on-text", 1, env, 1, true)
  let cb = proc (t: string) {.closure.} =
    callLater(done, @[str(t)])
  prompt(textOf(arg(a, "message", 0), "prompt"), cb,
    strOr(a, "title", -1, "", "prompt"), strOr(a, "text", -1, "", "prompt"),
    strOr(a, "placeholder", -1, "", "prompt"), mode = modeOf(arg(a, "mode", -1)))
  nothing()

proc toastBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # toast message (seconds): a note at the bottom of the window.
  let a = parseArgs(env, args, bodyStart)
  toast(textOf(arg(a, "message", 0), "toast"), numOr(a, "seconds", 1, 2.5, "toast"))
  nothing()

proc isDialogProcessBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # is-dialog-process: this run only shows one dialog in its own window.
  boolean(isDialogProcess())

# --- the app ----------------------------------------------------------------------------

# Why the last frame's view failed ("" when it did not): the message, and
# the whole error window shown over the view.
var frameError = ""
var frameReport = ""
var reportedError = ""

proc drawError() =
  let t = activeTheme
  openElement()
  configureOpenElement(col(width = grow(), height = fit(), padding = padAll(12), gap = 4)
    .bg(rgb(120, 24, 24)).floating(attachRoot, zIndex = 100))
  textElement("owl error (fix it and the view comes back):",
    TextConfig(fontSize: t.text.label, color: rgb(255, 210, 210)))
  # the window's lines as they are: a word wrap would move the arrow
  textElement(frameReport, TextConfig(fontSize: t.text.control, color: rgb(255, 255, 255),
    fontId: MonoFont, wrap: newlineWrap))
  closeElement()

var currentView = nothing()
var guiRunning = false
var quietRun = false
  ## gui-run (quiet = true): nothing goes to stdout or stderr -- the app owns
  ## the terminal (the repl), and shows its errors itself.

proc viewProc(): AppFn =
  # Each frame runs the owl view. A failure keeps the frame balanced, shows
  # the error over the window and is printed once; the next frame tries
  # again, so a fix (a patch, a saved file) brings the view back.
  result = proc () {.closure, raises.} =
    hasPending = false
    try:
      discard invoke(currentView, @[])
      frameError = ""
      frameReport = ""
    except:
      frameError = currentError.message
      frameReport = errorText()
    if frameError.len > 0:
      if frameReport != reportedError and not quietRun:
        errorReport("owl error in the view:\n" & errorText(colorErrors))
        reportedError = frameReport
      drawError()
    else:
      reportedError = ""

proc useFonts() =
  # The font ships with the ellipse checkout: <root>/assets, beside the
  # bin/ the owl binary is in, unless the project carries its own.
  if not fileExists(fontPath):
    let root = parentDir(parentDir(getAppFilename()))
    let candidate = root & "/assets/fonts/inter/Inter-Regular.ttf"
    if fileExists(candidate):
      fontPath = candidate

var guiScript*: nil AppFn = nil
  ## Tests: drives gui-run's frames instead of the loop (`run(app, script)`).

var afterQueue: seq[Object] = @[]

proc afterFrameBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # after-frame f: call f once the next frame has run (a frame is asked for).
  if args.len != 1:
    err("after-frame needs a fun")
  afterQueue.add eval(args[0], env)
  requestFrame()
  nothing()

proc runAfterFrame() {.raises.} =
  let queued = afterQueue
  afterQueue = @[]
  for f in queued:
    try:
      discard invoke(f, @[])
    except:
      discard

proc guiRunBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # gui-run config view: open the window and run the frame loop until it
  # closes. config has title, width, height, debug. view is called every
  # frame, so redefining what it calls changes the next frame.
  if args.len != 2:
    err("gui-run needs a config record and a view fun")
  let cfg = eval(args[0], env)
  let view = eval(args[1], env)
  if not isCommand(view):
    err("gui-run needs a view fun, got " & stringify(view))
  currentView = view
  if guiRunning:
    # A reload reran run-app: keep the loop, take the new view and title.
    if hasField(cfg, "title"):
      setWindowTitle(textOf(field(cfg, "title"), "gui-run"))
    requestFrame()
    return nothing()
  var win = WindowConfig()
  if hasField(cfg, "title"):
    win.title = textOf(field(cfg, "title"), "gui-run")
  if hasField(cfg, "width"):
    win.width = int32(toNumber(field(cfg, "width")))
  if hasField(cfg, "height"):
    win.height = int32(toNumber(field(cfg, "height")))
  let debug = not hasField(cfg, "debug") or toBool(field(cfg, "debug"))
  quietRun = hasField(cfg, "quiet") and toBool(field(cfg, "quiet"))
  useFonts()
  # A dialog in its own window is this program run again: owl run, from
  # the same directory.
  dialogLauncher = @[getAppFilename(), "run"]
  guiRunning = true
  try:
    run(App(window: win, view: viewProc(), debugMode: debug, log: not quietRun,
            after: runAfterFrame),
      guiScript)
  finally:
    guiRunning = false
  nothing()

proc owlApp*(view: Object; window: WindowConfig): App =
  ## The App gui-run starts, for tests that drive frames themselves
  ## (`run(owlApp(...), script)`).
  currentView = view
  App(window: window, view: viewProc(), debugMode: false, log: false,
      after: runAfterFrame)

proc setOwlView*(view: Object) =
  currentView = view

proc quitAppBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # quit-app: close the window; gui-run returns.
  platform.quit()
  wake()
  nothing()

proc frameErrorBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # frame-error: why the last frame's view failed, or nothing.
  if frameError.len == 0: nothing() else: str(frameError)

proc watchFdBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # watch-fd fd f: call f between frames whenever fd is readable (see
  # ellipse/platform/fdwatch). A frame follows, so what f changed shows.
  if args.len != 2:
    err("watch-fd needs a descriptor and a fun")
  let fd = int32(numOf(eval(args[0], env), "watch-fd"))
  let f = eval(args[1], env)
  let ok = watchFd(fd, proc () {.closure.} =
    try:
      discard invoke(f, @[])
    except:
      discard
    # what the callback printed reaches a log file now, not at exit
    flushFile(stdout)
    requestFrame())
  boolean(ok)

proc unwatchFdBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  unwatchFd(int32(numOf(eval(args[0], env), "unwatch-fd")))
  nothing()

proc windowTitleBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  setWindowTitle(oneText(env, args, "window-title"))
  nothing()

# --- for code: the editor, keys taken before widgets, scrolling ------------

proc codeEditorBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # code-editor id text (max-lines) (read-only) (font) (wrap) (indent-after):
  # ellipse_ui's editor (undo, selection, mouse, Emacs keys), indenting like
  # the line above; the text to store back.
  let a = parseArgs(env, args, bodyStart)
  var opts = EditorOpts(maxLines: int(numOr(a, "max-lines", -1, 0.0, "code-editor")),
    readOnly: toBool(arg(a, "read-only", -1)),
    fontId: fontIdOf(arg(a, "font", -1)),
    autoIndent: true,
    indentAfter: strOr(a, "indent-after", -1, "", "code-editor"))
  if a.has("wrap"):
    opts.wrap = toBool(arg(a, "wrap", -1))
  let r = editor(idOf(need(a, "id", 0, "code-editor")),
    textOf(arg(a, "text", 1), "code-editor"), opts)
  rethrow()
  str(r.text)

proc editorCaretBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # editor-caret id text: where the caret is, as a byte offset.
  let a = parseArgs(env, args, bodyStart)
  number(float64(editorCaret(idOf(arg(a, "id", 0)), textOf(arg(a, "text", 1), "editor-caret"))))

proc takeKeyBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # take-key "ctrl+enter": true when the chord was pressed this frame; the
  # key is taken, so no widget drawn after sees it.
  if args.len != 1:
    err("take-key needs a chord such as ctrl+enter")
  let c = parseChord(textOf(eval(args[0], env), "take-key"))
  if c.kind == kevNone:
    err("take-key: not a chord: " & stringify(eval(args[0], env)))
  var kept: seq[KeyEvent] = @[]
  var hit = false
  let evs = keyEvents()
  for ev in evs:
    if not hit and matches(ev, c):
      hit = true
    else:
      kept.add ev
  if hit:
    setKeyEvents(kept)
  boolean(hit)

proc typedTextBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # typed-text: the text typed this frame (no chords), taken from the frame.
  var kept: seq[KeyEvent] = @[]
  var typed = ""
  let evs = keyEvents()
  for ev in evs:
    if ev.kind == kevText:
      typed.add ev.text
    else:
      kept.add ev
  if typed.len > 0:
    setKeyEvents(kept)
  str(typed)

proc setClipboardBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # set-clipboard text: the system clipboard (OSC 52 in a terminal).
  setClipboard(oneText(env, args, "set-clipboard"))
  nothing()

proc textColumnsBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # text-columns: how many characters of monospaced code fit across the
  # window (the terminal's columns).
  if terminalMode():
    return number(float64(terminalSize().cols))
  let w = windowPixelSize().width
  let cw = measureText("0000000000", TextConfig(fontSize: activeTheme.text.control,
    fontId: MonoFont)).width / 10.0
  number(float64(if cw > 0: int(w / cw) else: 80))

proc scrollIntoViewBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # scroll-into-view container element: scroll the container so the
  # element (as laid out last frame) is in sight.
  let a = parseArgs(env, args, bodyStart)
  let cid = idOf(arg(a, "container", 0))
  let c = elementData(cid)
  let e = elementData(idOf(arg(a, "element", 1)))
  let sd = scrollContainerData(cid)
  if c.found and e.found and sd.found:
    var y = sd.position.y
    if e.box.y < c.box.y:
      y += c.box.y - e.box.y
    elif e.box.y + e.box.height > c.box.y + c.box.height:
      y -= min(e.box.y + e.box.height - (c.box.y + c.box.height), e.box.y - c.box.y)
    if y != sd.position.y:
      setScrollPosition(cid, vec2(sd.position.x, y))
      requestFrame()
  nothing()

proc scrollToEndBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # scroll-to-end id: scroll a container to its bottom.
  let id = idArg(env, args, "scroll-to-end")
  setScrollPosition(id, vec2(0, -1.0e9))
  nothing()

proc windowBackendBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # window-backend: an app here would open a window (SDL is built in, no
  # --tui, and there is a display), not take over the terminal.
  when withSdl:
    let display = getEnv("WAYLAND_DISPLAY").len > 0 or getEnv("DISPLAY").len > 0 or
      getEnv("SDL_VIDEODRIVER").len > 0
    boolean(display and not terminalMode())
  else:
    boolean(false)

proc onCloseBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # on-close f: when the person closes the app (the window's close button,
  # Ctrl+Q in a terminal) f is asked first: true closes it, false keeps it
  # running. on-close nothing closes at once again.
  if args.len != 1:
    err("on-close needs a fun, or nothing")
  let f = eval(args[0], env)
  if isNothing(f):
    setCloseHandler(nil)
  else:
    setCloseHandler(proc (): bool {.closure.} =
      result = true
      try:
        result = toBool(invoke(f, @[]))
      except:
        result = true
      requestFrame())
  nothing()

proc useTerminalBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
  # use-terminal: the next gui-run takes over the terminal, window backend
  # or not.
  setTerminalMode(true)
  nothing()

proc installGui*(env: ref Environment) =
  template fn(name: string, p: CommandProc) =
    define(env, symbol(name), newBuiltin(name, p, true))
  template cmd(name: string, p: CommandProc) =
    define(env, symbol(name), newBuiltin(name, p, false))
  # layout and values
  cmd "row", rowBuiltin
  cmd "column", columnBuiltin
  cmd "text", textBuiltin
  cmd "grow", growBuiltin
  cmd "fit", fitBuiltin
  cmd "pct", pctBuiltin
  # interaction
  fn "hovered", hoveredBuiltin
  fn "clicked", clickedBuiltin
  fn "activated", activatedBuiltin
  fn "focused", focusedBuiltin
  fn "gained-focus", gainedFocusBuiltin
  fn "pressing", pressingBuiltin
  cmd "register-focus", registerFocusBuiltin
  fn "set-focus", setFocusBuiltin
  fn "key-pressed", keyPressedBuiltin
  fn "request-frame", requestFrameBuiltin
  cmd "refresh-due", refreshDueBuiltin
  fn "invalidate", invalidateBuiltin
  # events
  fn "widget-frame", widgetFrameBuiltin
  cmd "handle-events", handleEventsBuiltin
  fn "define-event", defineEventBuiltin
  fn "known-event", knownEventBuiltin
  cmd "emit", emitBuiltin
  fn "reemit", reemitBuiltin
  fn "event-log", eventLogBuiltin
  # stock widgets
  cmd "button", buttonBuiltin
  cmd "checkbox", checkboxBuiltin
  cmd "switch", switchBuiltin
  cmd "text-field", textFieldBuiltin
  cmd "multiline-field", multilineFieldBuiltin
  cmd "number-field", numberFieldBuiltin
  cmd "combo-box", comboBoxBuiltin
  cmd "tab-strip", tabStripBuiltin
  cmd "text-link", textLinkBuiltin
  cmd "menu-item", menuItemBuiltin
  cmd "heading", headingBuiltin
  fn "label", labelBuiltin
  fn "body-text", bodyTextBuiltin
  fn "caption", captionBuiltin
  fn "overline", overlineBuiltin
  fn "badge", badgeBuiltin
  fn "spacer", spacerBuiltin
  fn "menu-separator", menuSeparatorBuiltin
  cmd "card", cardBuiltin
  cmd "stat-card", statCardBuiltin
  cmd "card-row", cardRowBuiltin
  cmd "section", sectionBuiltin
  cmd "prose", proseBuiltin
  cmd "labeled", labeledBuiltin
  cmd "tabbed-view", tabbedViewBuiltin
  fn "active-tab", activeTabBuiltin
  cmd "tool-bar", toolBarBuiltin
  cmd "menu", menuBuiltin
  cmd "int-number-field", intNumberFieldBuiltin
  cmd "multi-select", multiSelectBuiltin
  cmd "list-row", listRowBuiltin
  cmd "list-card", listCardBuiltin
  cmd "set-scroll-position", setScrollPositionBuiltin
  cmd "focus-at", focusAtBuiltin
  fn "theme", themeBuiltin
  fn "set-theme", setThemeBuiltin
  # dialogs
  cmd "define-dialog", defineDialogBuiltin
  cmd "open-dialog", openDialogBuiltin
  fn "dialog-args", dialogArgsBuiltin
  fn "dialog-opened", dialogOpenedBuiltin
  fn "dialog-enter", dialogEnterBuiltin
  fn "pass-enter", passEnterBuiltin
  fn "dialog-in-window", dialogInWindowBuiltin
  cmd "accept", acceptBuiltin
  fn "cancel", cancelBuiltin
  fn "any-dialog-open", anyDialogOpenBuiltin
  cmd "alert", alertBuiltin
  cmd "confirm", confirmBuiltin
  cmd "ask", askBuiltin
  cmd "prompt", promptBuiltin
  cmd "toast", toastBuiltin
  fn "is-dialog-process", isDialogProcessBuiltin
  # the app
  fn "gui-run", guiRunBuiltin
  fn "quit-app", quitAppBuiltin
  fn "frame-error", frameErrorBuiltin
  fn "after-frame", afterFrameBuiltin
  fn "watch-fd", watchFdBuiltin
  fn "unwatch-fd", unwatchFdBuiltin
  fn "window-title", windowTitleBuiltin
  cmd "code-editor", codeEditorBuiltin
  fn "editor-caret", editorCaretBuiltin
  fn "take-key", takeKeyBuiltin
  fn "typed-text", typedTextBuiltin
  fn "set-clipboard", setClipboardBuiltin
  fn "text-columns", textColumnsBuiltin
  fn "scroll-into-view", scrollIntoViewBuiltin
  fn "scroll-to-end", scrollToEndBuiltin
  fn "window-backend", windowBackendBuiltin
  fn "use-terminal", useTerminalBuiltin
  fn "on-close", onCloseBuiltin

proc guiModule*(source: string): Module {.raises.} =
  # The Nim builtins and gui.owl in one module: `use gui` gives both.
  result = newModule("gui")
  installGui(result.env)
  exportAllBindings(result)
  result = addLibrarySource(result, source)
