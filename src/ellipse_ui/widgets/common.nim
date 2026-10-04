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
## Keyboard and wheel input arrives through `ellipse/platform/platform`'s
## per-frame event queues; `updateUI` advances them, and `editStep` applies
## one frame's events to the focused field.

import std/[monotimes, strutils]

import clay
import ../ui

import ellipse/platform/platform

const
  accent* = rgb(96, 130, 220)      ## focus rings, checked boxes, links
  fieldBg* = rgb(20, 22, 28)       ## text-field and dropdown interiors
  selectedBg* = rgb(64, 70, 92)    ## the chosen row in an option list
  dimColor* = rgb(130, 134, 150)   ## placeholders, captions, hints
  labelColor* = rgb(180, 184, 196) ## field labels and secondary text

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
  configureOpenElement(col(width = grow(), gap = 6, padding = padAll(4)))
  textElement(label, TextConfig(fontSize: 15, color: labelColor))
  control()
  closeElement()
