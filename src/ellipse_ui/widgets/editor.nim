## The full text-editing surface -- the document area a Notepad-style app
## edits. Where `textField`/`multilineField` are small entry boxes that
## commit and release focus, `editor` is an endless scrollable page: the
## shared edit engine from `common` (caret, selection, Emacs chords, the
## system clipboard) plus everything a document area needs on top --
## painted selection, click / drag / double-click caret placement,
## word wrap or horizontal scrolling, PageUp/PageDown by view height,
## scrolling that follows the caret, and an undo / redo history.
##
## Immediate-mode contract, same shape as the fields: the caller owns the
## text, hands it in, and stores the edited one back out of the stats:
##
##   doc = editor(hashId("doc"), doc).text
##
## The widget's transient state (undo history, the position mirror below)
## lives here, keyed by element id like the dropdown slot in `common`.
## The menu-side entry points (`editorUndo`, `editorCut`, `editorSelect`,
## ...) let an application drive the same acts a keystroke would -- with
## the same history bookkeeping -- from anywhere in its frame.
##
## Caret & selection are mirrored even while another widget holds focus:
## a modal dialog steals the keyboard (its text field takes the engine's
## caret), yet the document keeps a position, a selection worth painting
## behind the dialog, and search actions that must resolve "from here".
## One remembered pair per editor, refreshed whenever the editor is live.
##
## Selection painting is a translucent rectangle per wrapped line floated
## over the glyphs -- the renderer only promises rectangles, so an
## opaque Notepad-blue would bury the text. The washed accent reads like
## a modern editor's highlight.

import std/[monotimes, strutils]

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
## feeding the last frame's box width back in yields *exactly* the line
## grid the renderer drew -- what the caret geometry, the selection
## rectangles, the pointer hit-test and the scroll-follow all agree on.

proc pitchOf(ctx: Context, text: string, cfg: TextConfig): float32 =
  if cfg.lineHeight > 0:
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
                       lo, hi: int) =
  ## Paint the range `[lo, hi)` over the text element `textElId`: one
  ## rectangle per grid line it touches, called inside the editor while
  ## its text element has a last-frame box. Ranges crossing a line edge
  ## wash the full line width; the newline between selected lines earns a
  ## space cell so the highlight stays continuous down the left.
  if hi <= lo:
    return
  let ctx = currentContext()
  if not ctx.measureTextInstalled():
    return
  let prev = elementData(ElementId(id: textElId))
  if not prev.found or prev.box.width <= 0:
    return
  let lines = wrappedLines(ctx, text, cfg, prev.box.width)
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

proc scrollCaretIntoView(id, textEl: ElementId, text: string,
                         cfg: TextConfig, wrapped: bool, pos: int) =
  ## Nudge the editor's scroll container so the caret's line (and column,
  ## without word wrap) sits inside the padded viewport -- what a real
  ## editor does on typing, arrowing, and a programmatic jump.
  let sd = scrollContainerData(id)
  let prev = elementData(textEl)
  if not sd.found or not prev.found:
    return
  let ctx = currentContext()
  if not ctx.measureTextInstalled():
    return
  let g = caretGeom(text, pos, cfg, prev.box.width)
  if not g.found:
    return
  let cbox = elementData(id).box
  var posv = sd.position
  let lineTop = prev.box.y + g.y
  let lineBot = lineTop + g.barH
  let innerTop = cbox.y + float32(editorPad)
  let innerBot = cbox.y + cbox.height - float32(editorPad)
  if lineTop < innerTop:
    posv.y += lineTop - innerTop
  elif lineBot > innerBot:
    posv.y += lineBot - innerBot
  if not wrapped:
    let cx = prev.box.x + g.x
    let innerLeft = cbox.x + float32(editorPad)
    let innerRight = cbox.x + cbox.width - float32(editorPad)
    if cx < innerLeft:
      posv.x += cx - innerLeft
    elif cx > innerRight - 2.0:
      posv.x += cx - (innerRight - 2.0)
  if posv.x != sd.position.x or posv.y != sd.position.y:
    setScrollPosition(id, posv)

proc pageStep(s: string, cfg: TextConfig, id, textEl: ElementId,
              up: bool, extend: bool) =
  ## PageUp/PageDown: jump the caret a viewport of lines, keeping its
  ## column where the target line has room, and turn the page so the new
  ## line lands where the old one was on screen.
  let ctx = currentContext()
  let prev = elementData(textEl)
  if not prev.found or prev.box.width <= 0:
    return
  let lines = wrappedLines(ctx, s, cfg, prev.box.width)
  let pitch = pitchOf(ctx, s, cfg)
  let sd = scrollContainerData(id)
  let viewH = if sd.found: sd.containerDimensions.height
              else: layoutDimensions().height
  var pageLines = int(viewH / max(pitch, 1.0)) - 1
  if pageLines < 1:
    pageLines = 1
  let g = caretGeom(s, caretPos(), cfg, prev.box.width)
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

## --- the widget -------------------------------------------------------------------

proc editor*(id: ElementId, text: string,
             opts = EditorOpts()): EditorStats =
  ## The document area: `text` in, `EditorStats.text` back. A sunken,
  ## scrollable page (vertical always; horizontal too when `wrap` is off)
  ## holding one word-wrapped -- or endlessly wide -- text element, with
  ## the caret and selection painted over it and floating scrollbars
  ## hugging its edges.
  ##
  ## Mouse: a click places the caret (`hitTest` on the rendered line
  ## grid), holding and dragging sweeps a selection, a double click picks
  ## the word under the pointer. Keys: everything `common`'s engine does,
  ## plus Enter as a newline, Ctrl+A select-all, Ctrl+Z / Ctrl+Y undo /
  ## redo and PageUp/PageDown -- consumed here before the shared map
  ## sees them. While `blocked` the widget paints as normal but hears no
  ## keys and takes no clicks: a modal dialog owns the session meanwhile.
  let t = activeTheme
  var s = text
  let size =
    if opts.fontSize > 0'u16: opts.fontSize
    else: t.text.control
  let cfg = TextConfig(fontSize: size, color: t.palette.textColor,
                       wrap: if opts.wrap: wordWrap else: noWrap)
  let textEl = ElementId(id: textChildId(id.id))
  let ppos = currentContext().pointerData().position
  let wasLive = focused(id)
  let caretBefore = editorCaret(id, text)
  let anchorBefore = editorAnchor(id, text)

  if opts.blocked:
    pendingUndo = false
    pendingRedo = false
  else:
    # ---- focus & pointer ------------------------------------------------
    let was = wasLive
    if clickedIn(id):
      let prev = elementData(textEl)
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
      let prev = elementData(textEl)
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
    if focused(id) and not opts.readOnly:
      var rest: seq[KeyEvent] = @[]
      let evs = frameKeys()
      for ev in evs:
        var consumed = true
        case ev.kind
        of kevLetter:
          consumed = false
          if ev.ctrl:
            case ev.ch
            of 'a':
              editorSelectAll(id, s)
              consumed = true
            of 'z':
              discard takeUndo(id, s)
              consumed = true
            of 'y':
              discard takeRedo(id, s)
              consumed = true
            of 'm':
              rest.add KeyEvent(kind: kevText, text: "\n")
              consumed = true
            else: discard
        of kevEnter:
          # Newline, not a commit: the document never "leaves" the field.
          rest.add KeyEvent(kind: kevText, text: "\n")
        of kevPageUp, kevPageDown:
          pageStep(s, cfg, id, textEl, ev.kind == kevPageUp, ev.shift)
        else:
          consumed = false
        if not consumed:
          rest.add ev
      if rest.len > 0:
        let prevSnap = snapFrom(id, s)
        var inp = s   # the engine sinks its input; `s` stays pristine here
        let step = editStepWith(inp, rest)
        if step.text != s:
          s = step.text
          syncCaret(s.len)
          pushEdit(id, prevSnap, s)

  # ---- mirror refresh: the editor's position is whatever the engine
  # holds while it runs, and the mirror is everything else.
  if focused(id):
    mOwner = id.id
    mCaret = caretPos()
    mAnchor = anchorPos()

  # ---- layout & overlays ---------------------------------------------------
  item(id, fieldDecl(id, grow(), grow(), dir = topToBottom,
      padding = padAll(editorPad))
      .clip(horizontal = not opts.wrap, vertical = true,
            childOffset = currentScrollOffset())):
    textElement(s, TextConfig(fontSize: size, color: t.palette.textColor,
                              wrap: cfg.wrap))
    if mOwner == id.id:
      # Selection stays visible (it washes the text, dialogs sit above it
      # -- Notepad keeps a found selection lit behind its modal). The
      # caret hides while a modal owns the keyboard: a blinking bar floated
      # at max zIndex would punch through the dialog it sits over.
      let (slo, shi) = editorSel(id, s)
      selectionOverlay(textEl.id, s, cfg, slo, shi)
      if focused(id) and not opts.blocked:
        caretOverlay(textEl.id, s, cfg, t.palette.textColor)
      scrollCaretIntoView(id, textEl, s, cfg, opts.wrap,
                          editorCaret(id, s))
    scrollbar(localId("editor.bar"), id)

  let moved = editorCaret(id, s) != caretBefore or
    editorAnchor(id, s) != anchorBefore
  result = EditorStats(text: s, edited: s != text, caretMoved: moved,
                       undoable: editorUndoable(),
                       redoable: editorRedoable())
