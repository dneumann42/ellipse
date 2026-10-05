## Duck's document: the text, its file, its line-ending style, its title.
##
## Notepad owns exactly one document per window, so this state is a module
## singleton -- but every mutation still flows through the immediate-mode
## round trip: the `editor` widget hands edited text back, `noteEdited` /
## `markSaved` / `openPath` keep the file-level truth beside it.
##
## Line endings follow the Windows app being cloned: a fresh document saves
## CRLF, an opened one keeps its own style (CR and CRLF all fold to `\n`
## in the editor's buffer and are re-expanded on save). UTF-8 BOMs are
## stripped on read; files are written as plain UTF-8.

import std/[syncio, strutils]

import ellipse/platform/platform

type
  EolKind* = enum eolCRLF, eolLF
  Doc* = object
    text*: string        ## the buffer, LF-normalised
    path*: string        ## absolute path, "" = untitled
    eol*: EolKind        ## how this document reads and will be written
    dirty*: bool         ## edited since the last save (or last new/open)
    created*: bool       ## any save/load cycle completed at all

var document* = Doc(eol: eolCRLF)

proc nameOf*(path: string): string =
  ## The basename Notepad would show in the title bar.
  if path.len == 0:
    return "Untitled"
  var i = path.len
  while i > 0 and path[i - 1] != '/' and path[i - 1] != '\\':
    dec i
  result = substr(path, i, path.len - 1)

proc dirOf*(path: string): string =
  ## Everything up to and including the last separator, "" when there is
  ## none (the listing then lives in the process's cwd).
  result = ""
  var i = path.len
  while i > 0 and path[i - 1] != '/' and path[i - 1] != '\\':
    dec i
  if i > 0:
    result = substr(path, 0, i - 1)

proc eolTag*(e: EolKind): string =
  if e == eolCRLF: "Windows (CRLF)" else: "Unix (LF)"

proc newDoc*() =
  document = Doc(eol: eolCRLF)

proc normalize*(raw: string): string =
  ## Fold CR and CRLF line endings to the LF the edit engine navigates on,
  ## and drop NULs the way a text-mode editor does.
  result = ""
  var i = 0
  while i < raw.len:
    let c = raw[i]
    if c == '\r':
      result.add '\n'
      if i + 1 < raw.len and raw[i + 1] == '\n':
        inc i
    elif c != '\0':
      result.add c
    inc i

proc stripBom*(s: var string) =
  if s.len >= 3 and s[0] == 0xEF.char and s[1] == 0xBB.char and
      s[2] == 0xBF.char:
    s = substr(s, 3, s.len - 1)

proc openPath*(path: string): tuple[ok: bool, msg: string] =
  var raw = ""
  try:
    raw = readFile(path)
  except:
    return (false, "Cannot open this file -- it may not exist or is locked: " & path)
  var text = normalize(raw)
  stripBom(text)
  document.text = text
  document.path = path
  document.eol = if "\r\n" in raw: eolCRLF else: eolLF
  document.dirty = false
  document.created = true
  return (true, "")

proc expandEol(text: string, e: EolKind): string =
  if e == eolLF:
    return text
  result = ""
  for c in text:
    if c == '\n':
      result.add "\r\n"
    else:
      result.add c

proc savePath*(path: string): tuple[ok: bool, msg: string] =
  ## Write the buffer with the document's line endings. The first save of
  ## a new document adopts CRLF -- the Windows default this clone keeps.
  let outp = expandEol(document.text, document.eol)
  var wrote = false
  try:
    writeFile(path, outp)
    wrote = true
  except:
    wrote = false
  if not wrote:
    return (false, "Cannot save here -- check the path and permissions: " & path)
  document.path = path
  document.dirty = false
  document.created = true
  (true, "")

proc noteEdited*() =
  document.dirty = true

proc title*(): string =
  (if document.dirty: "*" else: "") & nameOf(document.path) & " - Duck"

proc syncTitle*() =
  setWindowTitle(title())
