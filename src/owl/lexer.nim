import std/strutils

type
  TokenKind* = enum Word, Str, Open, Close, Eq, Colon, Dot

  Token* = object
    kind*: TokenKind
    text*: string

  Line* = object
    num*: int
    indent*: int
    toks*: seq[Token]

  Tokenizer* = object
    err*: string
    line*: int

const
  # '\r' counts as space so files with CRLF line ends read like LF ones.
  Delimiters = {' ', '\t', '\r', '(', ')', ';', ':', '=', '"'}
  Digits = {'0' .. '9'}

func indentOf*(text: string): int =
  result = 0
  while result < text.len and text[result] in {' ', '\t'}:
    inc result

func numberDot(text: string, at, stop: int): bool =
  if text[at - 1] notin Digits:
    return false
  if at + 1 >= stop:
    return true
  return text[at + 1] in Digits or text[at + 1] in Delimiters

proc fail(t: var Tokenizer, msg: string) {.raises.} =
  if t.err.len == 0:
    t.err = msg
  raise ValueError

# The tokens of text[start ..< stop], one line of a source.
proc tokenizeRange(t: var Tokenizer, text: string, start, stop: int): seq[Token] {.raises.} =
  result = newSeqOfCap[Token](min(stop - start, 16))
  var i = start
  while i < stop:
    case text[i]
    of ' ', '\t', '\r':
      inc i
    of '(':
      result.add Token(kind: Open)
      inc i
    of ')':
      result.add Token(kind: Close)
      inc i
    of ':':
      result.add Token(kind: Colon)
      inc i
    of '=':
      result.add Token(kind: Eq)
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
        t.fail("unterminated string")
      result.add Token(kind: Str, text: text[i + 1 ..< j])
      i = j + 1
    of '.':
      result.add Token(kind: Dot)
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
      result.add Token(kind: Word, text: text[i ..< j])
      i = j

proc tokenize*(t: var Tokenizer, text: string): seq[Token] {.raises.} =
  tokenizeRange(t, text, 0, text.len)

func parenDelta(toks: seq[Token]): int =
  result = 0
  for tk in toks:
    case tk.kind
    of Open: inc result
    of Close: dec result
    else: discard

proc scanLines*(t: var Tokenizer, text: string): seq[Line] {.raises.} =
  # Each logical line of text, skipping blank lines and comment lines, read in
  # place (no line is copied out of text). A line whose parentheses are still
  # open at its end continues onto the following lines: their tokens join it
  # whatever their indentation, until the group closes. So both
  #
  #   (hello foo
  #          bar)     (hello
  #                     bar)
  #
  # read as one call. A group left open to the end of the source stays as a
  # line of its own, so the reader reports the missing ')'.
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
