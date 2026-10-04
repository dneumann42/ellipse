## Text entry fields. `textField` edits a caller-owned string through the
## shared caret/selection engine in `common`: click focuses, typing mutates,
## Enter commits (leaves the field), Escape reverts to the value the field
## was focused with.
##
## The returned string is what the caller stores back every frame --
## intermediate edits are already visible in it; commit only moves focus.

import clay
import ../ui

import ellipse/platform/platform   ## KeyEvent/kevEnter for the multiline remap
import ./common

proc textField*(id: ElementId, text: string, placeholder = "",
                fontSize: uint16 = 18, width = grow(),
                height = fixedPx(40)): string =
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

  openElement(id)
  configureOpenElement(row(width = width, height = height,
      padding = Padding(left: 10, right: 10, top: 8, bottom: 8),
      alignY = centerY)
    .bg(fieldBg)
    .corner(8)
    .border(1, fieldBorder(id)))

  var shown = edited
  var color = textColor
  if focused(id):
    shown = displayText(shown)
  elif shown.len == 0:
    shown = placeholder
    color = dimColor
  textElement(shown, TextConfig(fontSize: fontSize, color: color,
    wrap: noWrap))
  closeElement()

proc multilineField*(id: ElementId, text: string, placeholder = "",
                     fontSize: uint16 = 18, rows: int = 4,
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
    # Remap Enter to a newline so the shared engine treats it as text.
    var frame: seq[KeyEvent] = @[]
    let evs = keyEvents()
    for ev in evs:
      if ev.kind == kevEnter:
        frame.add KeyEvent(kind: kevText, text: "\n")
      else:
        frame.add ev
    let step = editStepWith(edited, frame)
    edited = step.text
    syncCaret(edited.len)
  result = edited

  openElement(id)
  configureOpenElement(col(width = width,
      height = fixedPx(float32(rows) * 26.0),
      padding = Padding(left: 10, right: 10, top: 8, bottom: 8))
    .bg(fieldBg)
    .corner(8)
    .border(1, fieldBorder(id)))
  if edited.len == 0 and not focused(id):
    textElement(placeholder, TextConfig(fontSize: fontSize, color: dimColor))
  elif edited.len == 0:
    textElement(displayText(""), TextConfig(fontSize: fontSize,
      color: textColor))
  else:
    var shown = edited
    if focused(id):
      shown = displayText(shown)
    textElement(shown, TextConfig(fontSize: fontSize, color: textColor))
  closeElement()
