## Text entry fields. `textField` edits a caller-owned string through the
## shared caret/selection engine in `common`: click focuses (the
## `fieldFocus` pair of edges), typing mutates, Enter commits (leaves the
## field), Escape reverts to the value the field was focused with. Editing
## keys follow the Emacs/readline default map -- C-a/C-e, C-b/C-f, M-b/M-f,
## C-k/C-u/C-w/C-y, C-g -- see `common`.
##
## The returned string is what the caller stores back every frame --
## intermediate edits are already visible in it; commit only moves focus.
## The field box itself is `ui.item` over `common.fieldDecl`, the
## placeholder pick is `common.fieldText`.

import clay
import ../ui

import ellipse/platform/platform   ## KeyEvent/kevEnter for the multiline remap
import ./common

proc textField*(id: ElementId, text: string, placeholder = "",
                fontSize: uint16 = activeTheme.text.control, width = grow(),
                height = fixedPx(activeTheme.metrics.controlHeight)): string =
  var edited = text
  if fieldFocus(id, text):
    let step = editStep(text)
    edited = step.text
    if step.outcome == eoCommit or step.outcome == eoCancel:
      if step.outcome == eoCancel:
        edited = snapshotValue()
      blur()

  let (shown, color) = fieldText(edited, placeholder, focused(id))
  let cfg = TextConfig(fontSize: fontSize, color: color, wrap: noWrap)
  item(id, fieldDecl(id, width, height, alignY = centerY)):
    textElement(shown, cfg)
    if focused(id):
      caretOverlay(textChildId(id.id), edited, cfg)
  result = edited

proc multilineField*(id: ElementId, text: string, placeholder = "",
                     fontSize: uint16 = activeTheme.text.control, rows: int = 4,
                     width = grow()): string =
  ## The same edit engine over a taller, word-wrapped box. Enter inserts a
  ## newline instead of committing; a click outside leaves the field.
  var edited = text
  if fieldFocus(id, text):
    # Remap Enter (and C-m) to a newline so the shared engine treats it as
    # text; everything else -- Emacs chords included -- flows through.
    var frame: seq[KeyEvent] = @[]
    let evs = keyEvents()
    for ev in evs:
      if ev.kind == kevEnter or
          (ev.kind == kevLetter and ev.ctrl and ev.ch == 'm'):
        frame.add KeyEvent(kind: kevText, text: "\n")
      else:
        frame.add ev
    let step = editStepWith(edited, frame)
    edited = step.text
    syncCaret(edited.len)

  let t = activeTheme
  let cfg = TextConfig(fontSize: fontSize, color: t.palette.textColor)
  let (shown, color) = fieldText(edited, placeholder, focused(id))
  item(id, fieldDecl(id, width,
      fixedPx(float32(rows) * t.metrics.textRowHeight), dir = topToBottom)):
    textElement(shown, TextConfig(fontSize: fontSize, color: color))
    if focused(id):
      caretOverlay(textChildId(id.id), edited, cfg)
  result = edited
