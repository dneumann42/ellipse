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

func numberDot(text: string, at: int): bool =
  if text[at - 1] notin Digits:
    return false
  if at + 1 >= text.len:
    return true
  return text[at + 1] in Digits or text[at + 1] in Delimiters

proc fail(t: var Tokenizer, msg: string) {.raises.} =
  if t.err.len == 0:
    t.err = msg
  raise ValueError

proc tokenize*(t: var Tokenizer, text: string): seq[Token] {.raises.} =
  result = @[]
  var i = 0
  while i < text.len:
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
      while j < text.len:
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
      while j < text.len and text[j] notin Delimiters:
        if text[j] == '.':
          if dotted or not numberDot(text, j):
            break
          dotted = true
        inc j
      result.add Token(kind: Word, text: text[i ..< j])
      i = j

proc scanLines*(t: var Tokenizer, text: string): seq[Line] {.raises.} =
  result = @[]
  var num = 0
  for raw in split(text, '\n'):
    inc num
    let content = strip(raw)
    if content.len == 0 or content[0] == ';':
      continue
    t.line = num
    result.add Line(num: num, indent: indentOf(raw), toks: tokenize(t, raw))
