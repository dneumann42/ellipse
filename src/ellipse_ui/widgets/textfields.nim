## Text entry fields. `textField` edits a caller-owned string through the
## shared caret/selection engine in `common`: click focuses, typing mutates,
## Enter commits (leaves the field), Escape reverts to the value the field
## was focused with. Editing keys follow the Emacs/readline default map --
## C-a/C-e, C-b/C-f, M-b/M-f, C-k/C-u/C-w/C-y, C-g -- see `common`.
##
## The returned string is what the caller stores back every frame --
## intermediate edits are already visible in it; commit only moves focus.

import clay
import ../ui

import ellipse/platform/platform   ## KeyEvent/kevEnter for the multiline remap
import ./common

proc textField*(id: ElementId, text: string, placeholder = "",
                fontSize: uint16 = activeTheme.text.control, width = grow(),
                height = fixedPx(activeTheme.metrics.controlHeight)): string =
  result = text

  let wasFocused = focused(id)
  if clickedIn(id):
    if not wasFocused:
      focus(id, text)
  elif wasFocused and clickedOut(id):
    blur()

  var edited = result
  if focused(id):
    let step = editStep(result)
    edited = step.text
    if step.outcome == eoCommit or step.outcome == eoCancel:
      if step.outcome == eoCancel:
        edited = snapshotValue()
      blur()
  result = edited

  let t = activeTheme
  openElement(id)
  configureOpenElement(row(width = width, height = height,
      padding = Padding(left: t.metrics.padFieldX, right: t.metrics.padFieldX,
                        top: t.metrics.padFieldY, bottom: t.metrics.padFieldY),
      alignY = centerY)
    .bg(t.palette.fieldBg)
    .corner(t.radii.field)
    .border(t.metrics.borderHairline, fieldBorder(id)))

  var shown = edited
  var color = textColor
  if not focused(id) and shown.len == 0:
    shown = placeholder
    color = dimColor
  let cfg = TextConfig(fontSize: fontSize, color: color, wrap: noWrap)
  textElement(shown, cfg)
  if focused(id):
    caretOverlay(textChildId(id.id), edited, cfg)
  closeElement()

proc multilineField*(id: ElementId, text: string, placeholder = "",
                     fontSize: uint16 = activeTheme.text.control, rows: int = 4,
                     width = grow()): string =
  ## The same edit engine over a taller, word-wrapped box. Enter inserts a
  ## newline instead of committing; a click outside leaves the field.
  result = text

  let wasFocused = focused(id)
  if clickedIn(id):
    if not wasFocused:
      focus(id, text)
  elif wasFocused and clickedOut(id):
    blur()

  var edited = result
  if focused(id):
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
  result = edited

  let t = activeTheme
  openElement(id)
  configureOpenElement(col(width = width,
      height = fixedPx(float32(rows) * t.metrics.textRowHeight),
      padding = Padding(left: t.metrics.padFieldX, right: t.metrics.padFieldX,
                        top: t.metrics.padFieldY, bottom: t.metrics.padFieldY))
    .bg(t.palette.fieldBg)
    .corner(t.radii.field)
    .border(t.metrics.borderHairline, fieldBorder(id)))
  let cfg = TextConfig(fontSize: fontSize, color: t.palette.textColor)
  if edited.len == 0 and not focused(id):
    textElement(placeholder,
      TextConfig(fontSize: fontSize, color: t.palette.dimColor))
  else:
    textElement(edited, cfg)
  if focused(id):
    caretOverlay(textChildId(id.id), edited, cfg)
  closeElement()
