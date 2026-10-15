import owl/[resultshim, lexer, objects, errors]
export resultshim

type
  ItemKind = enum Object, Eq, Colon, Dot

  Item = object
    dotted: bool
    loc: Loc
    case kind: ItemKind
    of Object: value: objects.Object
    of Eq, Colon, Dot: discard

  Parser = object
    pos: int
    num: int
    err: string
    src: ref SourceFile
    errLoc: Loc

proc fail(p: var Parser, msg: string, at: Loc) =
  if p.err.len == 0:
    p.err = msg
    p.errLoc = at

func indexCall(src: ref SourceFile, target, key: Item, dot: Loc): objects.Object =
  listAt(@[symbol("index"), target.value, key.value], src, span(target.loc, key.loc),
    @[dot, target.loc, key.loc])

func itemsLoc(items: seq[Item]): Loc =
  result = Loc(at: 0, len: 0)
  if items.len > 0:
    result = span(items[0].loc, items[^1].loc)

func tryNumber*(text: string): (bool, float64) =
  var i = 0
  var sign = 1.0
  if i < text.len and text[i] in {'+', '-'}:
    if text[i] == '-':
      sign = -1.0
    inc i
  var value = 0.0
  var digits = 0
  while i < text.len and text[i] in {'0'..'9'}:
    value = value * 10.0 + float64(ord(text[i]) - ord('0'))
    inc i
    inc digits
  var frac = 0.1
  var fracDigits = 0
  if i < text.len and text[i] == '.':
    inc i
    while i < text.len and text[i] in {'0'..'9'}:
      value += frac * float64(ord(text[i]) - ord('0'))
      frac *= 0.1
      inc i
      inc fracDigits
  if i != text.len or digits + fracDigits == 0:
    result = (false, 0.0)
  else:
    result = (true, sign * value)

func atom*(text: string): objects.Object =
  if text.len == 0 or text[0] notin {'0'..'9', '+', '-'}:
    return symbol(text)
  let (isNum, value) = tryNumber(text)
  if isNum:
    result = number(value)
  else:
    result = symbol(text)

proc assemble(p: var Parser, items: var seq[Item], whole: var Loc,
    bodyAt: int = -1): objects.Object =
  result = nothing()
  if whole.len == 0:
    whole = itemsLoc(items)
  var eqAt = -1
  var cmdAt = -1
  for i in 0 ..< items.len:
    case items[i].kind
    of Object:
      discard
    of Eq:
      if cmdAt < 0 and (i == 0 or i == eqAt + 1):
        cmdAt = i
      elif eqAt >= 0:
        p.fail("repeated '='", items[i].loc)
        return
      else:
        eqAt = i
    of Colon:
      p.fail("':' must end the line", items[i].loc)
      return
    of Dot:
      p.fail("'.' needs a value before it", items[i].loc)
      return

  var before = newSeqOfCap[objects.Object](items.len)
  var beforeLocs = newSeqOfCap[Loc](items.len)
  var after: seq[objects.Object] = @[]
  var afterLocs: seq[Loc] = @[]
  if eqAt >= 0:
    after = newSeqOfCap[objects.Object](items.len - eqAt)
    afterLocs = newSeqOfCap[Loc](items.len - eqAt)
  for i in 0 ..< items.len:
    var value: objects.Object
    var keep = false
    case items[i].kind
    of Object:
      value = move(items[i].value)
      keep = true
    of Eq:
      if i == cmdAt:
        value = symbol("=")
        keep = true
    of Colon, Dot:
      discard
    if keep:
      if eqAt >= 0 and i > eqAt:
        after.add value
        afterLocs.add items[i].loc
      else:
        before.add value
        beforeLocs.add items[i].loc

  if eqAt >= 0:
    if before.len != 1 or (toSymbol(before[0]) == "" and not isList(before[0])):
      let at = if beforeLocs.len > 0: span(beforeLocs[0], beforeLocs[^1]) else: items[eqAt].loc
      p.fail("a binding needs a name or a grouped call on the left of '='", at)
      return
    if after.len == 0:
      p.fail("missing value after '='", items[eqAt].loc)
      return
    result = if after.len == 1:
      pairAt(before[0], after[0], p.src, beforeLocs[0], afterLocs[0])
    else:
      let valLoc = span(afterLocs[0], afterLocs[^1])
      var inner = listAt(after, p.src, valLoc, afterLocs)
      if bodyAt > eqAt:
        inner.setBodyStart(bodyAt - eqAt - 1)
      pairAt(before[0], inner, p.src, beforeLocs[0], valLoc)
  elif before.len == 0:
    p.fail("empty expression", whole)
  elif before.len == 1:
    result = before[0]
  else:
    result = listAt(before, p.src, whole, beforeLocs)
    if bodyAt >= 0:
      result.setBodyStart(bodyAt)

proc foldDots(p: var Parser, items: seq[Item]): seq[Item] =
  result = @[]
  var i = 0
  while i < items.len:
    if items[i].kind == Dot:
      if result.len == 0 or result[^1].kind != Object:
        p.fail("'.' needs a value before it", items[i].loc)
        return
      if i + 1 >= items.len or items[i + 1].kind != Object:
        p.fail("'.' needs a key after it", items[i].loc)
        return
      let target = result[^1]
      let whole = span(target.loc, items[i + 1].loc)
      let value = indexCall(p.src, target, items[i + 1], items[i].loc)
      result.setLen(result.len - 1)
      result.add Item(kind: Object, value: value, dotted: true, loc: whole)
      i += 2
    else:
      result.add items[i]
      inc i

proc parseItems(p: var Parser, toks: seq[Token], i: var int): seq[Item] =
  result = newSeqOfCap[Item](toks.len - i)
  var dots = false
  while i < toks.len:
    let here = Loc(at: toks[i].at, len: toks[i].len)
    case toks[i].kind
    of Word:
      result.add Item(kind: Object, value: atom(toks[i].text), loc: here)
      inc i
    of Str:
      result.add Item(kind: Object, value: str(toks[i].text), loc: here)
      inc i
    of Eq:
      result.add Item(kind: Eq, loc: here)
      inc i
    of Colon:
      result.add Item(kind: Colon, loc: here)
      inc i
    of Dot:
      result.add Item(kind: Dot, loc: here)
      dots = true
      inc i
    of Open:
      inc i
      var inner = p.parseItems(toks, i)
      if p.err.len > 0:
        return
      if i >= toks.len or toks[i].kind != Close:
        p.fail("expected ')' to close this '('", here)
        return
      var group = span(here, Loc(at: toks[i].at, len: toks[i].len))
      inc i
      let innerLoc = itemsLoc(inner)
      var value = p.assemble(inner, group)
      if inner.len == 1 and inner[0].kind == Object and (isSymbol(value) or inner[0].dotted):
        value = listAt(@[value], p.src, group, @[innerLoc])
      result.add Item(kind: Object, value: value, loc: group)
    of Close:
      break
  if dots:
    result = p.foldDots(result)

func lineStart(line: Line): Loc =
  result = Loc(at: 0, len: 0)
  if line.toks.len > 0:
    result = Loc(at: line.toks[0].at, len: line.toks[0].len)

proc parseExprs(p: var Parser, lines: seq[Line], base: int,
    locs: var seq[Loc]): seq[objects.Object] =
  result = @[]
  while p.pos < lines.len and p.err.len == 0:
    let at = p.pos
    if lines[at].indent < base:
      break
    if lines[at].indent > base:
      p.num = lines[at].num
      p.fail("unexpected indentation", lineStart(lines[at]))
      break
    inc p.pos
    p.num = lines[at].num

    var i = 0
    var items = p.parseItems(lines[at].toks, i)
    if p.err.len == 0 and i < lines[at].toks.len:
      p.fail("unexpected ')'", Loc(at: lines[at].toks[i].at, len: 1))

    var bodyAt = -1
    if p.err.len == 0 and items.len > 0 and items[^1].kind == Colon:
      let colon = items[^1].loc
      items.setLen(items.len - 1)
      bodyAt = items.len
      if p.pos < lines.len and lines[p.pos].indent > lines[at].indent:
        var bodyLocs: seq[Loc] = @[]
        let forms = p.parseExprs(lines, lines[p.pos].indent, bodyLocs)
        for k in 0 ..< forms.len:
          items.add Item(kind: Object, value: forms[k], loc: bodyLocs[k])
      else:
        p.fail("missing block after ':'", colon)

    if p.err.len == 0:
      var whole = Loc(at: 0, len: 0)
      result.add p.assemble(items, whole, bodyAt)
      locs.add whole

proc readForms*(source: string, name: string,
    internal: bool = false): Result[seq[objects.Object], OwlError] =
  var t = Tokenizer(err: "", line: 0, errAt: 0)
  var lines: seq[Line] = @[]
  try:
    lines = scanLines(t, source)
  except:
    discard
  var p = Parser(pos: 0, num: 0, err: "", src: newSource(name, source, internal), errLoc: Loc(at: 0, len: 0))
  if t.err.len > 0:
    p.num = if t.line > 0: t.line else: 1
    p.fail(t.err, Loc(at: int32(t.errAt), len: 1))
  var locs: seq[Loc] = @[]
  let forms = p.parseExprs(lines, 0, locs)
  if p.err.len > 0:
    result = err[seq[objects.Object], OwlError](
      owlError(ReadError, p.err, place(p.src, p.errLoc)))
  else:
    result = ok[seq[objects.Object], OwlError](forms)

proc parseOwl*(source: string, name: string = "<input>"): Result[seq[objects.Object], string] =
  let r = readForms(source, name)
  if r.isOk:
    result = ok[seq[objects.Object], string](r.get(@[]))
  else:
    let e = r.error(owlError(ReadError, ""))
    let (line, col) = lineCol(source, int(e.place.loc.at))
    discard col
    result = err[seq[objects.Object], string]("line " & $line & ": " & e.message)
