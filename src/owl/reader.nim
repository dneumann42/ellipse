import std/result
import owl/[lexer, objects]

type
  ItemKind = enum Object, Eq, Colon, Dot

  Item = object
    case kind: ItemKind
    of Object: value: objects.Object
    of Eq, Colon, Dot: discard

  Parser = object
    lines: seq[Line]
    pos: int
    num: int
    err: string

proc fail(p: var Parser, msg: string) =
  if p.err.len == 0:
    p.err = "line " & $p.num & ": " & msg

func indexCall(target, key: objects.Object): objects.Object =
  list(@[symbol("index"), target, key])

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
  let (isNum, value) = tryNumber(text)
  if isNum:
    result = number(value)
  else:
    result = symbol(text)

proc assemble(p: var Parser, items: seq[Item], bodyAt: int = -1): objects.Object =
  result = nothing()
  var eqAt = -1
  for i in 0 ..< items.len:
    case items[i].kind
    of Object:
      discard
    of Eq:
      if eqAt >= 0:
        p.fail("repeated '='")
        return
      eqAt = i
    of Colon:
      p.fail("':' must end the line")
      return
    of Dot:
      p.fail("'.' needs a value before it")
      return

  var before, after: seq[objects.Object]
  for i in 0 ..< items.len:
    if i != eqAt and items[i].kind == Object:
      if eqAt >= 0 and i > eqAt:
        after.add items[i].value
      else:
        before.add items[i].value

  if eqAt >= 0:
    if before.len != 1 or toSymbol(before[0]) == "":
      p.fail("a binding needs a single name on the left of '='")
      return
    if after.len == 0:
      p.fail("missing value after '='")
      return
    result = if after.len == 1:
      pair(before[0], after[0])
    else:
      var inner = list(after)
      if bodyAt > eqAt:
        inner.setBodyStart(bodyAt - eqAt - 1)
      pair(before[0], inner)
  elif before.len == 0:
    p.fail("empty expression")
  elif before.len == 1:
    result = before[0]
  else:
    result = list(before)
    if bodyAt >= 0:
      result.setBodyStart(bodyAt)

proc foldDots(p: var Parser, items: seq[Item]): seq[Item] =
  result = @[]
  var i = 0
  while i < items.len:
    if items[i].kind == Dot:
      if result.len == 0 or result[^1].kind != Object:
        p.fail("'.' needs a value before it")
        return
      if i + 1 >= items.len or items[i + 1].kind != Object:
        p.fail("'.' needs a key after it")
        return
      let target = result[^1].value
      let key = items[i + 1].value
      result.setLen(result.len - 1)
      result.add Item(kind: Object, value: indexCall(target, key))
      i += 2
    else:
      result.add items[i]
      inc i

proc parseItems(p: var Parser, toks: seq[Token], i: var int): seq[Item] =
  result = @[]
  while i < toks.len:
    case toks[i].kind
    of Word:
      result.add Item(kind: Object, value: atom(toks[i].text))
      inc i
    of Str:
      result.add Item(kind: Object, value: str(toks[i].text))
      inc i
    of Eq:
      result.add Item(kind: Eq)
      inc i
    of Colon:
      result.add Item(kind: Colon)
      inc i
    of Dot:
      result.add Item(kind: Dot)
      inc i
    of Open:
      inc i
      let inner = p.parseItems(toks, i)
      if p.err.len > 0:
        return
      if i >= toks.len or toks[i].kind != Close:
        p.fail("expected ')'")
        return
      inc i
      result.add Item(kind: Object, value: p.assemble(inner))
    of Close:
      break
  result = p.foldDots(result)

proc parseExprs(p: var Parser, base: int): seq[objects.Object] =
  result = @[]
  while p.pos < p.lines.len and p.err.len == 0:
    let ln = p.lines[p.pos]
    if ln.indent < base:
      break
    if ln.indent > base:
      p.num = ln.num
      p.fail("unexpected indentation")
      break
    inc p.pos
    p.num = ln.num

    var i = 0
    var items = p.parseItems(ln.toks, i)
    if p.err.len == 0 and i < ln.toks.len:
      p.fail("unexpected ')'")

    var bodyAt = -1
    if p.err.len == 0 and items.len > 0 and items[^1].kind == Colon:
      items.setLen(items.len - 1)
      bodyAt = items.len
      if p.pos < p.lines.len and p.lines[p.pos].indent > ln.indent:
        for form in p.parseExprs(p.lines[p.pos].indent):
          items.add Item(kind: Object, value: form)
      else:
        p.fail("missing block after ':'")

    if p.err.len == 0:
      result.add p.assemble(items, bodyAt)

proc parseOwl*(source: string): Result[seq[objects.Object], string] =
  var t = Tokenizer(err: "", line: 0)
  var lines: seq[Line] = @[]
  try:
    lines = scanLines(t, source)
  except:
    discard
  var p = Parser(lines: lines)
  if t.err.len > 0:
    p.num = if t.line > 0: t.line else: 1
    p.fail(t.err)
  let forms = p.parseExprs(0)
  if p.err.len > 0:
    result = err(p.err)
  else:
    result = ok(forms)
