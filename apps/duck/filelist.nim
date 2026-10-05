## Directory listing for Duck's open / save dialogs.
##
## SDL has no file picker, so the dialogs are built from the widget set:
## a scrollable list of the current directory, a name field and the usual
## buttons. This module owns only the listing half of that: enumerate a
## directory (folders first, then files, case-insensitive), and the small
## path plumbing that walks it.
##
## Every std/os entry point here is `.raises`-marked, so every call rides
## inside a try/except -- failures simply yield empty lists and stay quiet.

import std/[os, strutils]
import std/dirs except getCurrentDir
import std/paths

type
  FEntry* = object
    name*: string
    isDir*: bool

proc cwdString*(): string =
  try:
    result = os.getCurrentDir()
  except:
    result = "/"

proc homeString*(): string =
  try:
    result = os.getHomeDir()
  except:
    result = cwdString()

proc normDir*(dir: string): string =
  ## Collapse trailing separators (except the bare root) and empty input.
  if dir.len == 0:
    return "/"
  result = dir
  while result.len > 1 and (result[^1] == '/' or result[^1] == '\\'):
    result = substr(result, 0, result.len - 2)

proc isRoot*(dir: string): bool =
  normDir(dir).len <= 1

proc parentOf*(dir: string): string =
  let d = normDir(dir)
  if d.len <= 1:
    return d
  var i = d.len - 1
  while i > 0 and d[i - 1] != '/' and d[i - 1] != '\\':
    dec i
  if i <= 1:
    return "/"
  result = substr(d, 0, i - 2)

proc joinDir*(dir, name: string): string =
  let d = normDir(dir)
  if d.len == 1 and (d[0] == '/' or d[0] == '\\'):
    result = d & name
  else:
    result = d & "/" & name

func lowerName(s: string): string =
  result = ""
  for c in s:
    if c >= 'A' and c <= 'Z':
      result.add chr(ord(c) + 32)
    else:
      result.add c

proc listDir*(dir: string): seq[FEntry] =
  ## Names inside `dir`: directories first, then files, each sorted
  ## case-insensitively. Empty on any failure.
  result = @[]
  try:
    for kind, p in walkDir(path dir):
      var nm = $p
      # walkDir yields "<dir>/<name>"; keep the tail only.
      var i = nm.len
      while i > 0 and nm[i - 1] != '/' and nm[i - 1] != '\\':
        dec i
      nm = substr(nm, i, nm.len - 1)
      if nm == "." or nm == "..":
        continue
      # Notepad's picker hides dot-files by default -- so do we.
      if nm.len > 0 and nm[0] == '.':
        continue
      result.add FEntry(name: nm, isDir: kind == pcDir)
  except:
    discard
  # insertion sort by (isDir desc, name asc)
  var i = 1
  while i < result.len:
    let e = result[i]
    var j = i - 1
    while j >= 0:
      let k = result[j]
      let swap =
        if k.isDir != e.isDir: not e.isDir
        else: lowerName(k.name) > lowerName(e.name)
      if not swap:
        break
      result[j + 1] = k
      dec j
    result[j + 1] = e
    inc i

proc existsAny*(path: string): bool =
  fileExists(path) or dirExists(path)
