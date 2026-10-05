## Duck's search: the byte scanner behind Find, Replace and their counts.
##
## ASCII case-insensitive matching keeps the scan simple and safe for
## UTF-8 text -- upper-casing only touches bytes >= 'a', so multi-byte
## sequences pass through untouched and a match never splits a codepoint:
## `findFrom` steps byte-by-byte and the engine's caret always lands on a
## byte index that is a codepoint start because the query itself was typed
## at codepoint boundaries.

import std/[strutils]

proc matchesAt*(text: string, at: int, q: string, caseless: bool): bool =
  if at + q.len > text.len:
    return false
  for k in 0 ..< q.len:
    var a = text[at + k]
    var b = q[k]
    if caseless:
      if a >= 'A' and a <= 'Z': a = chr(ord(a) + 32)
      if b >= 'A' and b <= 'Z': b = chr(ord(b) + 32)
    if a != b:
      return false
  return true

proc findFrom*(text: string, q: string, fromIdx: int,
               caseless: bool, wrap = true): tuple[lo, hi: int, found: bool] =
  ## First occurrence of `q` at or after `fromIdx`; with `wrap` the search
  ## restarts at the top when none is left ahead (Notepad's default).
  if q.len == 0 or text.len == 0:
    return (-1, -1, false)
  var i = max(min(fromIdx, text.len - q.len), 0)
  while i <= text.len - q.len:
    if matchesAt(text, i, q, caseless):
      return (i, i + q.len, true)
    inc i
  if not wrap:
    return (-1, -1, false)
  # behind the start: scan 0 ..< fromIdx once
  var j = 0
  let stop = min(fromIdx, text.len - q.len)
  while j <= stop:
    if j < i and matchesAt(text, j, q, caseless):
      return (j, j + q.len, true)
    inc j
  return (-1, -1, false)

proc findBack*(text: string, q: string, before: int,
               caseless: bool, wrap = true): tuple[lo, hi: int, found: bool] =
  ## Last occurrence ending at or before `before`; with `wrap` the search
  ## continues at the bottom of the document.
  if q.len == 0 or text.len == 0:
    return (-1, -1, false)
  var i = min(before, text.len) - q.len
  var best = -1
  while i >= 0:
    if matchesAt(text, i, q, caseless):
      best = i
      break
    dec i
  if best < 0 and wrap:
    i = text.len - q.len
    while i >= 0 and i > min(before, text.len) - q.len:
      if matchesAt(text, i, q, caseless):
        best = i
        break
      dec i
  if best < 0:
    return (-1, -1, false)
  return (best, best + q.len, true)

proc replaceAll*(text: string, q, with: string, caseless: bool,
                 outText: var string, count: var int) =
  ## Every occurrence of `q` swapped for `with`, in one pass.
  outText = ""
  count = 0
  if q.len == 0:
    outText = text
    return
  var i = 0
  while i < text.len:
    if i + q.len <= text.len and matchesAt(text, i, q, caseless):
      outText.add with
      inc count
      inc i, q.len
    else:
      outText.add text[i]
      inc i

proc countMatches*(text: string, q: string, caseless: bool): int =
  if q.len == 0:
    return 0
  var i = 0
  result = 0
  while i <= text.len - q.len:
    if matchesAt(text, i, q, caseless):
      inc result
      i += q.len
    else:
      inc i

func lineCount*(text: string): int =
  ## Logical lines: what a status bar shows as "Lines selected".
  result = 1
  for c in text:
    if c == '\n':
      inc result
