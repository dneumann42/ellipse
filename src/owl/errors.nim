import std/strutils


type
  SourceFile* = object
    name*: string
    text*: string
    internal*: bool

  Loc* = object
    at*: int32
    len*: int32

  Place* = object
    src*: ref SourceFile
    loc*: Loc

  ErrorKind* = enum
    ReadError
    CompileError
    RuntimeError

  TraceFrame* = object
    name*: string
    place*: Place

  OwlError* = object
    kind*: ErrorKind
    message*: string
    place*: Place
    trace*: seq[TraceFrame]
    sealed*: bool

const MaxTrace* = 12

func owlError*(kind: ErrorKind, message: string, at: Place = Place(src: nil,
    loc: Loc(at: 0, len: 0))): OwlError =
  OwlError(kind: kind, message: message, place: at, trace: @[], sealed: false)

proc newSource*(name, text: string, internal: bool = false): ref SourceFile =
  (ref SourceFile)(name: name, text: text, internal: internal)

func loc*(at, stop: int): Loc =
  Loc(at: int32(at), len: int32(max(stop - at, 0)))

func stop*(l: Loc): int = int(l.at) + int(l.len)

func span*(a, b: Loc): Loc =
  loc(min(int(a.at), int(b.at)), max(a.stop, b.stop))

func isKnown*(p: Place): bool = p.src != nil

func noPlace*(): Place = Place(src: nil, loc: Loc(at: 0, len: 0))

func place*(src: ref SourceFile, l: Loc): Place = Place(src: src, loc: l)

func kindTitle*(k: ErrorKind): string =
  case k
  of ReadError: "read error"
  of CompileError: "compile error"
  of RuntimeError: "error"

proc charCount(text: string, a, b: int): int =
  result = 0
  for i in a ..< b:
    if ord(text[i]) < 0x80 or ord(text[i]) >= 0xC0:
      inc result

proc lineCol*(text: string, at: int): (int, int) =
  var line = 1
  var lineStart = 0
  let stopAt = min(at, text.len)
  for i in 0 ..< stopAt:
    if text[i] == '\n':
      inc line
      lineStart = i + 1
  result = (line, charCount(text, lineStart, stopAt) + 1)

proc placeText*(p: Place): string =
  result = ""
  let src = p.src
  if src != nil:
    let (line, col) = lineCol(src.text, int(p.loc.at))
    result = src.name & ":" & $line & ":" & $col

proc sourceLines(text: string): seq[string] =
  result = text.split('\n')
  for i in 0 ..< result.len:
    if result[i].endsWith("\r"):
      result[i].setLen(result[i].len - 1)
    result[i] = result[i].replace('\t', ' ')

type Paint = object
  on: bool

func paint(p: Paint, code, s: string): string =
  if p.on and s.len > 0: "\e[" & code & "m" & s & "\e[0m" else: s

proc renderError*(e: OwlError, color: bool = false): string =
  if e.place.src == nil and e.message.startsWith("╭─"):
    return e.message
  let p = Paint(on: color)
  let bar = p.paint("31", "│")
  result = p.paint("31", "╭─ ") & p.paint("1;31", kindTitle(e.kind) & ":") & " " &
    p.paint("1", e.message.replace("\n", "\n" & bar & "  "))
  let src = e.place.src
  if src != nil:
    let at = int(e.place.loc.at)
    let (line, col) = lineCol(src.text, at)
    result.add "\n" & bar & "  " & p.paint("2", "at ") & p.paint("36", placeText(e.place))
    let lines = sourceLines(src.text)
    if line - 1 < lines.len:
      var first = max(line - 2, 1)
      while first < line and lines[first - 1].strip.len == 0:
        inc first
      let last = min(line + 1, lines.len)
      let gutter = len($last)
      result.add "\n" & bar
      for n in first .. last:
        let num = repeat(' ', gutter - len($n)) & $n
        let text = lines[n - 1]
        if n == last and n != line and text.strip.len == 0:
          break
        let shown = if n == line: p.paint("1", text) else: p.paint("2", text)
        result.add "\n" & bar & "  " & p.paint("34", num & " │ ") & shown
        if n == line:
          let lineChars = charCount(text, 0, text.len)
          let startCol = min(col - 1, lineChars)
          var width = 1
          if e.place.loc.len > 0:
            let stopAt = min(e.place.loc.stop, src.text.len)
            var lineEnd = at
            while lineEnd < src.text.len and src.text[lineEnd] != '\n':
              inc lineEnd
            let endAt = min(stopAt, lineEnd)
            width = max(charCount(src.text, at, max(endAt, at)), 1)
            if stopAt > lineEnd:
              width = max(lineChars - startCol, 1)
          result.add "\n" & bar & "  " & p.paint("34", repeat(' ', gutter) & " │ ") &
            repeat(' ', startCol) & p.paint("1;31", repeat('^', width))
  let inLibrary = src != nil and src.internal
  var gap = false
  for i in 0 ..< e.trace.len:
    let f = e.trace[i]
    let fsrc = f.place.src
    if fsrc != nil and fsrc.internal and not inLibrary:
      continue
    let where = placeText(f.place)
    if where.len > 0:
      if not gap:
        result.add "\n" & bar
        gap = true
      let what = if f.name.len > 0: "in " & f.name & ", called at " else: "called at "
      result.add "\n" & bar & "  " & p.paint("2", what) & p.paint("36", where)
  result.add "\n" & p.paint("31", "╰─")
