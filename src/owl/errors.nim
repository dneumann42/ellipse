import std/strutils

# Owl's one error report. Reading, loading (compile time) and running all
# fail the same way: an OwlError with a message and, when the failing code
# came from a source, the place it was written. renderError draws it as a
# window around the source lines, with an arrow under the place:
#
#   ╭─ error: unbound symbol: fo
#   │  at main.owl:12:6
#   │
#   │  11 │ fun bar x:
#   │  12 │     (fo x)
#   │     │      ^^
#   │  13 │ bar 1
#   │
#   │  in bar, called at main.owl:13:1
#   ╰─
#
# Places are kept in the boxes values already have (a list's items, a pair,
# a syntax, a command), never in the value itself, so an Object stays small.

type
  # A source text as read: the file (or a name like <repl>) and its text,
  # shared by every form read from it.
  SourceFile* = object
    name*: string
    text*: string
    # built into owl (its libraries, its command line): calls in it are
    # left out of the traces of errors in other code
    internal*: bool

  # A run of a source: byte offset and length.
  Loc* = object
    at*: int32
    len*: int32

  Place* = object
    src*: nil ref SourceFile
    loc*: Loc

  ErrorKind* = enum
    ReadError
    CompileError
    RuntimeError

  # A command call the error passed through on its way out.
  TraceFrame* = object
    name*: string
    place*: Place

  OwlError* = object
    kind*: ErrorKind
    message*: string
    place*: Place
    trace*: seq[TraceFrame]
    # Set where the error leaves the code it is about (run-file): the calls
    # further out, owl's own command line, are not part of its trace.
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

# The run from the start of a to the end of b.
func span*(a, b: Loc): Loc =
  loc(min(int(a.at), int(b.at)), max(a.stop, b.stop))

func isKnown*(p: Place): bool = p.src != nil

func noPlace*(): Place = Place(src: nil, loc: Loc(at: 0, len: 0))

func place*(src: nil ref SourceFile, l: Loc): Place = Place(src: src, loc: l)

func kindTitle*(k: ErrorKind): string =
  case k
  of ReadError: "read error"
  of CompileError: "compile error"
  of RuntimeError: "error"

proc charCount(text: string, a, b: int): int =
  # characters, not bytes: UTF-8 continuation bytes add nothing
  result = 0
  for i in a ..< b:
    if ord(text[i]) < 0x80 or ord(text[i]) >= 0xC0:
      inc result

# line and column (both from 1) of a byte offset
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
  ## file:line:col of a place, or "" when it is not known.
  result = ""
  let src = p.src
  if src != nil:
    let (line, col) = lineCol(src.text, int(p.loc.at))
    result = src.name & ":" & $line & ":" & $col

# The lines of text, without their line ends; lines[i] is line i + 1.
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
  ## The error as a window of text: its message, where it happened with the
  ## source lines around it and an arrow under the place, and the command
  ## calls it came through. color adds ANSI colors for a terminal.
  # A message that is already a window (an error passed on as text, from an
  # attached program) shows as it is.
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
          # the arrow: from the column to the end of the place, or of the
          # line when the place runs on to later lines
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
  # Calls in owl's own libraries say nothing about an error in other code.
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
