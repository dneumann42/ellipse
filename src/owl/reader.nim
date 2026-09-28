import std/[strutils, result]
import owl/objects

type
  TokKind = enum tkWord, tkOpen, tkClose, tkEq, tkColon

  Token = object
    kind: TokKind
    text: string

  Line = object
    num: int
    indent: int
    toks: seq[Token]

  ItemKind = enum itObject, itEq, itColon
  Item = object
    case kind: ItemKind
    of itObject: value: Object
    of itEq, itColon: discard

  Parser = object
    lines: seq[Line]
    pos: int
    num: int
    err: string

const
  Delimiters = {' ', '\t', '(', ')', ';', ':', '='}

proc fail(p: var Parser, msg: string) =
  if p.err.len == 0:
    p.err = "line " & $p.num & ": " & msg

func indentOf(text: string): int =
  result = 0
  while result < text.len and text[result] in {' ', '\t'}:
    inc result

func tokenize(text: string): seq[Token] =
  result = @[]
  var i = 0
  while i < text.len:
    case text[i]
    of ' ', '\t':
      inc i
    of '(':
      result.add Token(kind: tkOpen)
      inc i
    of ')':
      result.add Token(kind: tkClose)
      inc i
    of ':':
      result.add Token(kind: tkColon)
      inc i
    of '=':
      result.add Token(kind: tkEq)
      inc i
    of ';':
      break
    else:
      var j = i + 1
      while j < text.len and text[j] notin Delimiters:
        inc j
      result.add Token(kind: tkWord, text: text[i ..< j])
      i = j

func splitLines(text: string): seq[Line] =
  result = @[]
  var num = 0
  for raw in split(text, '\n'):
    inc num
    let content = strip(raw)
    if content.len == 0 or content[0] == ';':
      continue
    result.add Line(num: num, indent: indentOf(raw), toks: tokenize(raw))

func tryNumber(text: string): (bool, float64) =
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

func atom(text: string): Object =
  let (isNum, value) = tryNumber(text)
  if isNum:
    result = number(value)
  else:
    result = symbol(text)

proc assemble(p: var Parser, items: seq[Item]): Object =
  result = nothing()
  var eqAt = -1
  for i in 0 ..< items.len:
    case items[i].kind
    of itObject:
      discard
    of itEq:
      if eqAt >= 0:
        p.fail("repeated '='")
        return
      eqAt = i
    of itColon:
      p.fail("':' must end the line")
      return

  var before, after: seq[Object]
  for i in 0 ..< items.len:
    if i != eqAt and items[i].kind == itObject:
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
      pair(before[0], list(after))
  elif before.len == 0:
    p.fail("empty expression")
  elif before.len == 1:
    result = before[0]
  else:
    result = list(before)

proc parseItems(p: var Parser, toks: seq[Token], i: var int): seq[Item] =
  result = @[]
  while i < toks.len:
    case toks[i].kind
    of tkWord:
      result.add Item(kind: itObject, value: atom(toks[i].text))
      inc i
    of tkEq:
      result.add Item(kind: itEq)
      inc i
    of tkColon:
      result.add Item(kind: itColon)
      inc i
    of tkOpen:
      inc i
      let inner = p.parseItems(toks, i)
      if p.err.len > 0:
        return
      if i >= toks.len or toks[i].kind != tkClose:
        p.fail("expected ')'")
        return
      inc i
      result.add Item(kind: itObject, value: p.assemble(inner))
    of tkClose:
      break

proc parseExprs(p: var Parser, base: int): seq[Object] =
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

    var ephemeral = false
    if p.err.len == 0 and items.len > 0 and items[^1].kind == itColon:
      items.setLen(items.len - 1)
      ephemeral = true

    if ephemeral and p.pos < p.lines.len and p.lines[p.pos].indent > ln.indent:
      for form in p.parseExprs(p.lines[p.pos].indent):
        items.add Item(kind: itObject, value: form)

    if p.err.len == 0:
      result.add p.assemble(items)

proc parseOwl*(source: string): Result[seq[Object], string] =
  var p = Parser(lines: splitLines(source))
  let forms = p.parseExprs(0)
  if p.err.len > 0:
    result = err(p.err)
  else:
    result = ok(forms)
