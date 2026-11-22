import std/[tables, strutils, algorithm, options]
import ../ui
import ./[common, editor, scrollbars]
import ellipse/platform/platform
import ../[ropes, languages]

type
  RopeEditorOpts* = object
    fontSize*, fontId*: uint16
    blocked*, readOnly*, autoIndent*: bool
    lineNumbers*: bool = true
    indent*: string = "    "
    indentAfter*: string
    lineHeight*: float32 ## Zero uses the font's line pitch.
    gutterWidth*: float32 ## Width reserved before the line numbers.
    activeLine*: int ## One-based line to highlight, or zero.
    activeLineBg*, activeLineFg*: Color
  RopeGutter* = proc(id: ElementId, line: int, cfg: TextConfig) {.closure, gcsafe.}
    ## Draws inside the gutter cell for a visible one-based line.
  TokenKind* = enum
    tkText, tkKeyword, tkSymbol, tkType, tkBuiltin, tkLiteral, tkNumber,
    tkString, tkComment
  Token* = object
    start*, stop*: int
    kind*: TokenKind
  Snapshot = object
    content: Rope
    caret, anchor: int
  RopeEditorState* = ref object
    caret*, anchor*: int
    undo, redo: seq[Snapshot]
    expected: Rope
    indexed: Rope
    starts: seq[int]
    opts*: RopeEditorOpts
    moved: bool
    recenter: bool
    pendingCount = -1
    lastOp = 0
    lastYank: tuple[start, length: int]

type
  RopeCommandProc* = proc(s: RopeEditorState, r: var Rope,
                          opts: RopeEditorOpts, n: int) {.closure.}
  RopeCommand = object
    run: RopeCommandProc
    writes: bool

var editors {.threadvar.}: Table[uint32, RopeEditorState]
var editorCommands {.threadvar.}: Table[string, RopeCommand]
var killRing {.threadvar.}: seq[string]
var yankIndex {.threadvar.}: int
var lastKill {.threadvar.}: tuple[at: int, forward: bool, active: bool]

proc byteAt(r: Rope, p: int): char =
  let c = r[p]
  if c.isSome: c.get else: '\0'

proc previous(r: Rope, p: int): int =
  result = max(0, p - 1)
  while result > 0 and (ord(r.byteAt(result)) and 0xc0) == 0x80: dec result

proc following(r: Rope, p: int): int =
  result = min(r.len, p + 1)
  while result < r.len and (ord(r.byteAt(result)) and 0xc0) == 0x80: inc result

proc bol(r: Rope, p: int): int =
  result = p
  while result > 0 and r.byteAt(result - 1) != '\n': dec result

proc eol(r: Rope, p: int): int =
  result = p
  while result < r.len and r.byteAt(result) != '\n': inc result

proc ropeEditorState*(id: ElementId): RopeEditorState =
  if not editors.hasKey(id.id): editors[id.id] = RopeEditorState()
  editors[id.id]

proc snapshot(s: RopeEditorState, r: Rope): Snapshot =
  Snapshot(content: r, caret: s.caret, anchor: s.anchor)

proc replaceSelection*(s: RopeEditorState, r: var Rope, text: string) =
  if s.opts.readOnly: return
  let lo = min(s.caret, s.anchor)
  let hi = max(s.caret, s.anchor)
  if lo == hi and text.len == 0: return
  s.undo.add s.snapshot(r)
  if s.undo.len > 512: s.undo.delete(0)
  s.redo.setLen(0)
  let previous = r
  r = r.delete(lo, hi).insert(lo, text)
  if s.indexed == previous and s.starts.len > 0:
    var starts: seq[int]
    for start in s.starts:
      if start <= lo: starts.add start
    for i, c in text:
      if c == '\n': starts.add lo + i + 1
    for start in s.starts:
      if start > hi: starts.add start + text.len - (hi - lo)
    s.starts = starts
    s.indexed = r
  s.caret = lo + text.len
  s.anchor = s.caret
  s.expected = r

proc restore(s: RopeEditorState, r: var Rope, redo: bool) =
  var snap: Snapshot
  if redo:
    if s.redo.len == 0: return
    s.undo.add s.snapshot(r)
    snap = s.redo.pop()
  else:
    if s.undo.len == 0: return
    s.redo.add s.snapshot(r)
    snap = s.undo.pop()
  r = snap.content
  s.caret = snap.caret
  s.anchor = snap.anchor
  s.expected = r

proc word(c: char): bool = c.isAlphaNumeric or c == '_' or ord(c) >= 128

proc highlightLine*(line: string, mode: LanguageMode): seq[Token] =
  var i = 0
  while i < line.len:
    let start = i
    var kind = tkText
    var comment = false
    for prefix in mode.lineComments:
      if prefix.len > 0 and line.continuesWith(prefix, i): comment = true
    if comment:
      kind = tkComment
      i = line.len
    elif $line[i] in mode.stringDelimiters:
      kind = tkString
      let quote = line[i]
      inc i
      while i < line.len:
        if line[i] == '\\': i = min(i + 2, line.len)
        elif line[i] == quote:
          inc i
          break
        else: inc i
    elif line[i].isDigit:
      kind = tkNumber
      inc i
      while i < line.len and (line[i].word or line[i] == '.'): inc i
    elif line[i].word:
      inc i
      while i < line.len and line[i].word: inc i
      let name = line[start ..< i]
      if name in mode.keywords: kind = tkKeyword
      elif name in mode.types: kind = tkType
      elif name in mode.builtins: kind = tkBuiltin
      elif name in mode.literals: kind = tkLiteral
    else:
      var longest = 0
      for symbol in mode.symbols:
        if symbol.len > longest and line.continuesWith(symbol, i): longest = symbol.len
      if longest > 0:
        kind = tkSymbol
        i += longest
      else: inc i
    result.add Token(start: start, stop: i, kind: kind)

type
  SyntaxColors* = object
    keyword*, symbol*, typeName*, builtin*, literal*, number*, str*, comment*: Color

const defaultSyntaxColors* = SyntaxColors(
  keyword: rgb(198, 120, 221), symbol: rgb(86, 182, 194),
  typeName: rgb(229, 192, 123), builtin: rgb(97, 175, 239),
  literal: rgb(209, 154, 102), number: rgb(209, 154, 102),
  str: rgb(152, 195, 121), comment: rgb(110, 120, 130))

var syntaxColors* = defaultSyntaxColors

proc tokenColor(kind: TokenKind): Color =
  case kind
  of tkKeyword: syntaxColors.keyword
  of tkSymbol: syntaxColors.symbol
  of tkType: syntaxColors.typeName
  of tkBuiltin: syntaxColors.builtin
  of tkLiteral: syntaxColors.literal
  of tkNumber: syntaxColors.number
  of tkString: syntaxColors.str
  of tkComment: syntaxColors.comment
  of tkText: activeTheme.palette.textColor

proc shiftLines(s: RopeEditorState, r: var Rope, indent: string, outdent: bool) =
  if s.opts.readOnly: return
  let before = s.snapshot(r)
  let lo = min(s.caret, s.anchor)
  var hi = max(s.caret, s.anchor)
  if hi > lo and r.byteAt(hi - 1) == '\n': dec hi
  var positions: seq[int]
  var removals: seq[int]
  var p = r.bol(lo)
  while true:
    positions.add p
    var count = 0
    if outdent:
      if r.byteAt(p) == '\t': count = 1
      else:
        while count < indent.len and r.byteAt(p + count) == ' ': inc count
    removals.add count
    let stop = r.eol(p)
    if stop >= hi: break
    p = stop + 1
  var caret = s.caret
  var anchor = s.anchor
  for i in countdown(positions.high, 0):
    let start = positions[i]
    if outdent:
      let count = removals[i]
      r = r.delete(start, start + count)
      caret -= clamp(caret - start, 0, count)
      anchor -= clamp(anchor - start, 0, count)
    else:
      r = r.insert(start, indent)
      if caret > start or (caret == start and before.caret == before.anchor): caret += indent.len
      if anchor > start or (anchor == start and before.caret == before.anchor): anchor += indent.len
  if r != before.content:
    s.undo.add before
    if s.undo.len > 512: s.undo.delete(0)
    s.redo.setLen(0)
  s.caret = caret
  s.anchor = anchor
  s.expected = r

proc wordTarget(r: Rope, pos: int, backward: bool): int =
  result = pos
  if backward:
    while result > 0 and not r.byteAt(r.previous(result)).word:
      result = r.previous(result)
    while result > 0 and r.byteAt(r.previous(result)).word:
      result = r.previous(result)
  else:
    while result < r.len and not r.byteAt(result).word:
      result = r.following(result)
    while result < r.len and r.byteAt(result).word:
      result = r.following(result)

# --- editor commands -----------------------------------------------------------
#
# Editing works as named commands, the way Emacs does. Movement, marks and
# edits live here; `handleKey` is a fallback keymap onto them, and owl
# bindings dispatch the same commands to the focused editor. Each command
# takes a numeric argument `n`, as with M-1 M-5 and friends.

proc clampPos(r: Rope, p: int): int =
  result = clamp(p, 0, r.len)
  while result > 0 and (ord(r.byteAt(result)) and 0xc0) == 0x80: dec result

proc region(s: RopeEditorState): (int, int) =
  (min(s.caret, s.anchor), max(s.caret, s.anchor))

proc moveTo(s: RopeEditorState, r: Rope, target: int, extend: bool) =
  s.caret = r.clampPos(target)
  if not extend: s.anchor = s.caret

proc startMove(s: RopeEditorState, forward: bool, extend: bool): int =
  let (lo, hi) = s.region
  result = s.caret
  if lo != hi and not extend:
    if forward and hi > result: result = hi
    elif not forward and lo < result: result = lo

proc charForward(s: RopeEditorState, r: Rope, n = 1, extend = false) =
  var target = s.startMove(true, extend)
  for unused in 0 ..< n: target = r.following(target)
  s.moveTo(r, target, extend)

proc charBackward(s: RopeEditorState, r: Rope, n = 1, extend = false) =
  var target = s.startMove(false, extend)
  for unused in 0 ..< n: target = r.previous(target)
  s.moveTo(r, target, extend)

proc wordForward(s: RopeEditorState, r: Rope, n = 1, extend = false) =
  var target = s.caret
  for unused in 0 ..< n: target = r.wordTarget(target, false)
  s.moveTo(r, target, extend)

proc wordBackward(s: RopeEditorState, r: Rope, n = 1, extend = false) =
  var target = s.caret
  for unused in 0 ..< n: target = r.wordTarget(target, true)
  s.moveTo(r, target, extend)

proc lineStart(s: RopeEditorState, r: Rope, extend = false) =
  s.moveTo(r, r.bol(s.caret), extend)

proc lineEnd(s: RopeEditorState, r: Rope, extend = false) =
  s.moveTo(r, r.eol(s.caret), extend)

proc bufferStart(s: RopeEditorState, r: Rope, extend = false) =
  s.moveTo(r, 0, extend)

proc bufferEnd(s: RopeEditorState, r: Rope, extend = false) =
  s.moveTo(r, r.len, extend)

proc lineStep(r: Rope, target: int, up: bool): int =
  let column = target - r.bol(target)
  result = target
  if up:
    if r.bol(result) == 0: return result
    result = r.bol(r.bol(result) - 1)
  else:
    if r.eol(result) == r.len: return result
    result = r.eol(result) + 1
  result = min(r.eol(result), r.bol(result) + column)

proc lineUp(s: RopeEditorState, r: Rope, n = 1, extend = false) =
  var target = s.caret
  for unused in 0 ..< n:
    let next = r.lineStep(target, true)
    if next == target: break
    target = next
  s.moveTo(r, target, extend)

proc lineDown(s: RopeEditorState, r: Rope, n = 1, extend = false) =
  var target = s.caret
  for unused in 0 ..< n:
    let next = r.lineStep(target, false)
    if next == target: break
    target = next
  s.moveTo(r, target, extend)

proc pageUp(s: RopeEditorState, r: Rope, n = 1, extend = false) =
  s.lineUp(r, 20 * max(n, 1), extend)

proc pageDown(s: RopeEditorState, r: Rope, n = 1, extend = false) =
  s.lineDown(r, 20 * max(n, 1), extend)

proc blankLine(r: Rope, start: int): bool =
  r.slice(start, r.eol(start)).flatten.strip.len == 0

proc paragraphForward(s: RopeEditorState, r: Rope, n = 1, extend = false) =
  var target = s.caret
  for unused in 0 ..< n:
    var p = r.eol(target)
    if p >= r.len:
      target = r.len
      break
    p = p + 1
    while p < r.len and r.blankLine(p): p = min(r.eol(p) + 1, r.len)
    while p < r.len and not r.blankLine(p): p = min(r.eol(p) + 1, r.len)
    while p < r.len and r.blankLine(p): p = min(r.eol(p) + 1, r.len)
    target = p
  s.moveTo(r, target, extend)

proc paragraphBackward(s: RopeEditorState, r: Rope, n = 1, extend = false) =
  var target = s.caret
  for unused in 0 ..< n:
    let b = r.bol(target)
    var p = if target > b: b elif b == 0: 0 else: r.bol(b - 1)
    while p > 0 and r.blankLine(p): p = r.bol(r.previous(p))
    while p > 0:
      let up = r.bol(p - 1)
      if up >= p or r.blankLine(up): break
      p = up
    target = p
  s.moveTo(r, target, extend)

proc setMark(s: RopeEditorState) =
  s.anchor = s.caret
  s.lastOp = 0

proc keyboardQuit(s: RopeEditorState) =
  s.anchor = s.caret
  s.pendingCount = -1
  s.lastOp = 0

proc recenter(s: RopeEditorState) =
  s.recenter = true

proc exchangePointAndMark(s: RopeEditorState) =
  swap(s.caret, s.anchor)

proc markWhole(s: RopeEditorState, r: Rope) =
  s.anchor = 0
  s.caret = r.len

proc selectAll(s: RopeEditorState, r: Rope) =
  s.markWhole(r)

proc markWord(s: RopeEditorState, r: Rope, n = 1) =
  s.anchor = s.caret
  s.caret = r.clampPos(r.wordTarget(s.caret, n < 0))

proc markParagraph(s: RopeEditorState, r: Rope, n = 1) =
  s.anchor = s.caret
  if n < 0:
    var p = r.bol(s.caret)
    while p > 0 and not r.blankLine(p):
      let up = r.bol(r.previous(p - 1))
      if up >= p or r.blankLine(up): break
      p = up
    s.caret = r.clampPos(p)
  else:
    var p = s.caret
    while p < r.len and not r.blankLine(r.bol(p)): p = min(r.eol(p) + 1, r.len)
    while p > 0 and r.byteAt(r.previous(p)) == '\n': p = r.previous(p)
    s.caret = r.clampPos(p)

proc followingN(r: Rope, p: int, n: int): int =
  result = p
  for unused in 0 ..< n: result = r.following(result)

proc previousN(r: Rope, p: int, n: int): int =
  result = p
  for unused in 0 ..< n: result = r.previous(result)

proc killText(s: RopeEditorState, r: var Rope, lo, hi: int, forward: bool) =
  if s.opts.readOnly or hi <= lo: return
  let text = r.slice(lo, hi).flatten
  let edge = if forward: lo else: hi
  if lastKill.active and lastKill.at == edge and lastKill.forward == forward and
      killRing.len > 0:
    if forward: killRing[0] = killRing[0] & text
    else: killRing[0] = text & killRing[0]
  else:
    killRing.insert(text)
    if killRing.len > 64: killRing.setLen(64)
  lastKill = (at: lo, forward: forward, active: true)
  yankIndex = 0
  setClipboard(text)
  s.caret = hi
  s.anchor = lo
  s.replaceSelection(r, "")
  s.lastOp = 1

proc killRegion(s: RopeEditorState, r: var Rope) =
  let (lo, hi) = s.region
  if hi > lo: s.killText(r, lo, hi, true)

proc copyRegion(s: RopeEditorState, r: Rope) =
  let (lo, hi) = s.region
  if hi > lo:
    let text = r.slice(lo, hi).flatten
    killRing.insert(text)
    if killRing.len > 64: killRing.setLen(64)
    yankIndex = 0
    setClipboard(text)
  lastKill.active = false
  s.lastOp = 0

proc killLine(s: RopeEditorState, r: var Rope) =
  let (lo, hi) = s.region
  if hi > lo:
    s.killText(r, lo, hi, true)
  else:
    var stop = r.eol(lo)
    if stop == lo:
      if lo < r.len: stop = lo + 1
      else: return
    s.killText(r, lo, stop, true)

proc deleteChar(s: RopeEditorState, r: var Rope, n = 1) =
  lastKill.active = false
  let (lo, hi) = s.region
  if lo != hi:
    s.replaceSelection(r, "")
  else:
    s.caret = lo
    s.anchor = r.followingN(lo, max(n, 1))
    s.replaceSelection(r, "")

proc backwardDelete(s: RopeEditorState, r: var Rope, n = 1) =
  lastKill.active = false
  let (lo, hi) = s.region
  if lo != hi:
    s.replaceSelection(r, "")
  else:
    s.anchor = r.previousN(hi, max(n, 1))
    s.caret = hi
    s.replaceSelection(r, "")

proc killWord(s: RopeEditorState, r: var Rope, n = 1) =
  let (lo, hi) = s.region
  if lo != hi:
    s.killText(r, lo, hi, true)
  else:
    let target = r.wordTarget(hi, false)
    if target > hi: s.killText(r, hi, target, true)

proc backwardKillWord(s: RopeEditorState, r: var Rope, n = 1) =
  let (lo, hi) = s.region
  if lo != hi:
    s.killText(r, lo, hi, false)
  else:
    let target = r.wordTarget(lo, true)
    if target < lo: s.killText(r, target, lo, false)

proc yank(s: RopeEditorState, r: var Rope, n = 1) =
  if killRing.len == 0:
    let text = getClipboard().replace("\r", "")
    if text.len == 0: return
    let lo = min(s.caret, s.anchor)
    s.replaceSelection(r, text)
    s.lastYank = (start: lo, length: text.len)
    s.lastOp = 2
    return
  yankIndex = 0
  let text = killRing[0]
  let lo = min(s.caret, s.anchor)
  var inserted = ""
  for unused in 0 ..< max(n, 1): inserted.add text
  s.replaceSelection(r, inserted)
  s.lastYank = (start: lo, length: inserted.len)
  s.lastOp = 2
  lastKill.active = false

proc yankPop(s: RopeEditorState, r: var Rope) =
  if s.lastOp != 2 or killRing.len == 0: return
  if s.caret != s.lastYank.start + s.lastYank.length: return
  yankIndex = (yankIndex + 1) mod killRing.len
  s.anchor = s.lastYank.start
  s.replaceSelection(r, killRing[yankIndex])
  s.lastYank = (start: s.lastYank.start, length: killRing[yankIndex].len)
  s.lastOp = 2

proc paste(s: RopeEditorState, r: var Rope) =
  lastKill.active = false
  s.replaceSelection(r, getClipboard().replace("\r", ""))

proc undo(s: RopeEditorState, r: var Rope, n = 1, redo = false) =
  lastKill.active = false
  for unused in 0 ..< max(n, 1): s.restore(r, redo)
  s.lastOp = 0

proc redo(s: RopeEditorState, r: var Rope, n = 1) =
  lastKill.active = false
  for unused in 0 ..< max(n, 1): s.restore(r, true)
  s.lastOp = 0

func asciiUpper(c: char): char =
  if c in 'a' .. 'z': char(ord(c) - 32) else: c

func asciiLower(c: char): char =
  if c in 'A' .. 'Z': char(ord(c) + 32) else: c

func caseText(text, mode: string): string =
  var first = true
  for c in text:
    case mode
    of "up": result.add c.asciiUpper
    of "down": result.add c.asciiLower
    else:
      result.add (if first and c != ' ': c.asciiUpper else: c)
      if c.word: first = false

proc wordRegion(s: RopeEditorState, r: Rope, n: int): (int, int) =
  if n < 0:
    let lo = r.wordTarget(s.caret, true)
    (lo, s.caret)
  else:
    let hi = r.wordTarget(s.caret, false)
    (s.caret, hi)

proc changeWord(s: RopeEditorState, r: var Rope, n: int, mode: string) =
  let (lo, hi) = s.wordRegion(r, n)
  if hi <= lo: return
  let text = r.slice(lo, hi).flatten
  s.caret = lo
  s.anchor = hi
  s.replaceSelection(r, caseText(text, mode))
  lastKill.active = false
  s.lastOp = 0

proc newline(s: RopeEditorState, r: var Rope, opts: RopeEditorOpts,
             forceIndent = false) =
  if opts.readOnly: return
  let (lo, hi) = s.region
  var ins = "\n"
  if opts.autoIndent or forceIndent:
    var p = r.bol(lo)
    while p < lo and r.byteAt(p) in {' ', '\t'}:
      ins.add r.byteAt(p)
      inc p
    if opts.indentAfter.len > 0 and
        r.slice(r.bol(lo), lo).flatten.strip.endsWith(opts.indentAfter):
      ins.add opts.indent
  s.replaceSelection(r, ins)

proc openLine(s: RopeEditorState, r: var Rope, opts: RopeEditorOpts) =
  if opts.readOnly: return
  let (lo, hi) = s.region
  var ins = "\n"
  if opts.autoIndent:
    var p = r.bol(lo)
    while p < lo and r.byteAt(p) in {' ', '\t'}:
      ins.add r.byteAt(p)
      inc p
  s.replaceSelection(r, ins)
  s.caret = min(lo + 1, r.len)
  s.anchor = s.caret
  s.lastOp = 0

proc spaceAround(r: Rope, pos: int): (int, int) =
  var a = pos
  while a > 0 and r.byteAt(a - 1) in {' ', '\t'}: dec a
  var b = pos
  while b < r.len and r.byteAt(b) in {' ', '\t'}: inc b
  (a, b)

proc justOneSpace(s: RopeEditorState, r: var Rope) =
  let (lo, hi) = s.region
  if lo != hi: s.replaceSelection(r, "")
  var (a, b) = r.spaceAround(s.caret)
  if a == b:
    a = s.caret
    b = s.caret
  s.caret = a
  s.anchor = b
  s.replaceSelection(r, " ")

proc deleteHorizontalSpace(s: RopeEditorState, r: var Rope) =
  let (lo, hi) = s.region
  if lo != hi: s.replaceSelection(r, "")
  let (a, b) = r.spaceAround(s.caret)
  s.caret = a
  s.anchor = b
  s.replaceSelection(r, "")

proc blankAt(r: Rope, pos: int): bool =
  r.slice(r.bol(pos), r.eol(pos)).flatten.strip.len == 0

proc deleteBlankLines(s: RopeEditorState, r: var Rope) =
  let (a, b) = s.region
  if a != b: s.replaceSelection(r, "")
  if not r.blankAt(s.caret): return
  var lo = r.bol(s.caret)
  while lo > 0 and r.blankAt(lo - 1):
    let up = r.bol(r.previous(lo - 1))
    if up >= lo: break
    lo = up
  var hi = r.eol(s.caret) + 1
  while hi < r.len and r.blankAt(hi): hi = r.eol(hi) + 1
  if hi - lo > 2:
    s.caret = lo
    s.anchor = hi
    s.replaceSelection(r, "\n\n")

proc transposeChars(s: RopeEditorState, r: var Rope, n = 1) =
  for unused in 0 ..< max(n, 1):
    let p = s.caret
    if p == 0 or r.len < 2: break
    let x = r.previous(p)
    if p < r.len and r.byteAt(p) != '\n':
      let z = r.following(p)
      let c1 = r.slice(x, p).flatten
      let c2 = r.slice(p, z).flatten
      s.caret = x
      s.anchor = z
      s.replaceSelection(r, c2 & c1)
      s.caret = x + c2.len + c1.len
      s.anchor = s.caret
    else:
      let y = r.previous(x)
      if y == x: break
      let c1 = r.slice(y, x).flatten
      let c2 = r.slice(x, p).flatten
      s.caret = y
      s.anchor = p
      s.replaceSelection(r, c2 & c1)
      s.caret = y + c2.len + c1.len
      s.anchor = s.caret
  lastKill.active = false
  s.lastOp = 0

proc transposeWords(s: RopeEditorState, r: var Rope, n = 1) =
  for unused in 0 ..< max(n, 1):
    let w2End = r.wordTarget(s.caret, false)
    let w2Start = r.wordTarget(w2End, true)
    let w1Start = r.wordTarget(w2Start, true)
    let w1End = r.wordTarget(w1Start, false)
    if w1Start == w2Start or w1End > w2Start or w2End <= w2Start: break
    let t1 = r.slice(w1Start, w1End).flatten
    let sep = r.slice(w1End, w2Start).flatten
    let t2 = r.slice(w2Start, w2End).flatten
    s.caret = w1Start
    s.anchor = w2End
    s.replaceSelection(r, t2 & sep & t1)
    s.caret = w2End
    s.anchor = s.caret
  lastKill.active = false
  s.lastOp = 0

proc transposeLines(s: RopeEditorState, r: var Rope) =
  let cur = r.bol(s.caret)
  if cur == 0: return
  let prev = r.bol(r.previous(cur))
  if prev == cur: return
  let e = r.eol(s.caret)
  let line2 = r.slice(cur, e).flatten
  let line1 = r.slice(prev, cur - 1).flatten
  let last = e == r.len
  let repl = line2 & "\n" & line1 & (if last: "" else: "\n")
  s.caret = prev
  s.anchor = if last: r.len else: e + 1
  s.replaceSelection(r, repl)
  s.caret = prev
  s.anchor = s.caret
  lastKill.active = false
  s.lastOp = 0

proc indentForTab(s: RopeEditorState, r: var Rope, opts: RopeEditorOpts,
                  outdent = false) =
  if opts.readOnly or opts.indent.len == 0: return
  let (lo, hi) = s.region
  if outdent or (hi > lo and r.bol(lo) != r.bol(hi)):
    s.shiftLines(r, opts.indent, outdent or hi == lo)
  else:
    s.replaceSelection(r, opts.indent)
  lastKill.active = false
  s.lastOp = 0


proc digitArgument(s: RopeEditorState, d: int) =
  s.pendingCount = (if s.pendingCount >= 0: s.pendingCount else: 0) * 10 +
    clamp(d, 0, 9)

proc universalArgument(s: RopeEditorState) =
  s.pendingCount = if s.pendingCount >= 0: s.pendingCount * 4 else: 4

proc reg(name: string, run: RopeCommandProc, writes = false) =
  editorCommands[name] = RopeCommand(run: run, writes: writes)

proc cmdBackwardChar(s: RopeEditorState, r: var Rope, opts: RopeEditorOpts, n: int) = s.charBackward(r, n)
proc cmdForwardChar(s: RopeEditorState, r: var Rope, opts: RopeEditorOpts, n: int) = s.charForward(r, n)
proc cmdPreviousLine(s: RopeEditorState, r: var Rope, opts: RopeEditorOpts, n: int) = s.lineUp(r, abs(n))
proc cmdNextLine(s: RopeEditorState, r: var Rope, opts: RopeEditorOpts, n: int) = s.lineDown(r, abs(n))
proc cmdBackwardWord(s: RopeEditorState, r: var Rope, opts: RopeEditorOpts, n: int) = s.wordBackward(r, abs(n))
proc cmdForwardWord(s: RopeEditorState, r: var Rope, opts: RopeEditorOpts, n: int) = s.wordForward(r, abs(n))
proc cmdLineStart(s: RopeEditorState, r: var Rope, opts: RopeEditorOpts, n: int) = s.lineStart(r)
proc cmdLineEnd(s: RopeEditorState, r: var Rope, opts: RopeEditorOpts, n: int) = s.lineEnd(r)
proc cmdBufferStart(s: RopeEditorState, r: var Rope, opts: RopeEditorOpts, n: int) = s.bufferStart(r)
proc cmdBufferEnd(s: RopeEditorState, r: var Rope, opts: RopeEditorOpts, n: int) = s.bufferEnd(r)
proc cmdBackwardParagraph(s: RopeEditorState, r: var Rope, opts: RopeEditorOpts, n: int) = s.paragraphBackward(r, abs(n))
proc cmdForwardParagraph(s: RopeEditorState, r: var Rope, opts: RopeEditorOpts, n: int) = s.paragraphForward(r, abs(n))
proc cmdScrollUp(s: RopeEditorState, r: var Rope, opts: RopeEditorOpts, n: int) = s.pageDown(r, abs(n))
proc cmdScrollDown(s: RopeEditorState, r: var Rope, opts: RopeEditorOpts, n: int) = s.pageUp(r, abs(n))
proc cmdSetMark(s: RopeEditorState, r: var Rope, opts: RopeEditorOpts, n: int) = s.setMark()
proc cmdKeyboardQuit(s: RopeEditorState, r: var Rope, opts: RopeEditorOpts, n: int) = s.keyboardQuit()
proc cmdExchange(s: RopeEditorState, r: var Rope, opts: RopeEditorOpts, n: int) = s.exchangePointAndMark()
proc cmdMarkWhole(s: RopeEditorState, r: var Rope, opts: RopeEditorOpts, n: int) = s.markWhole(r)
proc cmdMarkWord(s: RopeEditorState, r: var Rope, opts: RopeEditorOpts, n: int) = s.markWord(r, n)
proc cmdMarkParagraph(s: RopeEditorState, r: var Rope, opts: RopeEditorOpts, n: int) = s.markParagraph(r, n)
proc cmdRecenter(s: RopeEditorState, r: var Rope, opts: RopeEditorOpts, n: int) = s.recenter()
proc cmdDigitArgument(s: RopeEditorState, r: var Rope, opts: RopeEditorOpts, n: int) = s.digitArgument(n)
proc cmdUniversalArgument(s: RopeEditorState, r: var Rope, opts: RopeEditorOpts, n: int) = s.universalArgument()
proc cmdDeleteChar(s: RopeEditorState, r: var Rope, opts: RopeEditorOpts, n: int) = s.deleteChar(r, n)
proc cmdBackwardDelete(s: RopeEditorState, r: var Rope, opts: RopeEditorOpts, n: int) = s.backwardDelete(r, n)
proc cmdKillLine(s: RopeEditorState, r: var Rope, opts: RopeEditorOpts, n: int) = s.killLine(r)
proc cmdKillWord(s: RopeEditorState, r: var Rope, opts: RopeEditorOpts, n: int) = s.killWord(r, n)
proc cmdBackwardKillWord(s: RopeEditorState, r: var Rope, opts: RopeEditorOpts, n: int) = s.backwardKillWord(r, n)
proc cmdKillRegion(s: RopeEditorState, r: var Rope, opts: RopeEditorOpts, n: int) = s.killRegion(r)
proc cmdCopyRegion(s: RopeEditorState, r: var Rope, opts: RopeEditorOpts, n: int) = s.copyRegion(r)
proc cmdYank(s: RopeEditorState, r: var Rope, opts: RopeEditorOpts, n: int) = s.yank(r, n)
proc cmdYankPop(s: RopeEditorState, r: var Rope, opts: RopeEditorOpts, n: int) = s.yankPop(r)
proc cmdPaste(s: RopeEditorState, r: var Rope, opts: RopeEditorOpts, n: int) = s.paste(r)
proc cmdUndo(s: RopeEditorState, r: var Rope, opts: RopeEditorOpts, n: int) = s.undo(r, n)
proc cmdRedo(s: RopeEditorState, r: var Rope, opts: RopeEditorOpts, n: int) = s.redo(r, n)
proc cmdNewline(s: RopeEditorState, r: var Rope, opts: RopeEditorOpts, n: int) = s.newline(r, opts)
proc cmdNewlineAndIndent(s: RopeEditorState, r: var Rope, opts: RopeEditorOpts, n: int) = s.newline(r, opts, forceIndent = true)
proc cmdOpenLine(s: RopeEditorState, r: var Rope, opts: RopeEditorOpts, n: int) = s.openLine(r, opts)
proc cmdJustOneSpace(s: RopeEditorState, r: var Rope, opts: RopeEditorOpts, n: int) = s.justOneSpace(r)
proc cmdDeleteHorizontalSpace(s: RopeEditorState, r: var Rope, opts: RopeEditorOpts, n: int) = s.deleteHorizontalSpace(r)
proc cmdDeleteBlankLines(s: RopeEditorState, r: var Rope, opts: RopeEditorOpts, n: int) = s.deleteBlankLines(r)
proc cmdUpcaseWord(s: RopeEditorState, r: var Rope, opts: RopeEditorOpts, n: int) = s.changeWord(r, n, "up")
proc cmdDowncaseWord(s: RopeEditorState, r: var Rope, opts: RopeEditorOpts, n: int) = s.changeWord(r, n, "down")
proc cmdCapitalizeWord(s: RopeEditorState, r: var Rope, opts: RopeEditorOpts, n: int) = s.changeWord(r, n, "cap")
proc cmdTransposeChars(s: RopeEditorState, r: var Rope, opts: RopeEditorOpts, n: int) = s.transposeChars(r, n)
proc cmdTransposeWords(s: RopeEditorState, r: var Rope, opts: RopeEditorOpts, n: int) = s.transposeWords(r, n)
proc cmdTransposeLines(s: RopeEditorState, r: var Rope, opts: RopeEditorOpts, n: int) = s.transposeLines(r)
proc cmdIndentForTab(s: RopeEditorState, r: var Rope, opts: RopeEditorOpts, n: int) = s.indentForTab(r, opts)
proc cmdShiftRight(s: RopeEditorState, r: var Rope, opts: RopeEditorOpts, n: int) = s.shiftLines(r, opts.indent, false)
proc cmdShiftLeft(s: RopeEditorState, r: var Rope, opts: RopeEditorOpts, n: int) = s.shiftLines(r, opts.indent, true)

proc declareRopeCommands() =
  reg("backward-char", cmdBackwardChar)
  reg("forward-char", cmdForwardChar)
  reg("previous-line", cmdPreviousLine)
  reg("next-line", cmdNextLine)
  reg("backward-word", cmdBackwardWord)
  reg("forward-word", cmdForwardWord)
  reg("move-beginning-of-line", cmdLineStart)
  reg("move-end-of-line", cmdLineEnd)
  reg("beginning-of-buffer", cmdBufferStart)
  reg("end-of-buffer", cmdBufferEnd)
  reg("backward-paragraph", cmdBackwardParagraph)
  reg("forward-paragraph", cmdForwardParagraph)
  reg("scroll-up-command", cmdScrollUp)
  reg("scroll-down-command", cmdScrollDown)
  reg("set-mark-command", cmdSetMark)
  reg("keyboard-quit", cmdKeyboardQuit)
  reg("exchange-point-and-mark", cmdExchange)
  reg("mark-whole-buffer", cmdMarkWhole)
  reg("mark-word", cmdMarkWord)
  reg("mark-paragraph", cmdMarkParagraph)
  reg("recenter", cmdRecenter)
  reg("digit-argument", cmdDigitArgument)
  reg("universal-argument", cmdUniversalArgument)
  reg("delete-char", cmdDeleteChar, true)
  reg("backward-delete-char", cmdBackwardDelete, true)
  reg("kill-line", cmdKillLine, true)
  reg("kill-word", cmdKillWord, true)
  reg("backward-kill-word", cmdBackwardKillWord, true)
  reg("kill-region", cmdKillRegion, true)
  reg("copy-region-as-kill", cmdCopyRegion, true)
  reg("yank", cmdYank, true)
  reg("yank-pop", cmdYankPop, true)
  reg("paste", cmdPaste, true)
  reg("undo", cmdUndo, true)
  reg("redo", cmdRedo, true)
  reg("newline", cmdNewline, true)
  reg("newline-and-indent", cmdNewlineAndIndent, true)
  reg("open-line", cmdOpenLine, true)
  reg("just-one-space", cmdJustOneSpace, true)
  reg("delete-horizontal-space", cmdDeleteHorizontalSpace, true)
  reg("delete-blank-lines", cmdDeleteBlankLines, true)
  reg("upcase-word", cmdUpcaseWord, true)
  reg("downcase-word", cmdDowncaseWord, true)
  reg("capitalize-word", cmdCapitalizeWord, true)
  reg("transpose-chars", cmdTransposeChars, true)
  reg("transpose-words", cmdTransposeWords, true)
  reg("transpose-lines", cmdTransposeLines, true)
  reg("indent-for-tab-command", cmdIndentForTab, true)
  reg("shift-region-right", cmdShiftRight, true)
  reg("shift-region-left", cmdShiftLeft, true)

proc runRopeCommand*(s: RopeEditorState, r: var Rope, name: string,
                     opts = s.opts, count = 1): bool =
  if editorCommands.len == 0: declareRopeCommands()
  if not editorCommands.hasKey(name): return false
  let entry = editorCommands[name]
  if entry.writes and opts.readOnly: return false
  let n = if s.pendingCount >= 0 and name != "digit-argument" and
             name != "universal-argument": s.pendingCount else: count
  s.opts = opts
  entry.run(s, r, opts, n)
  if name != "digit-argument" and name != "universal-argument":
    s.pendingCount = -1
  s.moved = true
  true

proc ropeCommandNames*(): seq[string] =
  if editorCommands.len == 0: declareRopeCommands()
  for name in editorCommands.keys:
    result.add name
  result.sort()

proc focusedRopeEditor*(): ElementId =
  for id in editors.keys:
    if focused(elementIdFromId(id)):
      return elementIdFromId(id)
  ElementId()

proc handleKey*(s: RopeEditorState, r: var Rope, ev: KeyEvent,
                opts = RopeEditorOpts()) =
  s.opts = opts
  let ext = ev.shift
  let (lo, hi) = s.region
  if ev.kind == kevLetter:
    if ev.ctrl and not ev.alt:
      case ev.ch
      of 'a': s.lineStart(r, ext)
      of 'b': s.charBackward(r, 1, ext)
      of 'd': s.deleteChar(r, 1)
      of 'e': s.lineEnd(r, ext)
      of 'f': s.charForward(r, 1, ext)
      of 'g': s.keyboardQuit()
      of 'h': s.backwardDelete(r, 1)
      of 'j': s.newline(r, opts, forceIndent = true)
      of 'k': s.killLine(r)
      of 'l': s.recenter()
      of 'm': s.newline(r, opts)
      of 'n': s.lineDown(r, 1, ext)
      of 'o': s.openLine(r, opts)
      of 'p': s.lineUp(r, 1, ext)
      of 'u':
        s.universalArgument()
        return
      of 'y':
        if not opts.readOnly: s.restore(r, true)
      of 'z':
        if not opts.readOnly: s.restore(r, ext)
      of 'c': s.copyRegion(r)
      of 'v': s.paste(r)
      of 'x': s.killRegion(r)
      else: discard
      if s.pendingCount >= 0: s.pendingCount = -1
      s.moved = true
      return
    elif ev.alt and not ev.ctrl:
      if ev.ch in {'0' .. '9'}:
        s.digitArgument(ord(ev.ch) - ord('0'))
        return
      let n = if s.pendingCount >= 0: s.pendingCount else: 1
      s.pendingCount = -1
      case ev.ch
      of 'a': s.selectAll(r)
      of 'b': s.wordBackward(r, abs(n), ext)
      of 'c': s.changeWord(r, n, "cap")
      of 'd': s.killWord(r, n)
      of 'f': s.wordForward(r, abs(n), ext)
      of 'h': s.markParagraph(r)
      of 'l': s.changeWord(r, n, "down")
      of 'p': s.paragraphBackward(r, abs(n), ext)
      of 't': s.transposeWords(r, n)
      of 'u': s.changeWord(r, n, "up")
      of 'v': s.pageUp(r, abs(n), ext)
      of 'w': s.copyRegion(r)
      of 'y': s.yankPop(r)
      of '[': s.paragraphBackward(r, abs(n), ext)
      of ']': s.paragraphForward(r, abs(n), ext)
      of '<': s.bufferStart(r, ext)
      of '>': s.bufferEnd(r, ext)
      of ' ': s.justOneSpace(r)
      of '\\': s.deleteHorizontalSpace(r)
      else: discard
      s.moved = true
      return
  let n = if s.pendingCount >= 0: s.pendingCount else: 1
  s.pendingCount = -1
  case ev.kind
  of kevText:
    if not opts.readOnly:
      s.replaceSelection(r, ev.text.replace("\r", ""))
      lastKill.active = false
      s.lastOp = 0
  of kevEnter: s.newline(r, opts)
  of kevTab: s.indentForTab(r, opts, outdent = ev.shift)
  of kevBackspace:
    if ev.ctrl or ev.alt: s.backwardKillWord(r, n)
    else: s.backwardDelete(r, n)
  of kevDelete:
    if ev.ctrl or ev.alt: s.backwardKillWord(r, n)
    else: s.deleteChar(r, n)
  of kevLeft:
    if ev.ctrl or ev.alt: s.wordBackward(r, abs(n), ext)
    elif lo != hi and not ext: s.moveTo(r, lo, false)
    else: s.charBackward(r, n, ext)
  of kevRight:
    if ev.ctrl or ev.alt: s.wordForward(r, abs(n), ext)
    elif lo != hi and not ext: s.moveTo(r, hi, false)
    else: s.charForward(r, n, ext)
  of kevHome:
    if ev.ctrl: s.bufferStart(r, ext) else: s.lineStart(r, ext)
  of kevEnd:
    if ev.ctrl: s.bufferEnd(r, ext) else: s.lineEnd(r, ext)
  of kevUp: s.lineUp(r, n, ext)
  of kevDown: s.lineDown(r, n, ext)
  of kevPageUp: s.pageUp(r, n, ext)
  of kevPageDown: s.pageDown(r, n, ext)
  else: discard
  s.moved = true

proc ropeEditor*(id: ElementId, content: var Rope, opts = RopeEditorOpts(),
                 mode = LanguageMode(), gutter: RopeGutter = nil): bool {.discardable.} =
  let s = ropeEditorState(id)
  s.opts = opts
  if s.expected != content:
    s.undo.setLen(0)
    s.redo.setLen(0)
    s.caret = min(s.caret, content.len)
    s.anchor = min(s.anchor, content.len)
  let before = content
  let oldCaret = s.caret
  let fontSize = if opts.fontSize > 0: opts.fontSize else: activeTheme.text.control
  let cfg = TextConfig(fontSize: fontSize, fontId: opts.fontId, wrap: noWrap)
  if not opts.blocked:
    if clickedIn(id): setFocus(id)
    elif focused(id) and clickedOut(id): blur()
    if focused(id):
      for ev in frameKeys(): s.handleKey(content, ev, opts)
  s.expected = content
  if s.indexed != content or s.starts.len == 0:
    s.starts = @[0]
    var offset = 0
    for chunk in content.chunks:
      for c in chunk:
        inc offset
        if c == '\n': s.starts.add offset
    s.indexed = content
  let pitch = if opts.lineHeight > 0: opts.lineHeight else: linePitch(cfg)
  let numCfg = TextConfig(fontSize: fontSize, fontId: opts.fontId, wrap: noWrap,
                          color: activeTheme.palette.dimColor)
  let numberWidth = if opts.lineNumbers:
    # Reserve the widest possible number so every line's text starts at
    # the same x, whatever the buffer's length.
    measureTextCached(currentContext(), "9".repeat(($ (s.starts.high + 1)).len),
                      cfg).unwrapped.width + 12.0'f32
  else: 0.0'f32
  let gutterW = opts.gutterWidth + numberWidth
  var firstLine = 0
  var lastLine = min(s.starts.high, int(layoutDimensions().height / max(pitch, 1.0'f32)) + 3)
  item id, col(width = grow(), height = grow()).padding(padAll(4))
      .bg(activeTheme.palette.fieldBg)
      .clip(horizontal = true, vertical = true, childOffset = currentScrollOffset()):
    # The scroll container only becomes queryable once its clip has been
    # declared this frame: `beginLayout` clears the element array, so
    # consulting `scrollContainerData` before the item opens always reads
    # `found == false` and pins the window to the fallback line range.
    let sd = scrollContainerData(id)
    if sd.found:
      if focused(id) and (oldCaret != s.caret or content != before or s.moved):
        var caretLine = 0
        while caretLine < s.starts.high and s.starts[caretLine + 1] <= s.caret: inc caretLine
        var position = sd.position
        let y = float32(caretLine) * pitch
        if s.recenter:
          position.y = (sd.containerDimensions.height - pitch) / 2 - y
        elif y + position.y < 0: position.y = -y
        elif y + pitch + position.y > sd.containerDimensions.height - 8:
          position.y = sd.containerDimensions.height - 8 - y - pitch
        let prefix = content.slice(s.starts[caretLine], s.caret).flatten
        let x = gutterW +
          measureTextCached(currentContext(), prefix, cfg).unwrapped.width
        if x + position.x < 0: position.x = -x
        elif x + position.x > sd.containerDimensions.width - 24:
          position.x = sd.containerDimensions.width - 24 - x
        setScrollPosition(id, position)
      s.moved = false
      s.recenter = false
      let offset = scrollContainerData(id).position.y
      firstLine = clamp(int(-offset / max(pitch, 1.0'f32)) - 1, 0, s.starts.high)
      lastLine = min(s.starts.high, firstLine + int(sd.containerDimensions.height / max(pitch, 1.0'f32)) + 3)
    if firstLine > 0:
      item localId("rope.top", id.id), col(width = fixedPx(1), height = fixedPx(float32(firstLine) * pitch)):
        discard
    for lineIndex in firstLine .. lastLine:
      let start = s.starts[lineIndex]
      let stop = if lineIndex < s.starts.high: s.starts[lineIndex + 1] - 1 else: content.len
      let line = content.slice(start, stop).flatten
      let lineId = localId("rope.line." & $lineIndex, id.id)
      let active = lineIndex + 1 == opts.activeLine
      var lineDecl = row(width = (if active: grow() else: fit()),
                         height = fixedPx(pitch), alignY = centerY)
      if active: lineDecl = lineDecl.bg(opts.activeLineBg)
      item lineId, lineDecl:
        if opts.gutterWidth > 0:
          let gutterId = localId("rope.gutter", lineId.id)
          item gutterId, row(width = fixedPx(opts.gutterWidth), height = fixedPx(pitch),
                             alignX = centerX, alignY = centerY):
            if gutter != nil: gutter(gutterId, lineIndex + 1, cfg)
        if opts.lineNumbers:
          item localId("rope.num", lineId.id),
               row(width = fixedPx(numberWidth), height = fixedPx(pitch),
                   padding = Padding(right: 12), alignX = right, alignY = centerY):
            var lineNumCfg = numCfg
            if active: lineNumCfg.color = opts.activeLineFg
            textElement($(lineIndex + 1), lineNumCfg)
        if line.len == 0: textElement(" ", cfg)
        for token in highlightLine(line, mode):
          var tc = cfg
          tc.color = token.kind.tokenColor
          textElement(line[token.start ..< token.stop], tc)
        let lo = max(start, min(s.caret, s.anchor))
        let hi = min(stop, max(s.caret, s.anchor))
        if hi > lo:
          let x0 = measureTextCached(currentContext(), line[0 ..< lo - start], cfg).unwrapped.width
          let x1 = measureTextCached(currentContext(), line[0 ..< hi - start], cfg).unwrapped.width
          let fill = activeTheme.palette.selectedBg
          item localId("rope.selection", lineId.id), col(width = fixedPx(max(x1 - x0, 1.0'f32)), height = fixedPx(pitch))
              .bg(Color(r: fill.r, g: fill.g, b: fill.b, a: 120))
              .floating(attachElementId, offset = vec2(x0 + gutterW, 0),
                parentId = lineId.id, zIndex = 49,
                points = AttachPoints(element: pointLeftTop, parent: pointLeftTop),
                capture = passThroughPointer):
            discard
        if focused(id) and not opts.blocked and s.caret >= start and s.caret <= stop:
          let geom = caretGeom(line, s.caret - start, cfg, 1000000.0)
          if geom.found:
            item localId("rope.caret", id.id), col(width = fixedPx(2), height = fixedPx(pitch))
                .bg(activeTheme.palette.textColor)
                .floating(attachElementId, offset = vec2(geom.x + gutterW, 0),
                  parentId = lineId.id, zIndex = 50,
                  points = AttachPoints(element: pointLeftTop, parent: pointLeftTop),
                  capture = passThroughPointer):
              discard
      if not opts.blocked:
        let box = elementData(lineId)
        if box.found and (clickedIn(lineId) or (focused(id) and pressing(id))):
          let pointer = currentContext().pointerData().position
          if clickedIn(lineId) or (pointer.y >= box.box.y and pointer.y < box.box.y + pitch):
            let pos = start + hitTest(line, cfg, box.box,
              pointer.x - box.box.x - gutterW, pointer.y - box.box.y)
            s.caret = pos
            if clickedIn(lineId):
              s.anchor = pos
              if doubleClick():
                while s.anchor > start and content.byteAt(content.previous(s.anchor)).word:
                  s.anchor = content.previous(s.anchor)
                while s.caret < stop and content.byteAt(s.caret).word:
                  s.caret = content.following(s.caret)
    if lastLine < s.starts.high:
      item localId("rope.bottom", id.id), col(width = fixedPx(1), height = fixedPx(float32(s.starts.high - lastLine) * pitch)):
        discard
    scrollbar(localId("rope.bar", id.id), id)
  result = content != before
