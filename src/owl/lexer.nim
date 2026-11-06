import std/[strutils, unicode]

type
  TokenKind* = enum Word, Str, Interp, Open, Close, Eq, Colon, Dot

  Token* = object
    kind*: TokenKind
    text*: string
    at*: int32
    len*: int32
    pieces*: seq[Piece]

  Piece* = object
    isExpr*: bool
    text*: string
    toks*: seq[Token]
    at*: int32
    len*: int32

  Line* = object
    num*: int
    indent*: int
    toks*: seq[Token]

  Tokenizer* = object
    err*: string
    line*: int
    errAt*: int

const
  Delimiters = {' ', '\t', '\r', '(', ')', ';', ':', '=', '"'}
  Digits = {'0' .. '9'}

func indentOf*(text: string): int =
  result = 0
  while result < text.len and text[result] in {' ', '\t'}:
    inc result

func numberDot(text: string, at, stop: int): bool =
  ## Whether the '.' at `at` is a decimal point (`1.5`, `1.`) rather than
  ## the start of a `.key` access.
  text[at - 1] in Digits and (at + 1 >= stop or text[at + 1] in Digits + Delimiters)

proc fail(t: var Tokenizer, msg: string, at: int) =
  if t.err.len == 0:
    t.err = msg
    t.errAt = at
  raise newException(ValueError, msg)

func tok(kind: TokenKind, at: int, len: int = 1): Token =
  Token(kind: kind, text: "", at: int32(at), len: int32(len))

proc tokenizeRange(t: var Tokenizer, text: string, start, stop: int): seq[Token] {.gcsafe.}

proc skipString(t: var Tokenizer, text: string, open, stop: int): int {.gcsafe.}

proc interpolationEnd(t: var Tokenizer, text: string, start, stop: int): int {.gcsafe.} =
  var depth = 1
  var k = start
  while k < stop:
    case text[k]
    of '(':
      inc depth
    of ')':
      dec depth
      if depth == 0:
        return k
    of '"':
      k = t.skipString(text, k, stop)
      if k < 0:
        return -1
    else:
      discard
    inc k
  -1

proc skipString(t: var Tokenizer, text: string, open, stop: int): int {.gcsafe.} =
  var j = open + 1
  while j < stop:
    if text[j] == '"':
      return j
    if text[j] == '\\' and j + 1 < stop:
      if text[j + 1] == '(':
        let close = t.interpolationEnd(text, j + 2, stop)
        if close < 0:
          return -1
        j = close + 1
      else:
        j += 2
      continue
    inc j
  -1

proc readString(t: var Tokenizer, text: string, open, stop: int): (Token, int) {.gcsafe.} =
  var j = open + 1
  var closed = false
  var value = ""
  var pieces: seq[Piece]
  var pieceAt = j
  while j < stop:
    let c = text[j]
    if c == '"':
      closed = true
      break
    if c == '\\':
      if j + 1 >= stop:
        break
      let e = text[j + 1]
      case e
      of '"': value.add '"'
      of '\\': value.add '\\'
      of 'n': value.add '\n'
      of 't': value.add '\t'
      of 'r': value.add '\r'
      of '0': value.add '\0'
      of 'e': value.add '\e'
      of '(':
        if value.len > 0:
          pieces.add Piece(text: value, at: int32(pieceAt), len: int32(j - pieceAt))
          value = ""
        let close = t.interpolationEnd(text, j + 2, stop)
        if close < 0:
          t.fail("unterminated \\( in a string: it needs a closing )", j)
        let toks = t.tokenizeRange(text, j + 2, close)
        if toks.len == 0:
          t.fail("\\() needs an expression inside", j)
        pieces.add Piece(isExpr: true, toks: toks, at: int32(j), len: int32(close + 1 - j))
        j = close + 1
        pieceAt = j
        continue
      of 'u':
        if j + 2 >= stop or text[j + 2] != '{':
          t.fail("\\u needs a hex code in braces, as in \\u{e9}", j)
        var k = j + 3
        while k < stop and text[k] in HexDigits:
          inc k
        if k >= stop or text[k] != '}' or k == j + 3 or k - (j + 3) > 6:
          t.fail("\\u needs one to six hex digits in braces, as in \\u{e9}", j)
        let code = parseHexInt(text[j + 3 ..< k])
        if code > 0x10FFFF or code in 0xD800 .. 0xDFFF:
          t.fail("\\u{" & text[j + 3 ..< k] & "} is not a unicode character", j)
        value.add $Rune(code)
        j = k + 1
        continue
      else:
        t.fail("unknown escape \\" & e & " in a string", j)
      j += 2
      continue
    value.add c
    inc j
  if not closed:
    t.fail("unterminated string", open)
  let whole = int32(j + 1 - open)
  if pieces.len == 0:
    return (Token(kind: Str, text: value, at: int32(open), len: whole), j)
  if value.len > 0:
    pieces.add Piece(text: value, at: int32(pieceAt), len: int32(j - pieceAt))
  (Token(kind: Interp, pieces: pieces, at: int32(open), len: whole), j)

proc tokenizeRange(t: var Tokenizer, text: string, start, stop: int): seq[Token] {.gcsafe.} =
  result = newSeqOfCap[Token](min(stop - start, 16))
  var i = start
  while i < stop:
    case text[i]
    of ' ', '\t', '\r':
      inc i
    of '(':
      result.add tok(Open, i)
      inc i
    of ')':
      result.add tok(Close, i)
      inc i
    of ':':
      result.add tok(Colon, i)
      inc i
    of '=':
      result.add tok(Eq, i)
      inc i
    of ';':
      break
    of '"':
      let (token, close) = t.readString(text, i, stop)
      result.add token
      i = close + 1
    of '.':
      result.add tok(Dot, i)
      inc i
    else:
      var j = i + 1
      var dotted = false
      while j < stop and text[j] notin Delimiters:
        if text[j] == '.':
          if dotted or not numberDot(text, j, stop):
            break
          dotted = true
        inc j
      result.add Token(kind: Word, text: text[i ..< j], at: int32(i), len: int32(j - i))
      i = j

proc tokenize*(t: var Tokenizer, text: string): seq[Token] =
  tokenizeRange(t, text, 0, text.len)

func parenDelta(toks: seq[Token]): int =
  result = 0
  for tk in toks:
    case tk.kind
    of Open: inc result
    of Close: dec result
    else: discard

proc scanLines*(t: var Tokenizer, text: string): seq[Line] =
  result = newSeqOfCap[Line](text.len div 24 + 1)
  var num = 0
  var start = 0
  var open = 0
  while start <= text.len:
    var stop = start
    while stop < text.len and text[stop] != '\n':
      inc stop
    inc num
    var first = start
    while first < stop and text[first] in Whitespace:
      inc first
    if first < stop and text[first] != ';':
      var indent = 0
      while start + indent < stop and text[start + indent] in {' ', '\t'}:
        inc indent
      t.line = num
      let toks = tokenizeRange(t, text, start, stop)
      if open == 0:
        result.add Line(num: num, indent: indent, toks: toks)
      else:
        for tk in toks:
          result[^1].toks.add tk
      open += parenDelta(toks)
      if open < 0:
        open = 0
    start = stop + 1
