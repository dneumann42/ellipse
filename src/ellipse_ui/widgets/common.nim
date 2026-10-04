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
##    like `menu`'s `openMenuId`.
##
## Keyboard and wheel input arrives through `ellipse/platform/platform`'s
## per-frame event queues; `updateUI` advances them, and `editStep` applies
## one frame's events to the focused field.

import std/[monotimes]

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
## deletes it) but not painted: the renderer draws one colour per text
## element, so the caret glyph is a `|` spliced into the string.

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

proc applyKeys(text: sink string, evs: seq[KeyEvent],
               valid: ValidCharFn): EditResult =
  ## The shared edit loop over an explicit event list; caret/selection state
  ## is module-private and belongs to whichever field holds focus.
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
    of kevBackspace:
      if selHi() > selLo():
        splice(s, selLo(), selHi(), "")
      elif caret > 0:
        var pos = caret - 1
        while pos > 0 and isContByte(s[pos]):
          dec pos
        splice(s, pos, caret, "")
    of kevDelete:
      if selHi() > selLo():
        splice(s, selLo(), selHi(), "")
      elif caret < s.len:
        var pos = caret + 1
        while pos < s.len and isContByte(s[pos]):
          inc pos
        splice(s, caret, pos, "")
    of kevLeft:
      moveCaret(s, -1, ev.shift)
    of kevRight:
      moveCaret(s, 1, ev.shift)
    of kevHome:
      caret = 0
      if not ev.shift:
        selAnchor = 0
    of kevEnd:
      caret = s.len
      if not ev.shift:
        selAnchor = s.len
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

proc displayText*(text: string): string =
  ## `text` with the caret glyph spliced in at the cursor; while the caret's
  ## a selection, the selection range is not painted (see the note above).
  if not caretVisible():
    return text
  let pos = min(max(caret, 0), text.len)
  result = ""
  var i = 0
  while i < pos:
    result.add text[i]
    inc i
  result.add "|"
  while i < text.len:
    result.add text[i]
    inc i

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
