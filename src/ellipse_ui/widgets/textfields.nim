## Text entry fields. See `documentation/nim-tutorial.md` §6.5 (Text fields
## and the editor).
{.push gcsafe.}


import clay
import ../ui

import ellipse/platform/platform   ## KeyEvent/kevEnter for the multiline remap
import ./common
import ./scrollbars

widget textField(id: ElementId, text: string, placeholder = "",
                fontSize = activeTheme.text.control, width = grow(),
                height = fixedPx(activeTheme.metrics.controlHeight),
                tabIndex = 0) -> string:
  emits TextChanged
  emits TextCommitted
  var edited = text
  var committed = false
  if fieldFocus(id, text, tabIndex):
    let step = editStep(text)
    edited = step.text
    committed = step.outcome == eoCommit
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
  # emit before `result = edited`: that assignment may move `edited` out
  if edited != text:
    emit TextChanged(id: id, text: edited)
  if committed:
    emit TextCommitted(id: id, text: edited)
  result = edited

widget multilineField(id: ElementId, text: string, placeholder = "",
                      fontSize = activeTheme.text.control, rows = 4,
                      maxLines = 8, width = grow(), tabIndex = 0) -> string:
  ## The same edit engine over a word-wrapped box that grows with its
  ## text: at least `rows` lines tall, at most `maxLines` (0: no cap).
  ## Past the cap the text scrolls -- wheel, scrollbar, and the caret
  ## pulls its line into view. Enter inserts a newline instead of
  ## committing; a click outside (or Tab) leaves the field.
  emits TextChanged
  var edited = text
  if fieldFocus(id, text, tabIndex):
    # Remap Enter (and C-m) to a newline so the shared engine treats it as
    # text; everything else -- Emacs chords included -- flows through.
    var frame: seq[KeyEvent] = @[]
    let evs = frameKeys()
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
  let textEl = ElementId(id: textChildId(id.id))
  let pitch = linePitch(cfg)
  let padY = float32(t.metrics.padFieldY)
  let minH = float32(max(rows, 1)) * pitch + 2.0 * padY
  let maxH = if maxLines > 0: max(float32(maxLines) * pitch + 2.0 * padY, minH)
             else: 0.0'f32
  item(id, fieldDecl(id, width, fit(min = minH, max = maxH),
      dir = topToBottom)
      .clip(horizontal = false, vertical = true,
            childOffset = currentScrollOffset())):
    textElement(shown, TextConfig(fontSize: fontSize, color: color))
    if focused(id):
      let wrapW = wrapWidthIn(id, float32(t.metrics.padFieldX))
      caretOverlay(textEl.id, edited, cfg, wrapWidth = wrapW)
      scrollCaretIntoView(id, textEl, edited, cfg, caretPos(),
                          float32(t.metrics.padFieldX), padY,
                          wrapWidth = wrapW)
    scrollbar(localId("multiline.bar"), id)
  if edited != text:
    emit TextChanged(id: id, text: edited)
  result = edited
