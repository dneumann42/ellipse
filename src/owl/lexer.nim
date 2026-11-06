import std/strutils

type
  TokenKind* = enum Word, Str, Open, Close, Eq, Colon, Dot

  Token* = object
    kind*: TokenKind
    text*: string
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

proc fail(t: var Tokenizer, msg: string, at: int)  =
  if t.err.len == 0:
    t.err = msg
    t.errAt = at
  raise newException(ValueError, msg)

func tok(kind: TokenKind, at: int, len: int = 1): Token =
  Token(kind: kind, text: "", at: int32(at), len: int32(len))

proc tokenizeRange(t: var Tokenizer, text: string, start, stop: int): seq[Token]  =
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
      var j = i + 1
      var closed = false
      while j < stop:
        if text[j] == '"':
          closed = true
          break
        inc j
      if not closed:
        t.fail("unterminated string", i)
      result.add Token(kind: Str, text: text[i + 1 ..< j], at: int32(i), len: int32(j + 1 - i))
      i = j + 1
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

proc tokenize*(t: var Tokenizer, text: string): seq[Token]  =
  tokenizeRange(t, text, 0, text.len)

func parenDelta(toks: seq[Token]): int =
  result = 0
  for tk in toks:
    case tk.kind
    of Open: inc result
    of Close: dec result
    else: discard

proc scanLines*(t: var Tokenizer, text: string): seq[Line]  =
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
