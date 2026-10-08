## Numeric entry: a text field that parses, clamps and steps.
##
## While unfocused the field shows the caller's value formatted plainly;
## focusing it seeds an editable digit buffer (the shared caret engine, with
## a `0-9 . -` filter). Enter commits the parse + clamp, Escape discards the
## buffer, and leaving the field (a click outside, Tab) commits too.
## Up/Down arrows and the hover steppers add/subtract `step` immediately.
##
## The field box is `ui.item` over `common.fieldDecl`; the steppers are
## plain items over `shadeDecl`, so they share the small-button look with
## the multiselect footer.
##
## Events: `numberField` emits `NumberChanged` whenever its value moves;
## `intNumberField` catches that and emits `IntChanged` instead.

import clay
import ../ui

import ellipse/platform/platform
import ./common

var numBuffer = ""
var numBufferId = 0'u32

func clampTo(v, lo, hi: float): float =
  min(max(v, lo), hi)

func roundToInt(v: float): int =
  result = if v >= 0.0: int(v + 0.5) else: int(v - 0.5)

func fmtVal(v: float, whole: bool): string =
  ## `whole` -- the int view -- drops the fraction `$` gives a float.
  if whole:
    return $roundToInt(v)
  return $v

proc validDigitChar(c: char): bool =
  c >= '0' and c <= '9' or c == '.' or c == '-'

type NumResult = object
  ok: bool = false
  value: float = 0.0

proc parseNum(s: string): NumResult =
  ## Minimal float reader for the digit buffer (the stdlib has no
  ## `parseFloat`): optional sign, digits, optional fraction. Anything else
  ## -- empty, a lone `-`, letters -- reports `ok == false`.
  result = NumResult()
  if s.len == 0:
    return
  var i = 0
  var sign = 1.0
  if s[i] == '-':
    sign = -1.0
    inc i
  elif s[i] == '+':
    inc i
  var digits = 0
  var fracSeen = false
  var fracScale = 0.1
  var whole = 0.0
  var frac = 0.0
  while i < s.len:
    let c = s[i]
    if c >= '0' and c <= '9':
      let d = float(ord(c) - ord('0'))
      if fracSeen:
        frac += d * fracScale
        fracScale *= 0.1
      else:
        whole = whole * 10.0 + d
      inc digits
    elif c == '.' and not fracSeen:
      fracSeen = true
    else:
      return
    inc i
  if digits == 0:
    return
  result.value = sign * (whole + frac)
  result.ok = true

proc sanitizeNum(buf: string, allowNeg: bool): string =
  ## Keep digits, one leading sign and one decimal point, dropping whatever
  ## the key filter let past a mid-edit caret.
  result = ""
  var dots = 0
  var i = 0
  while i < buf.len:
    let c = buf[i]
    if c >= '0' and c <= '9':
      result.add c
    elif c == '.' and dots < 1:
      inc dots
      result.add c
    elif c == '-' and allowNeg and i == 0:
      result.add c
    else:
      discard
    inc i

proc stepper(id: ElementId, glyph: string) =
  ## One +/- square: `shadeDecl` surface, centred control-size glyph. The
  ## click is folded in by the caller *before* drawing, so the adjusted
  ## value shows in the field's text the same frame.
  let t = activeTheme
  item(id, shadeDecl(id, fixedPx(t.metrics.stepperSize),
      fixedPx(t.metrics.stepperSize), dir = topToBottom,
      alignX = centerX, alignY = centerY)):
    textElement(glyph, TextConfig(fontSize: t.text.control,
      color: t.palette.textColor))

widget focusable numberField(value: float, step = 1.0,
                  minVal = -1.0e9, maxVal = 1.0e9, whole = false,
                  width = grow(),
                  height = fixedPx(activeTheme.metrics.controlHeight)) -> float:
  emits NumberChanged
  result = value

  let decId = localId("num.dec", id.id)
  let incId = localId("num.inc", id.id)

  # Click or Tab focuses (see `ellipse_ui/focus`; the `focusable` widget
  # registers before this body). Focus leaving while the digit buffer is
  # live -- a click elsewhere, Tab -- commits it; focus arriving seeds it
  # from the caller's value.
  if numBufferId == id.id and not focused(id):
    let p = parseNum(numBuffer)
    if p.ok:
      result = clampTo(p.value, minVal, maxVal)
    numBufferId = 0'u32
  if focused(id) and (numBufferId != id.id or not caretSeeded(id)):
    numBuffer = fmtVal(value, whole)
    numBufferId = id.id
    focus(id, numBuffer)

  if focused(id) and numBufferId == id.id:
    let step0 = editStep(numBuffer, validDigitChar)
    numBuffer = sanitizeNum(step0.text, minVal < 0.0)
    syncCaret(numBuffer.len)
    let evs = keyEvents()
    for ev in evs:
      if ev.kind == kevUp:
        result = clampTo(result + step, minVal, maxVal)
        numBuffer = fmtVal(result, whole)
      elif ev.kind == kevDown:
        result = clampTo(result - step, minVal, maxVal)
        numBuffer = fmtVal(result, whole)
    if step0.outcome == eoCommit:
      let p = parseNum(numBuffer)
      if p.ok:
        result = clampTo(p.value, minVal, maxVal)
        numBuffer = fmtVal(result, whole)
      numBufferId = 0'u32
      blur()
    elif step0.outcome == eoCancel:
      numBuffer = fmtVal(value, whole)
      numBufferId = 0'u32
      blur()

  # steppers: children of the field box, so a click on them is also a click
  # inside (handled above) -- they adjust whether or not the field is open.
  if pressedNow():
    if pointerOver(decId):
      result = clampTo(result - step, minVal, maxVal)
      if focused(id):
        numBuffer = fmtVal(result, whole)
    elif pointerOver(incId):
      result = clampTo(result + step, minVal, maxVal)
      if focused(id):
        numBuffer = fmtVal(result, whole)

  let t = activeTheme
  item(id, fieldDecl(id, width, height, gap = t.metrics.gapTight,
      alignY = centerY,
      padding = Padding(left: t.metrics.padFieldX, right: t.metrics.padFieldY,
                        top: t.metrics.padFieldY, bottom: t.metrics.padFieldY))):
    container(row(width = grow(), height = fit(), alignX = right)):
      let cfg = TextConfig(fontSize: t.text.control, color: t.palette.textColor,
        wrap: noWrap, justify: justifyRight)
      textElement(keepLine(if focused(id): numBuffer else: fmtVal(result, whole)),
                  cfg)
      if focused(id):
        caretOverlay(textChildId(textChildId(id.id)), numBuffer, cfg)
    stepper(decId, "-")
    stepper(incId, "+")
  if result != value:
    emit NumberChanged(id: id, value: result)

widget intNumberField(id: ElementId, value: int, step = 1,
                     minVal = -1000000000, maxVal = 1000000000,
                     width = grow(),
                     height = fixedPx(activeTheme.metrics.controlHeight),
                     tabIndex = 0) -> int:
  ## Whole-number view of `numberField`: formats without a fraction and
  ## rounds what comes back. The inner field's `NumberChanged` is
  ## translated into an `IntChanged` for code further up.
  emits IntChanged(id: ElementId, value: int)
  event NumberChanged(e):
    emit IntChanged(id: e.id, value: roundToInt(e.value))
  let raw = numberField(id, float(value), float(step), float(minVal),
    float(maxVal), true, width, height, tabIndex)
  result = roundToInt(raw)
