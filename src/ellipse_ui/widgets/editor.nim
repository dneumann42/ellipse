## The full text-editing surface -- the document area a Notepad-style app
## edits. See `documentation/nim-tutorial.md` §6.5 (Text fields and the
## editor) and `documentation/reference-widgets.md` §3.9.

import std/[math, monotimes, strutils]

import clay
import ../ui

import ellipse/platform/platform
import ./common
import ./scrollbars

const
  undoLimit = 512        ## snapshots kept per direction
  groupGapMs = 600       ## same-kind edits this close coalesce into one undo
  editorPad = 4          ## the text area's inset (px)

type
  EditorOpts* = object
    ## Knobs of the document area.
    wrap*: bool = true     ## word wrap, or an endlessly wide h-scrollable page
    fontSize*: uint16 = 0  ## 0 = the live theme's `control` size (zoom lives here)
    blocked*: bool = false ## a modal owns keyboard & pointer: paint-only
    readOnly*: bool = false
    maxLines*: int = 0     ## 0: fill the parent, scrolling once the text
                           ## outgrows it; N: hug the text, up to N lines
    indent*: string = "    "  ## what Tab inserts (and Shift+Tab takes off a
                              ## line's front); "" leaves Tab alone
    autoIndent*: bool = false ## Enter copies the line's leading whitespace
    indentAfter*: string = "" ## with `autoIndent`: a line ending in this
                              ## (":" for owl, "{" for C) indents one
                              ## `indent` deeper
    fontId*: uint16 = 0    ## `MonoFont` for code

  EditorStats* = object
    ## What one editor frame produced.
    text*: string           ## store this back over the caller's copy
    edited*: bool           ## the text changed (drive the dirty flag from it)
    caretMoved*: bool       ## caret or selection moved (drive a status bar)
    undoable*: bool
    redoable*: bool

  Snap = object
    text: string
    caret: int
    anchor: int

var
  histId = 0'u32       ## the editor the undo history belongs to
  undoStack: seq[Snap] = @[]
  redoStack: seq[Snap] = @[]
  groupTick = 0'i64    ## when the current undo group last took an edit
  groupKind = 0        ## 1 grew, 2 shrank, 3 replaced -- what coalesces
  mOwner = 0'u32       ## the position mirror: which editor it belongs to
  mCaret = 0
  mAnchor = 0
  pendingUndo = false  ## menu requests that arrive between frames
  pendingRedo = false

## --- position mirror ------------------------------------------------------------
##
## The engine's caret/anchor are global and belong to whatever widget holds
## focus; `editor` copies them out every frame it is live and answers from
## the copy otherwise. The public setters write both halves, so a dialog
## can hold the keyboard while search still resolves against the document.

proc editorCaret*(id: ElementId, text: string): int =
  if focused(id):
    result = min(caretPos(), text.len)
  elif mOwner == id.id:
    result = min(mCaret, text.len)
  else:
    result = 0

proc editorAnchor*(id: ElementId, text: string): int =
  if focused(id):
    result = min(anchorPos(), text.len)
  elif mOwner == id.id:
    result = min(mAnchor, text.len)
  else:
    result = editorCaret(id, text)

proc editorSel*(id: ElementId, text: string): tuple[lo, hi: int] =
  ## The editor's selection as a half-open range, empty when collapsed --
  ## live or remembered, whichever applies.
  let c = editorCaret(id, text)
  let a = editorAnchor(id, text)
  (min(c, a), max(c, a))

func lineCol*(text: string, pos: int): tuple[line, col: int] =
  ## The 1-based line and column of `pos` in the buffer -- the status-bar
  ## readout every text editor shows for its caret. Pure: any string, any
  ## offset, no widget state involved.

  ## Count lines walked and the last line's start as one forward scan.
  var ln = 1
  var bol = 0
  var i = 0
  while i < pos and i < text.len:
    if text[i] == '\n':
      inc ln
      bol = i + 1
    inc i
  (ln, pos - bol + 1)

func countLines*(text: string): int =
  ## The buffer's logical line count -- 1 for empty text, one more per
  ## newline after it.
  result = 1
  for c in text:
    if c == '\n':
      inc result

proc editorSetCarets*(id: ElementId, text: string, c, a: int) =
  ## Park caret and anchor (clamped) on the editor, engine included while
  ## it holds focus, mirror always.
  let x = min(max(c, 0), text.len)
  let y = min(max(a, 0), text.len)
  mOwner = id.id
  mCaret = x
  mAnchor = y
  if focused(id):
    setCarets(text, x, y)

proc editorSelect*(id: ElementId, text: string, lo, hi: int) =
  ## Select the half-open range `[lo, hi)`, caret at `hi` -- what Find
  ## hits and Select All do.
  editorSetCarets(id, text, hi, lo)

proc editorPlaceCaret*(id: ElementId, text: string, pos: int) =
  editorSelect(id, text, pos, pos)

proc editorRestoreFocus*(id: ElementId, text: string) =
  ## Take the keyboard back for the editor without disturbing its
  ## remembered position -- the seam for closing a modal dialog.
  refocus(id, text)
  mOwner = id.id
  setCarets(text, mCaret, mAnchor)

proc snapFrom(id: ElementId, text: string): Snap =
  Snap(text: text, caret: editorCaret(id, text), anchor: editorAnchor(id, text))

## --- history -------------------------------------------------------------------

proc nowMs(): int64 =
  getMonoTime().ticks div 1_000_000'i64

proc pushEdit(id: ElementId, prev: Snap, changed: string) =
  ## Record the pre-edit state, coalescing a run of same-kind keystrokes
  ## into one undo step -- typing a word undoes as a word, Notepad style,
  ## while a pause or a change of direction opens a fresh group. Any new
  ## edit clears the redo stack, and history follows the editing editor.
  if histId != id.id:
    histId = id.id
    undoStack.setLen(0)
    redoStack.setLen(0)
  let kind =
    if changed.len > prev.text.len: 1
    elif changed.len < prev.text.len: 2
    else: 3
  let now = nowMs()
  if groupKind != kind or now - groupTick > groupGapMs:
    undoStack.add(prev)
    if undoStack.len > undoLimit:
      undoStack.delete(0)
    groupKind = kind
  groupTick = now
  redoStack.setLen(0)

proc takeUndo(id: ElementId, text: var string): bool =
  if histId != id.id or undoStack.len == 0:
    return false
  redoStack.add(snapFrom(id, text))
  if redoStack.len > undoLimit:
    redoStack.delete(0)
  let s = undoStack.pop()
  text = s.text
  editorSetCarets(id, text, s.caret, s.anchor)
  groupKind = 0   ## the next edit always opens a fresh undo step
  true

proc takeRedo(id: ElementId, text: var string): bool =
  if histId != id.id or redoStack.len == 0:
    return false
  undoStack.add(snapFrom(id, text))
  let s = redoStack.pop()
  text = s.text
  editorSetCarets(id, text, s.caret, s.anchor)
  groupKind = 0
  true

proc editorRequestUndo*() =
  ## Ask the next `editor` frame to undo: the seam for a menu or toolbar
  ## button clicked while the editor is not the widget about to run.
  pendingUndo = true

proc editorRequestRedo*() =
  pendingRedo = true

proc editorUndo*(id: ElementId, text: var string): bool =
  ## Undo directly, menu-style -- caret and selection come back with it.
  takeUndo(id, text)

proc editorRedo*(id: ElementId, text: var string): bool =
  takeRedo(id, text)

proc editorUndoable*(): bool =
  ## Menu-state: something sits in the history.
  undoStack.len > 0

proc editorRedoable*(): bool =
  redoStack.len > 0

proc editorClearHistory*() =
  ## Wipe the undo/redo bookkeeping -- called when the document itself is
  ## swapped underneath the editor (New / Open), so an undo can never
  ## resurrect a different file's text.
  histId = 0'u32
  undoStack.setLen(0)
  redoStack.setLen(0)
  groupKind = 0

## --- menu-side edit acts -----------------------------------------------------------
##
## The Edit menu's Copy / Cut / Paste / Delete / Select All drive the very
## engine the chords do, but resolve their range and caret through the
## mirror, so they stay correct in a frame where a dialog field or the
## menu bar itself has stolen focus. Each text-changing act is one undo
## group, indistinguishable from typing it.

func rangeText*(text: string, lo, hi: int): string =
  substr(text, lo, hi - 1)

proc editRange*(text: var string, lo, hi: int, ins: string): int =
  ## Splice `ins` over `[lo, hi)` and return the caret offset after it.
  var outp = substr(text, 0, lo - 1)
  outp.add ins
  outp.add substr(text, hi, text.len - 1)
  text = outp
  lo + ins.len

func clipText(s: string): string =
  ## Clipboard text sanitised for an editor: carriage returns are the
  ## newline half of CRLF -- the buffer speaks plain LF.
  result = ""
  for c in s:
    if c != '\r':
      result.add c

proc editorCopy*(id: ElementId, text: string) =
  let (lo, hi) = editorSel(id, text)
  if hi > lo:
    setClipboard(rangeText(text, lo, hi))

proc editorCut*(id: ElementId, text: var string) =
  let (lo, hi) = editorSel(id, text)
  if hi > lo:
    let prev = snapFrom(id, text)
    setClipboard(rangeText(text, lo, hi))
    let pos = editRange(text, lo, hi, "")
    editorPlaceCaret(id, text, pos)
    pushEdit(id, prev, text)

proc editorPaste*(id: ElementId, text: var string) =
  let ins = clipText(getClipboard())
  if ins.len == 0:
    return
  let (lo, hi) = editorSel(id, text)
  let prev = snapFrom(id, text)
  let pos = editRange(text, lo, hi, ins)
  editorPlaceCaret(id, text, pos)
  pushEdit(id, prev, text)

proc editorDelete*(id: ElementId, text: var string) =
  let (lo, hi) = editorSel(id, text)
  if hi > lo:
    let prev = snapFrom(id, text)
    discard editRange(text, lo, hi, "")
    editorPlaceCaret(id, text, lo)
    pushEdit(id, prev, text)

proc editorSelectAll*(id: ElementId, text: string) =
  editorSelect(id, text, 0, text.len)

proc editorInsert*(id: ElementId, text: var string, ins: string) =
  ## Splice `ins` in at the editor's caret with a history entry -- the
  ## seam for Notepad's F5 date/time stamp.
  let (lo, _) = editorSel(id, text)
  let prev = snapFrom(id, text)
  let pos = editRange(text, lo, lo, ins)
  editorPlaceCaret(id, text, pos)
  pushEdit(id, prev, text)

proc editorReplaceRange*(id: ElementId, text: var string, lo, hi: int,
                         ins: string): int =
  ## Replace `text[lo..<hi]` with `ins` as one undo step, caret after the
  ## insertion. Replace / Replace All use this.
  if hi < lo or hi > text.len:
    return editorCaret(id, text)
  let prev = snapFrom(id, text)
  let pos = editRange(text, lo, hi, ins)
  editorPlaceCaret(id, text, pos)
  if text != prev.text:
    pushEdit(id, prev, text)
  pos

proc editorSetAll*(id: ElementId, text: var string, replacement: string,
                   caretAt = 0) =
  ## Swap the whole buffer (opening a file through the engine path, a
  ## Replace-All built out-of-band) with a single undo entry.
  if replacement == text:
    return
  let prev = snapFrom(id, text)
  text = replacement
  pushEdit(id, prev, text)
  editorPlaceCaret(id, text, caretAt)

## --- line grid ------------------------------------------------------------------
##
## Clay wraps text between its sizing passes; `wrappedLines` re-runs that
## pass for any box width. An editor's text element is laid out at either
## the viewport width (wrap) or its own unwrapped width (no wrap), so
## `gridWidth` -- the viewport's inner width, or the text box's own --
## yields *exactly* the line grid the renderer draws -- what the caret
## geometry, the selection rectangles, the pointer hit-test and the
## scroll-follow all agree on. (Not the text box's last width when
## wrapping: that is the *old* text's, a glyph short of a just-typed line.)

proc barsAlways(opts: EditorOpts): bool =
  ## A page-filling editor keeps its scrollbars up whether or not the text
  ## overflows; one that hugs its text (`maxLines`) shows them on demand.
  opts.maxLines == 0

proc editorPadding(opts: EditorOpts): Padding =
  ## The text area's inset, plus a gutter along each edge a scrollbar
  ## always sits on, so the text never runs underneath the bar.
  let sb = activeTheme.scrollbar
  let gutter = int(ceil(sb.width + sb.margin))
  result = padAll(editorPad)
  if barsAlways(opts):
    result.right = editorPad + gutter
    if not opts.wrap:
      result.bottom = editorPad + gutter

proc gutterStrip(id: ElementId, vertical: bool, thick: float32) =
  ## Back a scrollbar gutter with the field's own fill, floated over the
  ## text (an unwrapped line scrolls sideways under the gutter, which the
  ## container's clip doesn't stop) and under the bar itself (zIndex 220).
  let t = activeTheme
  let d = elementData(id)
  if not d.found:
    return
  let inset = float32(t.metrics.borderHairline)
  let (w, h) = if vertical: (thick, d.box.height - 2.0 * inset)
               else: (d.box.width - 2.0 * inset, thick)
  let (points, offset) = if vertical:
    (AttachPoints(element: pointRightTop, parent: pointRightTop),
     vec2(-inset, inset))
  else:
    (AttachPoints(element: pointLeftBottom, parent: pointLeftBottom),
     vec2(inset, -inset))
  openElement(localId(if vertical: "editor.vgutter" else: "editor.hgutter",
    id.id))
  configureOpenElement(col(width = fixedPx(max(w, 0.0)),
                           height = fixedPx(max(h, 0.0)))
    .bg(t.palette.fieldBg)
    .floating(attachElementId, offset = offset, zIndex = 210,
              points = points, parentId = id.id,
              capture = passThroughPointer))
  closeElement()

proc gridWidth(id, textEl: ElementId, opts: EditorOpts): float32 =
  if opts.wrap:
    let d = elementData(id)
    if d.found:
      let p = editorPadding(opts)
      let w = d.box.width - float32(p.left) - float32(p.right)
      if w > 0.0:
        return w
  let prev = elementData(textEl)
  if prev.found: prev.box.width else: 0.0

proc pitchOf(ctx: Context, text: string, cfg: TextConfig): float32 =
  if cfg.lineHeight > 0 and not ctx.gridOn:   # a grid's lines are rows
    return float32(cfg.lineHeight)
  let m = measureTextCached(ctx, text, cfg)
  if m.unwrapped.height > 0: m.unwrapped.height else: float32(cfg.fontSize)

func lineBol(s: string, pos: int): int =
  ## Start of the logical line holding `pos`.
  result = pos
  while result > 0 and s[result - 1] != '\n':
    dec result

func lineEol(s: string, pos: int): int =
  result = pos
  while result < s.len and s[result] != '\n':
    inc result

proc codepoints(text: string, lo, hi: int): seq[int] =
  ## Start offsets of every codepoint in `[lo, hi)`, plus `hi` itself.
  result = @[]
  var i = lo
  while i < hi:
    result.add i
    inc i
    while i < hi and isContByte(text[i]):
      inc i
  result.add hi

proc prefixW(ctx: Context, text: string, cfg: TextConfig,
             ls, pos: int): float32 =
  ## Width of `text[ls ..< pos]` -- the measure a column's x is read from.
  if pos <= ls:
    return 0.0
  measureTextCached(ctx, substr(text, ls, pos - 1), cfg).unwrapped.width

proc hitTest*(text: string, cfg: TextConfig, box: Rect,
              px, py: float32): int =
  ## The character index nearest the point (`px`, `py` relative to the
  ## text box's top-left, on the renderer's own line grid). Below the
  ## grid clamps to the text's end; past a line's glyphs to that line's
  ## end; between glyphs to the nearer edge, the way real editors place
  ## a click.
  if text.len == 0:
    return 0
  let ctx = currentContext()
  if not ctx.measureTextInstalled():
    return text.len
  if box.width <= 0:
    return text.len
  let lines = wrappedLines(ctx, text, cfg, box.width)
  if lines.len == 0:
    return text.len
  let pitch = pitchOf(ctx, text, cfg)
  var li = 0
  if pitch > 0:
    li = int(py / pitch)
  if li < 0:
    li = 0
  elif li >= lines.len:
    return text.len
  let ln = lines[li]
  let ls = int(ln.start)
  let le = ls + int(ln.length)
  if px <= 0:
    return ls
  let bnds = codepoints(text, ls, le)
  if bnds.len <= 1:
    return ls
  # Binary search: first boundary whose prefix width exceeds px.
  var blo = 0
  var bhi = bnds.len
  while blo < bhi:
    let mid = (blo + bhi) div 2
    if prefixW(ctx, text, cfg, ls, bnds[mid]) <= px:
      blo = mid + 1
    else:
      bhi = mid
  if blo >= bnds.len:
    return le
  let left = bnds[blo - 1]
  let right = bnds[blo]
  let lw = prefixW(ctx, text, cfg, ls, left)
  let rw = prefixW(ctx, text, cfg, ls, right)
  if px - lw < rw - px:
    return left
  return right

## --- selection & scroll overlays -------------------------------------------------

proc selColor(): Color =
  ## The live theme's `selectedBg`, thinned to a translucent wash: floated
  ## over the glyphs, an opaque fill would bury the text.
  let c = activeTheme.palette.selectedBg
  Color(r: c.r, g: c.g, b: c.b, a: 120.0)

proc selRectAt(textElId: uint32, li: int, x, y, w, h: float32,
               fill: Color) =
  openElement(ElementId(id: hashNumber(uint32(16 + li), textElId)))
  configureOpenElement(col(width = fixedPx(w), height = fixedPx(h))
    .bg(fill)
    .floating(attachElementId,
              offset = vec2(x, y),
              # Below menus (100), dropdowns (200) and scrollbars (220+) --
              # a wash rides the text, never the furniture over it.
              zIndex = 50,
              parentId = textElId,
              points = AttachPoints(element: pointLeftTop,
                                    parent: pointLeftTop),
              capture = passThroughPointer))
  closeElement()

proc selectionOverlay*(textElId: uint32, text: string, cfg: TextConfig,
                       lo, hi: int, wrapWidth = 0.0'f32) =
  ## Paint the range `[lo, hi)` over the text element `textElId`: one
  ## rectangle per grid line it touches, called inside the editor while
  ## its text element has a last-frame box. Ranges crossing a line edge
  ## wash the full line width; the newline between selected lines earns a
  ## space cell so the highlight stays continuous down the left.
  ## `wrapWidth` as for `caretOverlay` (0: the text box's last width).
  if hi <= lo:
    return
  let ctx = currentContext()
  if not ctx.measureTextInstalled():
    return
  let prev = elementData(ElementId(id: textElId))
  if not prev.found or prev.box.width <= 0:
    return
  let lines = wrappedLines(ctx, text, cfg,
    if wrapWidth > 0.0: wrapWidth else: prev.box.width)
  if lines.len == 0:
    return
  let pitch = pitchOf(ctx, text, cfg)
  let space = measureTextCached(ctx, " ", cfg).unwrapped.width
  let fill = selColor()
  for li in 0 ..< lines.len:
    let ln = lines[li]
    let ls = int(ln.start)
    let le = ls + int(ln.length)
    if hi <= ls:
      break   # the grid runs top to bottom: nothing further overlaps
    let crosses = hi > le
    let a = max(lo, ls)
    let x0 = prefixW(ctx, text, cfg, ls, a)
    var x1 = if a < le:
      prefixW(ctx, text, cfg, ls, min(hi, le))
    else:
      max(ln.dims.width, x0)
    if crosses:
      x1 = max(x1, ln.dims.width) + space   # the newline's own cell
    if x1 <= x0:
      x1 = x0 + space
    selRectAt(textElId, li, x0, float32(li) * pitch, x1 - x0, pitch, fill)

proc pageStep(s: string, cfg: TextConfig, id, textEl: ElementId,
              up: bool, extend: bool, gridW: float32) =
  ## PageUp/PageDown: jump the caret a viewport of lines, keeping its
  ## column where the target line has room, and turn the page so the new
  ## line lands where the old one was on screen.
  let ctx = currentContext()
  let prev = elementData(textEl)
  if not prev.found or gridW <= 0:
    return
  let lines = wrappedLines(ctx, s, cfg, gridW)
  let pitch = pitchOf(ctx, s, cfg)
  let sd = scrollContainerData(id)
  let viewH = if sd.found: sd.containerDimensions.height
              else: layoutDimensions().height
  var pageLines = int(viewH / max(pitch, 1.0)) - 1
  if pageLines < 1:
    pageLines = 1
  let g = caretGeom(s, caretPos(), cfg, gridW)
  let maxLine = max(lines.len - 1, 0)
  var li = g.lineIdx
  li = if up: max(li - pageLines, 0) else: min(li + pageLines, maxLine)
  if li >= lines.len:
    # A page past the last rendered line: the document's own end.
    caretTo(s, s.len, extend)
    return
  let ln = lines[li]
  let lo = int(ln.start)
  let le = lo + int(ln.length)
  let col = caretPos() - lineBol(s, caretPos())
  caretTo(s, min(lo + col, le), extend)
  if sd.found:
    var p = sd.position
    p.y += (float32(li) - float32(g.lineIdx)) * pitch
    setScrollPosition(id, p)

## --- indentation -------------------------------------------------------------------
##
## Tab and Shift+Tab, the way code editors have them: a selection across
## lines indents (or outdents) every line it touches, keeping the same
## text selected; otherwise Tab types the indent and Shift+Tab takes one
## off the caret's line. Outdenting removes one leading tab, or up to an
## indent's width of spaces.

func leadingWs(s: string, bol, stop: int): string =
  ## The run of spaces and tabs at `bol`, cut off at `stop`.
  result = ""
  var i = bol
  while i < stop and i < s.len and (s[i] == ' ' or s[i] == '\t'):
    result.add s[i]
    inc i

func carried(pos: int, collapsed: bool, starts, removes: seq[int],
             width: int, outdent: bool): int =
  ## Where `pos` lands once `shiftLines` edited the line fronts at
  ## `starts`. Indenting pushes along what lies past a front -- and a
  ## bare caret on it; a selection edge at column 0 stays at column 0.
  ## Outdenting pulls positions back, those inside a removed run to the
  ## line's new front.
  result = pos
  for k in 0 ..< starts.len:
    let st = starts[k]
    if outdent:
      let r = removes[k]
      if pos >= st + r: result -= r
      elif pos > st: result -= pos - st
    elif pos > st or (pos == st and collapsed):
      result += width

proc shiftLines(s: var string, indent: string, outdent: bool) =
  ## Indent or outdent the lines the selection (or the caret) is on.
  let c = caretPos()
  let a = anchorPos()
  let lo = min(c, a)
  var hi = max(c, a)
  # A selection ending at a line's very start leaves that line alone.
  if hi > lo and s[hi - 1] == '\n':
    dec hi
  var starts: seq[int] = @[]
  var removes: seq[int] = @[]
  var p = lineBol(s, lo)
  while true:
    starts.add p
    var r = 0
    if outdent:
      if p < s.len and s[p] == '\t':
        r = 1
      else:
        while p + r < s.len and s[p + r] == ' ' and r < indent.len:
          inc r
    removes.add r
    let e = lineEol(s, p)
    if e >= hi or e >= s.len:
      break
    p = e + 1
  var outp = ""
  var last = 0
  for k in 0 ..< starts.len:
    outp.add substr(s, last, starts[k] - 1)
    if outdent:
      last = starts[k] + removes[k]
    else:
      outp.add indent
      last = starts[k]
  outp.add substr(s, last, s.len - 1)
  s = outp
  setCarets(s, carried(c, c == a, starts, removes, indent.len, outdent),
            carried(a, c == a, starts, removes, indent.len, outdent))

proc tabKey(s: var string, indent: string, outdent: bool) =
  let c = caretPos()
  let a = anchorPos()
  let lo = min(c, a)
  let hi = max(c, a)
  var multiLine = false
  for i in lo ..< hi:
    if s[i] == '\n':
      multiLine = true
  if outdent or multiLine:
    shiftLines(s, indent, outdent)
  else:
    insertAtCaret(s, indent)

proc runEngine(id: ElementId, s: var string, evs: var seq[KeyEvent]) =
  ## Hand the pending plain keys to the shared engine, as one history step.
  if evs.len == 0:
    return
  let prevSnap = snapFrom(id, s)
  var inp = s   # the engine sinks its input; `s` stays pristine here
  let step = editStepWith(inp, evs)
  evs.setLen(0)
  if step.text != s:
    s = step.text
    syncCaret(s.len)
    pushEdit(id, prevSnap, s)

## --- the widget -------------------------------------------------------------------

widget editor(id: ElementId, text: string,
             opts = EditorOpts()) -> EditorStats:
  ## The document area: `text` in, `EditorStats.text` back. A sunken,
  ## scrollable page (vertical always; horizontal too when `wrap` is off)
  ## holding one word-wrapped -- or endlessly wide -- text element, with
  ## the caret and selection painted over it and floating scrollbars
  ## hugging its edges.
  ##
  ## Mouse: a click places the caret (`hitTest` on the rendered line
  ## grid), holding and dragging sweeps a selection, a double click picks
  ## the word under the pointer. Keys: everything `common`'s engine does,
  ## plus Enter as a newline (indented like its line with `autoIndent`),
  ## Tab / Shift+Tab indent and outdent, Ctrl+A select-all, Ctrl+Z undo,
  ## Ctrl+Y / Ctrl+Shift+Z redo and PageUp/PageDown -- handled here, in
  ## the order they were pressed, before the shared map sees the rest.
  ## While `blocked` the widget paints as normal but hears no keys and
  ## takes no clicks: a modal dialog owns the session meanwhile.
  ## Emits `TextChanged` with the new text when this frame edited it.
  emits TextChanged
  let t = activeTheme
  var s = text
  let size =
    if opts.fontSize > 0'u16: opts.fontSize
    else: t.text.control
  let cfg = TextConfig(fontSize: size, color: t.palette.textColor,
                       fontId: opts.fontId,
                       wrap: if opts.wrap: wordWrap else: noWrap)
  let textEl = ElementId(id: textChildId(id.id))
  let ppos = currentContext().pointerData().position
  let wasLive = focused(id)
  let gridW = gridWidth(id, textEl, opts)
  let caretBefore = editorCaret(id, text)
  let anchorBefore = editorAnchor(id, text)

  if opts.blocked:
    pendingUndo = false
    pendingRedo = false
  else:
    # ---- focus & pointer ------------------------------------------------
    let was = wasLive
    if clickedIn(id):
      var prev = elementData(textEl)
      prev.box.width = gridW
      var pos = s.len
      if prev.found:
        pos = hitTest(s, cfg, prev.box, ppos.x - prev.box.x,
                      ppos.y - prev.box.y)
      if doubleClick() and prev.found and s.len > 0:
        let w = wordRange(s, pos)
        focusAt(id, s, w.hi)
        if w.hi > w.lo:
          selectRange(s, w.lo, w.hi)
      else:
        focusAt(id, s, pos)
    elif was and clickedOut(id):
      blur()
    elif focused(id) and pressing(id):
      # Held after the placing click: drag-select, anchor where it is.
      var prev = elementData(textEl)
      prev.box.width = gridW
      if prev.found:
        let pos = hitTest(s, cfg, prev.box, ppos.x - prev.box.x,
                          ppos.y - prev.box.y)
        caretTo(s, pos, true)

    # ---- menu requests ---------------------------------------------------
    if pendingUndo:
      pendingUndo = false
      pendingRedo = false
      discard takeUndo(id, s)
    elif pendingRedo:
      pendingRedo = false
      discard takeRedo(id, s)

    # ---- keys --------------------------------------------------------------
    # The editor's own keys act in sequence with the engine's: plain keys
    # queue up and run through the engine before each key handled here.
    if focused(id) and not opts.readOnly:
      var rest: seq[KeyEvent] = @[]
      let evs = frameKeys()
      for ev in evs:
        let newline = ev.kind == kevEnter or
          (ev.kind == kevLetter and ev.ctrl and not ev.alt and ev.ch == 'm')
        if newline:
          # Newline, not a commit: the document never "leaves" the field.
          runEngine(id, s, rest)
          var nl = "\n"
          if opts.autoIndent:
            let c = min(caretPos(), anchorPos())
            let bol = lineBol(s, c)
            nl.add leadingWs(s, bol, c)
            if opts.indentAfter.len > 0:
              var e = c
              while e > bol and s[e - 1] == ' ':
                dec e
              if e - bol >= opts.indentAfter.len and
                  s.substr(e - opts.indentAfter.len, e - 1) == opts.indentAfter:
                nl.add opts.indent
          rest.add KeyEvent(kind: kevText, text: nl)
          continue
        case ev.kind
        of kevLetter:
          if ev.ctrl and not ev.alt and
              (ev.ch == 'a' or ev.ch == 'z' or ev.ch == 'y'):
            runEngine(id, s, rest)
            if ev.ch == 'a':
              editorSelectAll(id, s)
            elif ev.ch == 'y' or ev.shift:
              discard takeRedo(id, s)
            else:
              discard takeUndo(id, s)
          else:
            rest.add ev
        of kevTab:
          if opts.indent.len > 0 and not ev.ctrl and not ev.alt:
            runEngine(id, s, rest)
            let prevSnap = snapFrom(id, s)
            tabKey(s, opts.indent, ev.shift)
            if s != prevSnap.text:
              groupKind = 0   # an indent is its own undo step
              pushEdit(id, prevSnap, s)
          else:
            rest.add ev
        of kevPageUp, kevPageDown:
          runEngine(id, s, rest)
          pageStep(s, cfg, id, textEl, ev.kind == kevPageUp, ev.shift, gridW)
        else:
          rest.add ev
      runEngine(id, s, rest)

  # ---- mirror refresh: the editor's position is whatever the engine
  # holds while it runs, and the mirror is everything else.
  if focused(id):
    mOwner = id.id
    mCaret = caretPos()
    mAnchor = anchorPos()

  # ---- layout & overlays ---------------------------------------------------
  let pad2 = float32(2 * editorPad)
  let height =
    if opts.maxLines > 0:
      let pitch = linePitch(cfg)
      fit(min = pitch + pad2, max = float32(opts.maxLines) * pitch + pad2)
    else: grow()
  let pads = editorPadding(opts)
  item(id, fieldDecl(id, grow(), height, dir = topToBottom,
      padding = pads)
      .clip(horizontal = not opts.wrap, vertical = true,
            childOffset = currentScrollOffset())):
    textElement(keepLine(s), TextConfig(fontSize: size, color: t.palette.textColor,
                              fontId: opts.fontId, wrap: cfg.wrap))
    if mOwner == id.id:
      # Selection stays visible (it washes the text, dialogs sit above it
      # -- Notepad keeps a found selection lit behind its modal). The
      # caret hides while a modal owns the keyboard: a blinking bar floated
      # at max zIndex would punch through the dialog it sits over.
      let (slo, shi) = editorSel(id, s)
      let wrapW = if opts.wrap: gridW else: 0.0'f32
      selectionOverlay(textEl.id, s, cfg, slo, shi, wrapW)
      if focused(id) and not opts.blocked:
        caretOverlay(textEl.id, s, cfg, t.palette.textColor, wrapW)
      scrollCaretIntoView(id, textEl, s, cfg, editorCaret(id, s),
                          float32(pads.right), float32(pads.bottom),
                          followX = not opts.wrap, wrapWidth = wrapW)
    if barsAlways(opts):
      gutterStrip(id, true, float32(pads.right - editorPad))
      if not opts.wrap:
        gutterStrip(id, false, float32(pads.bottom - editorPad))
    scrollbar(localId("editor.bar"), id, always = barsAlways(opts))

  let moved = editorCaret(id, s) != caretBefore or
    editorAnchor(id, s) != anchorBefore
  # emit before building the result: Nimony moves `s` into it, and a
  # later `s != text` would compare an emptied string
  if s != text:
    emit TextChanged(id: id, text: s)
  result = EditorStats(text: s, edited: s != text, caretMoved: moved,
                       undoable: editorUndoable(),
                       redoable: editorRedoable())
