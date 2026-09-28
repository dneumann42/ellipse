import std/strutils

type
  TokenKind* = enum Word, Open, Close, Eq, Colon

  Token* = object
    kind*: TokenKind
    text*: string

  Line* = object
    num*: int
    indent*: int
    toks*: seq[Token]

const
  Delimiters = {' ', '\t', '(', ')', ';', ':', '='}

func indentOf*(text: string): int =
  result = 0
  while result < text.len and text[result] in {' ', '\t'}:
    inc result

func tokenize*(text: string): seq[Token] =
  result = @[]
  var i = 0
  while i < text.len:
    case text[i]
    of ' ', '\t':
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
    else:
      var j = i + 1
      while j < text.len and text[j] notin Delimiters:
        inc j
      result.add Token(kind: Word, text: text[i ..< j])
      i = j

func scanLines*(text: string): seq[Line] =
  result = @[]
  var num = 0
  for raw in split(text, '\n'):
    inc num
    let content = strip(raw)
    if content.len == 0 or content[0] == ';':
      continue
    result.add Line(num: num, indent: indentOf(raw), toks: tokenize(raw))
