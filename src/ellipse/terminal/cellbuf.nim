## The terminal's picture: a grid of cells clay's render commands paint
## into, then written out as the difference from what the terminal already
## shows.
##
## Commands arrive in virtual pixels laid out on the grid (clay's `setGrid`),
## so every box covers whole cells. Painting is cell-wise:
##
##   command      what it does to the cells it covers
##   ----------+-----------------------------------------------------------
##   rectangle   opaque: the background, glyphs cleared; translucent:
##               blended into background and glyph colour alike (hover
##               tints, dimmed backdrops and shadows keep what is beneath)
##   border      box-drawing lines on the sides that have a width: 1 is
##               light, 2+ heavy, a rounded corner `╭`; a one-row box gets
##               `[ ]` caps (`( )` from `pillRadius`). A top or bottom line
##               with no sides is a rule: it over/underlines the edge row.
##               (Clay's grid has already dropped the sides that had no free
##               cell to be drawn in.)
##   text        glyphs and their colour over the background there; sizes
##               from `boldFrom` up are bold
##   clip        narrows painting to the intersection of the open clips
##   custom      handed to the cell painter its `custom` data names
##               (`registerCellPainter`); anything else draws nothing --
##               the way a widget with no terminal form disappears
##   image       not drawn (no terminal equivalent yet)
##
## A wide (CJK, emoji) glyph takes two cells: the second holds "" and is
## never written on its own.

import std/math

import clay
import ./cellwidth

type
  Rgb* = object
    r*, g*, b*: uint8

  CellAttr* = enum
    caBold, caDim, caItalic, caUnderline, caReverse, caOverline

  Cell* = object
    glyph*: string          ## one character; "" = right half of a wide one
    fg*, bg*: Rgb
    attrs*: set[CellAttr]

  CellRect* = object
    ## Cells `[c0, c1) x [r0, r1)`.
    c0*, r0*, c1*, r1*: int

  CellBuffer* = object
    cols*, rows*: int
    cells*: seq[Cell]
    cellW*, cellH*: float32 ## virtual pixels per cell (clay's grid)

  CellPainter* = proc (buf: var CellBuffer; cmd: RenderCommand;
                       area: CellRect) {.nimcall.}
    ## Draws a `renderCustom` command on the terminal: `area` is its box
    ## (`buf.toCells(cmd.box)`) already clipped -- paint only inside it.
    ## A plain proc, not a closure: what it needs comes with the command --
    ## `customBackground` (the element's `.bg`), `id`, `userData`.
    ## (Closures held in the registry were copied without a refcount bump
    ## and freed under it -- a Nimony codegen bug.)

  ColorMode* = enum
    cmTrue, cm256, cm16

var
  boldFrom*: uint16 = 20
    ## Text this size and up is drawn bold: headings stand out on a grid
    ## where every size is one row.
  painters: seq[CellPainter] = @[]
  pillRadius*: float32 = 12
    ## A one-row box rounded this much (virtual pixels) gets `( )` caps.

proc registerCellPainter*(p: CellPainter): pointer =
  ## Make `p` the terminal form of the elements declared with
  ## `.custom(handle)`, `handle` being what this returns. A widget with a
  ## custom look (a canvas, a glyph a rectangle cannot draw) registers once
  ## and declares the handle every frame; on a window the SDL renderer
  ## skips custom commands it does not know, so the same element can carry
  ## both looks. Handles are small integers, not addresses.
  painters.add p
  cast[pointer](uint(painters.len))

proc painterFor(data: nil pointer): nil CellPainter =
  ## The painter a custom command's data names, if any.
  let i = int(cast[uint](data)) - 1
  if i >= 0 and i < painters.len:
    return painters[i]
  nil

func `==`*(a, b: Rgb): bool = a.r == b.r and a.g == b.g and a.b == b.b

func `==`*(a, b: Cell): bool =
  a.glyph == b.glyph and a.fg == b.fg and a.bg == b.bg and a.attrs == b.attrs

func toRgb*(c: Color): Rgb =
  Rgb(r: uint8(clamp(c.r, 0, 255)), g: uint8(clamp(c.g, 0, 255)),
      b: uint8(clamp(c.b, 0, 255)))

func mix(a, b: Rgb; t: float32): Rgb =
  ## `a` moved toward `b` by `t` (0-1).
  Rgb(r: uint8(float32(a.r) + (float32(b.r) - float32(a.r)) * t + 0.5),
      g: uint8(float32(a.g) + (float32(b.g) - float32(a.g)) * t + 0.5),
      b: uint8(float32(a.b) + (float32(b.b) - float32(a.b)) * t + 0.5))

func alphaOf(c: Color): float32 = clamp(c.a, 0, 255) / 255

proc initCellBuffer*(cols, rows: int; cellW, cellH: float32;
                     bg, fg: Rgb): CellBuffer =
  result = CellBuffer(cols: cols, rows: rows, cellW: cellW, cellH: cellH,
                      cells: newSeq[Cell](cols * rows))
  for i in 0 ..< result.cells.len:
    result.cells[i] = Cell(glyph: " ", fg: fg, bg: bg)

proc clear*(buf: var CellBuffer; bg, fg: Rgb) =
  for i in 0 ..< buf.cells.len:
    buf.cells[i] = Cell(glyph: " ", fg: fg, bg: bg)

func full*(buf: CellBuffer): CellRect =
  CellRect(c0: 0, r0: 0, c1: buf.cols, r1: buf.rows)

func intersect*(a, b: CellRect): CellRect =
  CellRect(c0: max(a.c0, b.c0), r0: max(a.r0, b.r0),
           c1: min(a.c1, b.c1), r1: min(a.r1, b.r1))

func isEmpty*(a: CellRect): bool = a.c1 <= a.c0 or a.r1 <= a.r0

func contains*(a: CellRect; c, r: int): bool {.inline.} =
  c >= a.c0 and c < a.c1 and r >= a.r0 and r < a.r1

func toCells*(buf: CellBuffer; r: Rect): CellRect =
  ## The cells a (grid-snapped) box covers.
  CellRect(c0: int(floor(r.x / buf.cellW + 0.5)),
           r0: int(floor(r.y / buf.cellH + 0.5)),
           c1: int(floor((r.x + r.width) / buf.cellW + 0.5)),
           r1: int(floor((r.y + r.height) / buf.cellH + 0.5)))

func at(buf: CellBuffer; c, r: int): int {.inline.} = r * buf.cols + c

proc breakWide(buf: var CellBuffer; c, r: int) =
  ## About to overwrite cell (c, r): a wide glyph losing either half
  ## becomes a blank.
  let i = buf.at(c, r)
  if buf.cells[i].glyph.len == 0 and c > 0:
    buf.cells[i - 1].glyph = " "
  elif c + 1 < buf.cols and buf.cells[i + 1].glyph.len == 0:
    buf.cells[i + 1].glyph = " "

proc putGlyph*(buf: var CellBuffer; c, r: int; glyph: string; fg: Rgb;
               attrs: set[CellAttr] = {}; clip: CellRect) =
  ## One glyph at (c, r) inside `clip`, over the background already there.
  if not clip.contains(c, r) or not buf.full.contains(c, r):
    return
  buf.breakWide(c, r)
  let i = buf.at(c, r)
  buf.cells[i].glyph = glyph
  buf.cells[i].fg = fg
  buf.cells[i].attrs = attrs

proc shadeGlyph*(buf: var CellBuffer; c, r: int; glyph: string; col: Color) =
  ## A glyph in `col` over the cell's background, blended by `col`'s alpha:
  ## half blocks drawn this way darken or tint what lies beneath.
  if not buf.full.contains(c, r):
    return
  let bg = buf.cells[buf.at(c, r)].bg
  buf.putGlyph(c, r, glyph, mix(bg, toRgb(col), alphaOf(col)), {}, buf.full)

proc fillCells*(buf: var CellBuffer; area: CellRect; col: Color) =
  ## A rectangle: opaque replaces, translucent tints (see the module doc).
  let a = alphaOf(col)
  if a <= 0:
    return
  let rgb = toRgb(col)
  let area = intersect(area, buf.full)
  for r in area.r0 ..< area.r1:
    for c in area.c0 ..< area.c1:
      let i = buf.at(c, r)
      if a >= 1:
        buf.breakWide(c, r)
        buf.cells[i].glyph = " "
        buf.cells[i].bg = rgb
        buf.cells[i].attrs = {}
      else:
        buf.cells[i].bg = mix(buf.cells[i].bg, rgb, a)
        buf.cells[i].fg = mix(buf.cells[i].fg, rgb, a)

proc drawText*(buf: var CellBuffer; c0, r: int; text: string; col: Color;
               attrs: set[CellAttr]; clip: CellRect) =
  ## `text` on row `r` from column `c0`, blended over each cell's background.
  if r < clip.r0 or r >= clip.r1 or r < 0 or r >= buf.rows:
    return
  let a = alphaOf(col)
  let rgb = toRgb(col)
  var c = c0
  var i = 0
  while i < text.len:
    let (cp, n) = decodeRune(text, i)
    let w = runeWidth(cp)
    var glyph = if cp == 9: " " else: text.substr(i, i + n - 1)
    i += n
    if w == 0:
      # A combining mark rides on the glyph before it.
      if c > c0 and clip.contains(c - 1, r) and c - 1 < buf.cols:
        buf.cells[buf.at(c - 1, r)].glyph.add glyph
      continue
    if c >= clip.c1:
      break
    if c + w - 1 >= clip.c0:
      let fits = clip.contains(c, r) and clip.contains(c + w - 1, r) and
                 c >= 0 and c + w - 1 < buf.cols
      if fits:
        let fg = if a >= 1: rgb else: mix(buf.cells[buf.at(c, r)].bg, rgb, a)
        buf.putGlyph(c, r, glyph, fg, attrs, clip)
        if w == 2:
          buf.putGlyph(c + 1, r, "", fg, attrs, clip)
      else:
        # Half a wide glyph at a clip edge: show the half cell blank.
        for k in 0 ..< w:
          buf.putGlyph(c + k, r, " ", rgb, attrs, clip)
    c += w

type
  Lines = object
    h, v, tl, tr, bl, br: string

const
  lightLines = Lines(h: "─", v: "│", tl: "┌", tr: "┐", bl: "└", br: "┘")
  heavyLines = Lines(h: "━", v: "┃", tl: "┏", tr: "┓", bl: "┗", br: "┛")
  roundLines = Lines(h: "─", v: "│", tl: "╭", tr: "╮", bl: "╰", br: "╯")

func linesFor(width: int; rounded: bool): Lines =
  if width >= 2: heavyLines
  elif rounded: roundLines
  else: lightLines

proc ruleRow(buf: var CellBuffer; c0, c1, r: int; attr: CellAttr; fg: Rgb;
             clip: CellRect) =
  ## Over/underline cells `[c0, c1)` of row `r`; the line takes `fg`'s
  ## colour where no glyph has one.
  for c in c0 ..< c1:
    if clip.contains(c, r) and buf.full.contains(c, r):
      let i = buf.at(c, r)
      buf.cells[i].attrs.incl attr
      if buf.cells[i].glyph == " ":
        buf.cells[i].fg = fg

proc drawBorder*(buf: var CellBuffer; box: CellRect; bw: BorderWidth;
                 corner: CornerRadius; col: Color; clip: CellRect) =
  ## Box-drawing lines on each side of `box` with a width (module doc).
  if alphaOf(col) <= 0 or box.isEmpty:
    return
  let fg = toRgb(col)
  let rounded = corner.topLeft > 0 or corner.topRight > 0 or
                corner.bottomLeft > 0 or corner.bottomRight > 0
  let pill = corner.topLeft >= pillRadius and corner.bottomLeft >= pillRadius
  let last = CellRect(c0: box.c0, r0: box.r0, c1: box.c1 - 1, r1: box.r1 - 1)
  if bw.left == 0 and bw.right == 0:
    # Rules: the line becomes an attribute of the edge row's cells.
    if bw.bottom > 0:
      buf.ruleRow(box.c0, box.c1, last.r1, caUnderline, fg, clip)
    if bw.top > 0:
      buf.ruleRow(box.c0, box.c1, box.r0, caOverline, fg, clip)
    return
  if box.r1 - box.r0 == 1:
    # One row: caps for the sides.
    if bw.left > 0:
      buf.putGlyph(box.c0, box.r0, if pill: "(" else: "[", fg, {}, clip)
    if bw.right > 0 and box.c1 - box.c0 > 1:
      buf.putGlyph(last.c1, box.r0, if pill: ")" else: "]", fg, {}, clip)
    return
  let top = linesFor(bw.top, rounded)
  let bottom = linesFor(bw.bottom, rounded)
  let left = linesFor(bw.left, rounded)
  let right = linesFor(bw.right, rounded)
  if bw.top > 0:
    for c in box.c0 .. last.c1:
      buf.putGlyph(c, box.r0, top.h, fg, {}, clip)
  if bw.bottom > 0:
    for c in box.c0 .. last.c1:
      buf.putGlyph(c, last.r1, bottom.h, fg, {}, clip)
  if bw.left > 0:
    for r in box.r0 .. last.r1:
      buf.putGlyph(box.c0, r, left.v, fg, {}, clip)
  if bw.right > 0 and box.c1 - box.c0 > 1:
    for r in box.r0 .. last.r1:
      buf.putGlyph(last.c1, r, right.v, fg, {}, clip)
  # Corners where two lines meet; the heavier side picks the set.
  if bw.top > 0 and bw.left > 0:
    buf.putGlyph(box.c0, box.r0, linesFor(max(bw.top, bw.left), rounded).tl,
                 fg, {}, clip)
  if bw.top > 0 and bw.right > 0:
    buf.putGlyph(last.c1, box.r0, linesFor(max(bw.top, bw.right), rounded).tr,
                 fg, {}, clip)
  if bw.bottom > 0 and bw.left > 0:
    buf.putGlyph(box.c0, last.r1, linesFor(max(bw.bottom, bw.left), rounded).bl,
                 fg, {}, clip)
  if bw.bottom > 0 and bw.right > 0:
    buf.putGlyph(last.c1, last.r1,
                 linesFor(max(bw.bottom, bw.right), rounded).br, fg, {}, clip)

proc paint*(buf: var CellBuffer; cmds: seq[RenderCommand]) =
  ## Paint one frame's commands, in order, into `buf` (on top of what it
  ## holds: `clear` first for a fresh frame). Text comes from the current
  ## clay context.
  var clips: seq[CellRect] = @[buf.full]
  for cmd in cmds:
    let clip = clips[^1]
    case cmd.kind
    of renderRectangle:
      buf.fillCells(intersect(buf.toCells(cmd.box), clip), cmd.fill)
    of renderBorder:
      buf.drawBorder(buf.toCells(cmd.box), cmd.borderWidth, cmd.borderCorner,
                     cmd.borderColor, clip)
    of renderText:
      let cr = buf.toCells(cmd.box)
      let attrs = if cmd.fontSize >= boldFrom: {caBold} else: {}
      buf.drawText(cr.c0, cr.r0, lineText(cmd), cmd.textColor, attrs, clip)
    of renderClipStart:
      clips.add intersect(buf.toCells(cmd.box), clip)
    of renderClipEnd:
      if clips.len > 1:
        clips.setLen(clips.len - 1)
    of renderCustom:
      let painter = painterFor(cmd.customData)
      if painter != nil:
        painter(buf, cmd, intersect(intersect(buf.toCells(cmd.box), clip),
                                    buf.full))
    of renderImage, renderOverlayStart, renderOverlayEnd:
      discard

## --- output --------------------------------------------------------------------

proc toPlain*(buf: CellBuffer): string =
  ## The picture as plain text, one line per row, trailing blanks trimmed:
  ## the snapshot format.
  result = ""
  for r in 0 ..< buf.rows:
    var line = ""
    for c in 0 ..< buf.cols:
      line.add buf.cells[buf.at(c, r)].glyph
    var e = line.len
    while e > 0 and line[e - 1] == ' ':
      dec e
    line.setLen(e)
    result.add line
    result.add '\n'

const ansi16 = [
  Rgb(r: 0, g: 0, b: 0), Rgb(r: 205, g: 0, b: 0), Rgb(r: 0, g: 205, b: 0),
  Rgb(r: 205, g: 205, b: 0), Rgb(r: 0, g: 0, b: 238), Rgb(r: 205, g: 0, b: 205),
  Rgb(r: 0, g: 205, b: 205), Rgb(r: 229, g: 229, b: 229),
  Rgb(r: 127, g: 127, b: 127), Rgb(r: 255, g: 0, b: 0), Rgb(r: 0, g: 255, b: 0),
  Rgb(r: 255, g: 255, b: 0), Rgb(r: 92, g: 92, b: 255), Rgb(r: 255, g: 0, b: 255),
  Rgb(r: 0, g: 255, b: 255), Rgb(r: 255, g: 255, b: 255)]

func dist(a, b: Rgb): int =
  let dr = int(a.r) - int(b.r)
  let dg = int(a.g) - int(b.g)
  let db = int(a.b) - int(b.b)
  dr * dr * 3 + dg * dg * 4 + db * db * 2

func nearest16(c: Rgb): int =
  var best = 0
  for i in 1 ..< ansi16.len:
    if dist(c, ansi16[i]) < dist(c, ansi16[best]):
      best = i
  best

func cubeLevel(v: uint8): int =
  if v < 48: 0 elif v < 115: 1 else: (int(v) - 35) div 40

func nearest256(c: Rgb): int =
  ## The xterm palette: the 6x6x6 cube or the grey ramp, whichever is closer.
  const steps = [0, 95, 135, 175, 215, 255]
  let ri = cubeLevel(c.r)
  let gi = cubeLevel(c.g)
  let bi = cubeLevel(c.b)
  let cube = Rgb(r: uint8(steps[ri]), g: uint8(steps[gi]), b: uint8(steps[bi]))
  let avg = (int(c.r) + int(c.g) + int(c.b)) div 3
  let gi2 = if avg > 238: 23 else: max(avg - 3, 0) div 10
  let grey = uint8(8 + gi2 * 10)
  if dist(c, Rgb(r: grey, g: grey, b: grey)) < dist(c, cube):
    232 + gi2
  else:
    16 + 36 * ri + 6 * gi + bi

proc addColor(s: var string; c: Rgb; bg: bool; mode: ColorMode) =
  case mode
  of cmTrue:
    s.add(if bg: ";48;2;" else: ";38;2;")
    s.add $c.r
    s.add ';'
    s.add $c.g
    s.add ';'
    s.add $c.b
  of cm256:
    s.add(if bg: ";48;5;" else: ";38;5;")
    s.add $nearest256(c)
  of cm16:
    let n = nearest16(c)
    let base = if bg: 40 else: 30
    s.add ';'
    s.add $(if n < 8: base + n else: base + 60 + n - 8)

proc addPen(s: var string; cell: Cell; mode: ColorMode) =
  s.add "\e[0"
  if caBold in cell.attrs: s.add ";1"
  if caDim in cell.attrs: s.add ";2"
  if caItalic in cell.attrs: s.add ";3"
  if caUnderline in cell.attrs: s.add ";4"
  if caReverse in cell.attrs: s.add ";7"
  if caOverline in cell.attrs: s.add ";53"
  s.addColor(cell.fg, false, mode)
  s.addColor(cell.bg, true, mode)
  s.add 'm'

func samePen(a, b: Cell): bool =
  a.fg == b.fg and a.bg == b.bg and a.attrs == b.attrs

proc toAnsi*(buf: CellBuffer; prev: CellBuffer; mode: ColorMode;
             full: bool): string =
  ## The escape sequences that turn a terminal showing `prev` into `buf`:
  ## only the cells that changed (every cell when `full`, or when the size
  ## differs). Leaves the pen reset.
  result = ""
  let all = full or prev.cols != buf.cols or prev.rows != buf.rows
  var penSet = false
  var pen = Cell()
  var curC = -1
  var curR = -1
  for r in 0 ..< buf.rows:
    for c in 0 ..< buf.cols:
      let i = buf.at(c, r)
      if buf.cells[i].glyph.len == 0:
        continue   # the right half of a wide glyph: written with its left
      let wide = c + 1 < buf.cols and buf.cells[i + 1].glyph.len == 0
      var changed = all or not (buf.cells[i] == prev.cells[i])
      if not changed and wide:
        changed = not (buf.cells[i + 1] == prev.cells[i + 1])
      if not changed:
        continue
      if curR != r or curC != c:
        result.add "\e["
        result.add $(r + 1)
        result.add ';'
        result.add $(c + 1)
        result.add 'H'
      if not penSet or not samePen(pen, buf.cells[i]):
        result.addPen(buf.cells[i], mode)
        pen = buf.cells[i]
        penSet = true
      result.add buf.cells[i].glyph
      curR = r
      curC = c + (if wide: 2 else: 1)
  if penSet:
    result.add "\e[0m"

proc toAnsiFrame*(buf: CellBuffer; mode: ColorMode): string =
  ## The whole picture as an ANSI text file: rows separated by newlines, no
  ## cursor motion -- `cat` it to see a snapshot in colour.
  result = ""
  for r in 0 ..< buf.rows:
    var penSet = false
    var pen = Cell()
    for c in 0 ..< buf.cols:
      let cell = buf.cells[buf.at(c, r)]
      if cell.glyph.len == 0:
        continue
      if not penSet or not samePen(pen, cell):
        result.addPen(cell, mode)
        pen = cell
        penSet = true
      result.add cell.glyph
    result.add "\e[0m\n"
