## Shared plumbing for the standard widget set (see `ellipse_ui/widgets`).
##
## Everything here is built on the clay DSL (`clay` blocks, `row`/`col`
## declarations) and the slot-based `widget` definitions from
## `ellipse_ui/ui`. Interactive widgets follow the immediate-mode contract
## the built-in `button`/`menu` set already uses:
##
##   - the *caller* owns persistent data (a checkbox's bool, a field's text)
##     and passes it in; the widget returns the value to store back;
##   - the *widget modules* own transient interaction state -- which field
##     has the caret, which dropdown is open -- keyed by element id, exactly
##     like `menu`'s `openMenuId`.
##
## On top of the edit engine this module is the widget set's *scaffold
## layer*: the element brackets (`container`, plus `ui.item` for explicit
## ids), the repeated declaration shapes (`fieldDecl`, `shadeDecl`,
## `toggleRowDecl`, `optionRowDecl`), the shared parts (`spacer`,
## `chevron`, `tickBox`, `textLine`) and the whole dropdown plumbing
## (`toggleDropdown`, `dropdownField`, `dropdownPanel`, `optionRow`) that
## the widgets under `widgets/` are defined from. A tiny widget is the
## goal:
##
##   proc checkbox*(id, label, checked): bool =
##     item(id, toggleRowDecl(pointerOver(id))):
##       tickBox(checked)
##       textElement(label, ...)
##     result = if clickedIn(id): not checked else: checked
##
## Keyboard and wheel input arrives through `ellipse/platform/platform`'s
## per-frame event queues; `updateUI` advances them, and `editStep` applies
## one frame's events to the focused field.

import std/[monotimes, strutils]

import clay
import ../ui

import ellipse/platform/platform

proc pressedNow*(): bool =
  ## The primary button went down *this* frame (one-shot click edge).
  currentContext().pointerData().state == pressedThisFrame

proc clickedIn*(id: ElementId): bool =
  ## A click that began inside `id`'s last-frame box.
  pressedNow() and pointerOver(id)

proc clickedOut*(id: ElementId): bool =
  ## A click that began this frame but missed `id` -- the blur/dismiss edge.
  pressedNow() and not pointerOver(id)

## --- text editing --------------------------------------------------------------
##
## Caret, selection and focus live here so `textfields` and `numberfields`
## share one edit engine. Selection is tracked (shift-arrows, backspace
## deletes it) but not painted; the caret is `caretOverlay`: a 2px bar
## floated over the field's text element at the caret's measured line and
## column, so it renders *on top* of the text without displacing glyphs.
##
## Keys follow the Emacs/readline default map: C-a/C-e line edges, C-b/C-f
## and arrows characters (M-b/M-f, M-Left/M-Right words), C-p/C-n and
## Up/Down lines, C-d/C-h and Delete/Backspace deletion, C-k/C-u/C-w/M-d
## kills into a yank-able kill buffer (C-y), Enter/C-m commit and
## Escape/C-g cancel. Single-line fields never contain `\n`, so their
## "line" motions degenerate to buffer edges automatically.

type
  EditOutcome* = enum
    ## How the frame's keys ended.
    eoNone,     ## ordinary editing happened (or nothing did)
    eoCommit,   ## Enter: accept and leave the field
    eoCancel    ## Escape: revert to the value focused with

  EditResult* = object
    ## What one edit step produced: the new text and how it ended.
    text*: string = ""
    outcome*: EditOutcome = eoNone

  ValidCharFn* = proc(c: char): bool

proc acceptAll*(c: char): bool = true

var
  bootTime = getMonoTime().ticks
  focusId = 0'u32        ## the field holding the caret, 0 = none
  snapshot = ""          ## the text as it was when focused (Escape target)
  caret = 0
  selAnchor = 0

proc focused*(id: ElementId): bool =
  focusId == id.id

proc snapshotValue*(): string =
  snapshot

proc caretPos*(): int =
  caret

proc focus*(id: ElementId, text: string) =
  ## Move caret and selection to the end; remember the Escape snapshot.
  focusId = id.id
  snapshot = text
  caret = text.len
  selAnchor = caret

proc blur*() =
  focusId = 0'u32

proc fieldBorder*(id: ElementId): Color =
  ## Focused (or hovered) fields get the accent ring; idle ones the plain
  ## panel border. Shared by text and number fields.
  if focused(id) or pointerOver(id):
    return accent
  return panelBorder

proc selLo(): int = min(caret, selAnchor)
proc selHi(): int = max(caret, selAnchor)

func isContByte(c: char): bool =
  ## A UTF-8 continuation byte: backspace/delete must skip whole codepoints.
  (ord(c) and 0xC0) == 0x80

proc splice(s: var string, lo, hi: int, ins: string) =
  ## Replace `s[lo..<hi]` with `ins` (byte-wise), then park the caret after
  ## the insertion with the selection collapsed.
  var outp = ""
  var i = 0
  while i < lo:
    outp.add s[i]
    inc i
  outp.add ins
  i = hi
  while i < s.len:
    outp.add s[i]
    inc i
  s = outp
  caret = lo + ins.len
  selAnchor = caret

proc moveCaret(s: string, dir: int, extend: bool) =
  var pos = caret
  if dir < 0:
    dec pos
    while pos > 0 and isContByte(s[pos]):
      dec pos
  elif dir > 0:
    inc pos
    while pos < s.len and isContByte(s[pos]):
      inc pos
  pos = min(max(pos, 0), s.len)
  caret = pos
  if not extend:
    selAnchor = pos

## --- line & word geometry ------------------------------------------------------
##
## Fields hold plain text where `\n` splits display lines; single-line text
## never has one, so every "line" motion degenerates to buffer edges there --
## C-a/C-e mean field start/end as expected.

proc bolOf(s: string, pos: int): int =
  result = pos
  while result > 0 and s[result - 1] != '\n':
    dec result

proc eolOf(s: string, pos: int): int =
  result = pos
  while result < s.len and s[result] != '\n':
    inc result

func isWordChar(c: char): bool =
  (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
    (c >= '0' and c <= '9') or c == '_'

proc prevWordStart(s: string, pos: int): int =
  result = pos
  while result > 0 and not isWordChar(s[result - 1]) and s[result - 1] != '\n':
    dec result
  while result > 0 and isWordChar(s[result - 1]):
    dec result

proc nextWordEnd(s: string, pos: int): int =
  result = pos
  while result < s.len and not isWordChar(s[result]) and s[result] != '\n':
    inc result
  while result < s.len and isWordChar(s[result]):
    inc result

proc gotoLineEdge(s: string, toEnd: bool, extend: bool) =
  caret = if toEnd: eolOf(s, caret) else: bolOf(s, caret)
  if not extend:
    selAnchor = caret

proc gotoWord(s: string, dir: int, extend: bool) =
  caret = if dir < 0: prevWordStart(s, caret) else: nextWordEnd(s, caret)
  if not extend:
    selAnchor = caret

proc gotoLine(s: string, delta: int) =
  ## Up/Down and C-p/C-n: keep the column where the target line has room.
  let col = caret - bolOf(s, caret)
  if delta < 0:
    let ls = bolOf(s, caret)
    if ls > 0:                       # a previous line exists; ls-1 is its '\n'
      let prevStart = bolOf(s, ls - 1)
      caret = min(prevStart + col, ls - 1)
  else:
    let le = eolOf(s, caret)         # le is the newline below, when any
    if le < s.len:
      caret = min(le + 1 + col, s.len)
  selAnchor = caret

## --- delete & kill -------------------------------------------------------------
##
## Plain deletes swallow the selection. Emacs kills (C-k/C-u/C-w/M-d) feed a
## single-slot kill buffer; consecutive kills accumulate, so `C-k C-k` then
## `C-y` yanks both lines. Inserting or yanking closes the accumulation.

var killBuf = ""
var killAppend = false

proc sliceOf(s: string, lo, hi: int): string =
  result = ""
  var i = max(lo, 0)
  while i < hi and i < s.len:
    result.add s[i]
    inc i

proc deleteBackward(s: var string) =
  if selHi() > selLo():
    splice(s, selLo(), selHi(), "")
  elif caret > 0:
    var pos = caret - 1
    while pos > 0 and isContByte(s[pos]):
      dec pos
    splice(s, pos, caret, "")

proc deleteForward(s: var string) =
  if selHi() > selLo():
    splice(s, selLo(), selHi(), "")
  elif caret < s.len:
    var pos = caret + 1
    while pos < s.len and isContByte(s[pos]):
      inc pos
    splice(s, caret, pos, "")

proc takeKill(s: var string, lo, hi: int) =
  if hi > lo:
    let cut = sliceOf(s, lo, hi)
    if killAppend:
      killBuf.add cut
    else:
      killBuf = cut
      killAppend = true
    splice(s, lo, hi, "")

proc killLine(s: var string) =
  if selHi() > selLo():
    takeKill(s, selLo(), selHi())
  elif caret < s.len:
    takeKill(s, caret, eolOf(s, caret))

proc killToBol(s: var string) =
  takeKill(s, bolOf(s, caret), caret)

proc killPrevWord(s: var string) =
  if selHi() > selLo():
    takeKill(s, selLo(), selHi())
  else:
    takeKill(s, prevWordStart(s, caret), caret)

proc killNextWord(s: var string) =
  takeKill(s, caret, nextWordEnd(s, caret))

proc yank(s: var string) =
  if killBuf.len > 0:
    killAppend = false
    splice(s, caret, caret, killBuf)

proc applyKeys(text: sink string, evs: seq[KeyEvent],
               valid: ValidCharFn): EditResult =
  ## The shared edit loop over an explicit event list; caret/selection state
  ## is module-private and belongs to whichever field holds focus. The full
  ## keymap is documented at the top of this section; movements extend the
  ## selection while Shift is held, as with the arrow keys.
  result = EditResult(text: text)
  var s = result.text
  for ev in evs:
    case ev.kind
    of kevText:
      for ch in ev.text:
        if valid(ch):
          var one = ""
          one.add ch
          if selHi() > selLo():
            splice(s, selLo(), selHi(), one)
          else:
            splice(s, caret, caret, one)
          killAppend = false
    of kevLetter:
      if ev.ctrl:
        case ev.ch
        of 'a': gotoLineEdge(s, false, ev.shift)
        of 'e': gotoLineEdge(s, true, ev.shift)
        of 'b': moveCaret(s, -1, ev.shift)
        of 'f': moveCaret(s, 1, ev.shift)
        of 'p': gotoLine(s, -1)
        of 'n': gotoLine(s, 1)
        of 'h': deleteBackward(s)
        of 'd': deleteForward(s)
        of 'k': killLine(s)
        of 'u': killToBol(s)
        of 'w': killPrevWord(s)
        of 'y': yank(s)
        of 'g': result.outcome = eoCancel
        of 'm': result.outcome = eoCommit
        else: discard
      elif ev.alt:
        case ev.ch
        of 'b': gotoWord(s, -1, ev.shift)
        of 'f': gotoWord(s, 1, ev.shift)
        of 'd': killNextWord(s)
        else: discard
    of kevBackspace:
      deleteBackward(s)
    of kevDelete:
      deleteForward(s)
    of kevLeft:
      if ev.alt or ev.ctrl: gotoWord(s, -1, ev.shift)
      else: moveCaret(s, -1, ev.shift)
    of kevRight:
      if ev.alt or ev.ctrl: gotoWord(s, 1, ev.shift)
      else: moveCaret(s, 1, ev.shift)
    of kevUp:
      gotoLine(s, -1)
    of kevDown:
      gotoLine(s, 1)
    of kevHome:
      gotoLineEdge(s, false, ev.shift)
    of kevEnd:
      gotoLineEdge(s, true, ev.shift)
    of kevEnter:
      result.outcome = eoCommit
    of kevEscape:
      result.outcome = eoCancel
    else:
      discard
  result.text = s

proc editStep*(text: sink string, valid: ValidCharFn = acceptAll): EditResult =
  ## Apply *this frame's* key events to `text` through the shared caret
  ## state. Only the focused widget's caller should invoke it.
  result = EditResult(text: text)
  if focusId == 0'u32:
    return
  result = applyKeys(text, keyEvents(), valid)

proc editStepWith*(text: sink string, evs: seq[KeyEvent],
                   valid: ValidCharFn = acceptAll): EditResult =
  ## `editStep` over a caller-supplied (remapped) event list.
  result = EditResult(text: text)
  if focusId == 0'u32 or evs.len == 0:
    return
  result = applyKeys(text, evs, valid)

proc syncCaret*(textLen: int) =
  ## Re-clamp caret/selection after the caller edited the string behind the
  ## edit engine's back (a number field sanitising its buffer, say).
  if caret > textLen:
    caret = textLen
  if selAnchor > textLen:
    selAnchor = textLen

proc caretVisible*(): bool =
  ## Half-second blink phase from wall-clock time.
  let ms = (getMonoTime().ticks - bootTime) div 1_000_000'i64
  (ms div 500) mod 2 == 0

proc textChildId*(parentId: uint32, child: uint32 = 0): uint32 =
  ## The id Clay gives the `child`-th flow child of `parentId` when it is
  ## opened *without* an explicit id (the auto-id rule: hash of sibling
  ## count and parent id). A field's text element is its first child, so a
  ## field passes `textChildId(id.id)`; one nested inside an auto-id row
  ## passes `textChildId(textChildId(id.id))`.
  hashNumber(child, parentId)

proc caretOverlay*(textElId: uint32, text: string, cfg: TextConfig,
                   color: Color = textColor) =
  ## Paint the blinking caret as a 2px bar *floated over* the field's text
  ## element (`textElId` = that element's auto id, see `textChildId`): the
  ## bar is attached to the text box and offset to the caret's line and
  ## column, so it rides on top of the glyphs instead of displacing them.
  ## Call right after the field's `textElement`, still inside the field,
  ## only while the field holds focus. Line/column come from Clay's own
  ## wrapping pass (`wrappedLines` over the text box's previous-frame
  ## width), so the bar sits on exactly the grid the renderer draws.
  if focusId == 0'u32 or not caretVisible():
    return
  let ctx = currentContext()
  if not ctx.measureTextInstalled():
    return
  let prev = elementData(ElementId(id: textElId))
  if not prev.found:
    return                       # text never laid out yet: no geometry
  let pos = min(max(caret, 0), text.len)
  let m = measureTextCached(ctx, text, cfg)
  let lineHeight =
    if cfg.lineHeight > 0: float32(cfg.lineHeight) else: m.unwrapped.height
  let barH = if lineHeight > 0.0: lineHeight else: float32(cfg.fontSize)
  let yBase = (lineHeight - m.unwrapped.height) / 2.0
  var x: float32 = 0.0
  var lineIdx = 0
  if cfg.wrap == wordWrap and
      (m.containsNewlines or m.unwrapped.width > prev.box.width):
    let lines = wrappedLines(ctx, text, cfg, prev.box.width)
    if lines.len > 0:
      var li = 0
      for i in 0 ..< lines.len:
        if lines[i].start <= int32(pos):
          li = i
      let ln = lines[li]
      if pos > int(ln.start + ln.length):
        x = ln.dims.width
      else:
        x = measureTextCached(ctx, substr(text, int(ln.start), pos - 1),
                              cfg).unwrapped.width
      lineIdx = li
      # A caret right after a trailing newline belongs to the empty line
      # the box does not render.
      if pos == text.len and pos > 0 and text[pos - 1] == '\n':
        x = 0.0
        lineIdx = lines.len
  else:
    x = measureTextCached(ctx, substr(text, 0, pos - 1), cfg).unwrapped.width

  openElement(ElementId(id: hashNumber(1'u32, textElId)))
  configureOpenElement(col(width = fixedPx(2), height = fixedPx(barH))
    .bg(color)
    .floating(attachElementId,
              offset = vec2(x, yBase + float32(lineIdx) * lineHeight),
              zIndex = 32767,
              parentId = textElId,
              points = AttachPoints(element: pointLeftTop,
                                    parent: pointLeftTop),
              capture = passThroughPointer))
  closeElement()

## --- element brackets ----------------------------------------------------------
##
## The low-level clay rhythm -- open, configure, children, close -- spelled
## out per widget is what this layer replaces. `container` brackets an
## auto-id element (repeatable inside any parent, no id bookkeeping);
## `ui.item` is the explicit-id sibling. Nimony templates are hygienic, so
## a bracket's `body` cannot see locals the template computes -- instead it
## runs *while the element is open*, exactly where `hovered()` and
## `pressedNow()` are valid. Fold a click edge in wherever the body likes:
##
##   container(row(width = grow(), height = fit(), gap = 8)):
##     textElement("one", cfg)
##   item(agreeId, toggleRowDecl(pointerOver(agreeId))):
##     tickBox(checked)
##     if pressedNow() and hovered():   # or `clickedIn(agreeId)` outside
##       checked = not checked

template container*(decl: untyped, body: untyped): untyped =
  openElement()
  configureOpenElement(decl)
  body
  closeElement()

## --- shared parts ----------------------------------------------------------------
##
## The small repeated elements every composite builds by hand: the grow
## spacer that pushes siblings apart, the dropdown chevron, the tick square,
## a static text line.

proc spacer*(vertical = false) =
  ## Fill the leftover space in an open row (or column): pushes the next
  ## sibling to the far edge.
  let w = if vertical: fit() else: grow()
  let h = if vertical: grow() else: fit()
  openElement()
  configureOpenElement(row(width = w, height = h))
  closeElement()

proc chevron*(isOpen: bool) =
  ## The dropdown caret glyph: "v" closed, "^" open, on the theme's chevron
  ## size and dim colour.
  let t = activeTheme
  textElement(if isOpen: "^" else: "v",
    TextConfig(fontSize: t.text.chevron, color: t.palette.dimColor))

proc textLine*(text: string, cfg: TextConfig, width: SizingAxis = grow(),
               height: SizingAxis = fit()) =
  ## Static text in an auto-id row -- the bracket the named text styles
  ## (`label`, `caption`, ...) are one-liners over.
  container(row(width = width, height = height)):
    textElement(text, cfg)

proc tickBox*(checked: bool, box: float32 = activeTheme.metrics.checkSize,
              tick: float32 = activeTheme.metrics.tickSize) =
  ## The square tick indicator shared by `checkbox` and `multiSelect`: a
  ## sunken box with an accent hairline when `checked`, filled by an accent
  ## square of `tick` pixels. The filled square stands in for a `✓` glyph --
  ## the renderer only promises rectangles and the UI font.
  let t = activeTheme
  container(col(width = fixedPx(box), height = fixedPx(box),
      alignX = centerX, alignY = centerY)
    .bg(t.palette.fieldBg)
    .corner(t.radii.check)
    .border(t.metrics.borderHairline,
      if checked: t.palette.accent else: t.palette.panelBorder)):
    if checked:
      openElement()
      configureOpenElement(col(width = fixedPx(tick), height = fixedPx(tick))
        .bg(t.palette.accent).corner(t.radii.tick))
      closeElement()

proc fieldText*(text, placeholder: string, isFocused: bool): (string, Color) =
  ## What a field shows: its text, or the placeholder in the dim colour
  ## while empty and unfocused.
  if not isFocused and text.len == 0:
    return (placeholder, dimColor)
  return (text, textColor)

proc fieldFocus*(id: ElementId, text: string): bool =
  ## The click side of the edit engine for one field: a click inside
  ## focuses it (seeding `text` as the Escape snapshot), a click anywhere
  ## else while it holds focus blurs it. Returns whether the field is
  ## focused *after* this frame's click.
  let was = focused(id)
  if clickedIn(id):
    if not was:
      focus(id, text)
  elif was and clickedOut(id):
    blur()
  focused(id)

## --- declaration builders ----------------------------------------------------------
##
## The theme-resolved `ElementDeclaration`s the widgets keep re-deriving by
## hand. Each takes the sizing/padding knobs its call sites actually vary.

proc toggleRowDecl*(over: bool, showBg = true): ElementDeclaration =
  ## The labelled row a `checkbox`/`switch` lives in: fit content, centred,
  ## `padCheckRow` padding, 10px gap before the label; with `showBg` a
  ## button fill lights it while hovered.
  let t = activeTheme
  result = row(gap = 10, width = fit(), height = fit(), alignY = centerY,
    padding = padAll(t.metrics.padCheckRow))
  if showBg:
    result = result.bg(if over: t.palette.buttonBg else: Color())
      .corner(t.radii.button)

proc fieldPad*(): Padding =
  ## A field's standard inset: `padFieldX` across, `padFieldY` down.
  let m = activeTheme.metrics
  Padding(left: m.padFieldX, right: m.padFieldX,
          top: m.padFieldY, bottom: m.padFieldY)

proc fieldDecl*(id: ElementId, width: SizingAxis, height: SizingAxis,
                dir: Direction = leftToRight, gap: int = 0,
                alignY: AlignY = top,
                padding: Padding = fieldPad()): ElementDeclaration =
  ## The sunken entry-field chrome shared by text, multiline and number
  ## fields: `fieldBg`, `field` corners, the focus/hover hairline ring of
  ## `fieldBorder`.
  let t = activeTheme
  result = if dir == leftToRight:
    row(gap = gap, padding = padding, width = width, height = height,
        alignY = alignY)
  else:
    col(gap = gap, padding = padding, width = width, height = height,
        alignY = alignY)
  result = result.bg(t.palette.fieldBg).corner(t.radii.field)
    .border(t.metrics.borderHairline, fieldBorder(id))

proc shadeDecl*(id: ElementId, width: SizingAxis, height: SizingAxis,
                dir: Direction = leftToRight, padding: Padding = Padding(),
                alignX: AlignX = left, alignY: AlignY = top): ElementDeclaration =
  ## A small button surface that just lights up under the pointer --
  ## number-field steppers, dropdown footer buttons: `shade(pointerOver(id))`
  ## over `inner` corners.
  let t = activeTheme
  result = if dir == leftToRight:
    row(width = width, height = height, padding = padding,
        alignX = alignX, alignY = alignY)
  else:
    col(width = width, height = height, padding = padding,
        alignX = alignX, alignY = alignY)
  result = result.bg(shade(pointerOver(id))).corner(t.radii.inner)

proc optionRowDecl*(over, selected: bool, gap: int = 0,
                    alignY: AlignY = top): ElementDeclaration =
  ## A dropdown option row: grows to the panel width, `padOption` inset,
  ## `inner` corners, the selected fill or the hover fill, in that order.
  let t = activeTheme
  result = row(width = grow(), height = fit(), gap = gap,
      padding = padAll(t.metrics.padOption), alignY = alignY)
  if selected:
    result.background = t.palette.selectedBg
  elif over:
    result.background = t.palette.buttonHoverBg
  result.corner = allCorners(t.radii.inner)

## --- dropdowns -----------------------------------------------------------------------
##
## The single-choice combo and the multi-select share everything except the
## rows inside their popovers: the open/closed bookkeeping, the summary
## field, the floating clipped panel, the option-row chrome. One dropdown
## may be open at a time across the set -- `toggleDropdown` owns that slot.

var openDropdownId = 0'u32

proc toggleDropdown*(id, popId: ElementId): bool =
  ## Fold this frame's click into the open-dropdown slot: a click on the
  ## field toggles it, a click off both the field and its popover dismisses.
  ## Returns whether `id`'s dropdown is open *after* the click.
  if pressedNow():
    if pointerOver(id):
      openDropdownId = if openDropdownId == id.id: 0'u32 else: id.id
    elif openDropdownId == id.id and not pointerOver(popId):
      openDropdownId = 0'u32
  openDropdownId == id.id

proc closeDropdown*() =
  ## Dismiss the open dropdown (an option click usually does this).
  openDropdownId = 0'u32

proc dropdownField*(id: ElementId, isOpen: bool, shown: string,
                    shownColor: Color, width: SizingAxis, height: SizingAxis) =
  ## The combo-style summary field: a raised `padButton` row ringed in
  ## accent while open, holding `shown`, a `spacer`, and the `chevron`.
  let t = activeTheme
  openElement(id)
  configureOpenElement(row(width = width, height = height, gap = 8,
    padding = padAll(t.metrics.padButton), alignY = centerY)
    .bg(shade(pointerOver(id) or isOpen))
    .corner(t.radii.field)
    .border(t.metrics.borderHairline,
      if isOpen: t.palette.accent else: t.palette.panelBorder))
  textElement(shown, TextConfig(fontSize: t.text.control,
    color: shownColor, wrap: noWrap))
  spacer()
  chevron(isOpen)
  closeElement()

proc dropdownPanelDecl*(anchor: ElementId, maxHeight: float32):
    ElementDeclaration =
  ## The floating option-panel declaration `dropdownPanel` configures:
  ## a `padList` column capped at `maxHeight`, clipped and scrolled
  ## vertically, attached under `anchor`'s bottom edge at dropdown z-level.
  let t = activeTheme
  col(gap = t.metrics.gapList,
      padding = padAll(t.metrics.padList),
      width = pct(1.0), height = fit(max = maxHeight))
    .bg(t.palette.panelBg)
    .border(t.metrics.borderHairline, t.palette.panelBorder)
    .corner(t.radii.popover)
    .floating(attachElementId,
      offset = vec2(0.0, t.metrics.popoverOffset), zIndex = 200,
      points = AttachPoints(element: pointLeftTop,
                            parent: pointLeftBottom),
      parentId = anchor.id,
      fitViewport = true)
    .clip(horizontal = false, vertical = true,
          childOffset = currentScrollOffset())

template dropdownPanel*(popId: untyped, anchor: untyped, maxHeight: untyped,
                        body: untyped): untyped =
  ## The floating option panel hanging under a dropdown field: `popId`'s
  ## clip/scroll column, `maxHeight` tall at most, attached to `anchor`'s
  ## bottom edge; `body` declares the rows. Call `scrollbar(popId, popId)`
  ## at the end of `body` to attach the bar (popovers scroll themselves).
  block:
    openElement(popId)
    configureOpenElement(dropdownPanelDecl(anchor, maxHeight))
    body
    closeElement()

template optionRow*(id: untyped, selected: untyped, gap: untyped,
                    alignY: untyped, body: untyped): untyped =
  ## A themed dropdown option row with an explicit `id`: `body` declares
  ## the row's content *while the row is open*, so it can fold this
  ## frame's pick in with `pressedNow() and hovered()` -- a tick can flip
  ## in the very frame it is hit. `gap`/`alignY` are the row layout knobs
  ## content-heavy rows vary.
  block:
    openElement(id)
    configureOpenElement(optionRowDecl(hovered(), selected, gap, alignY))
    body
    closeElement()

template optionRow*(id: untyped, selected: untyped, body: untyped): untyped =
  ## `optionRow` with the default row layout.
  optionRow(id, selected, 0, top, body)

## --- composite widgets -----------------------------------------------------------

widget Labeled(label: string, control: proc(): void):
  ## A field label above its control:
  ##
  ##   Labeled(label = "Name"):
  ##     name = textField(hashId("name"), name)
  ##
  ## The trailing block fills `control`, so the assignment can capture the
  ## caller's locals.
  openElement()
  let t = activeTheme
  configureOpenElement(col(width = grow(), gap = t.metrics.gapTight,
      padding = padAll(t.metrics.padMinor)))
  textElement(label, TextConfig(fontSize: t.text.label, color: t.palette.labelColor))
  control()
  closeElement()
