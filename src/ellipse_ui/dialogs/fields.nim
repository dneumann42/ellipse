## `Fields`: the ordered string bag a dialog takes as arguments and hands
## back as its result, and the one-line wire form used to carry it across a
## process boundary. See `documentation/nim-tutorial.md` §13.1 (The Fields
## wire form).

import std/[strutils, parseutils]

type
  Fields* = object
    keys: seq[string]
    vals: seq[string]

proc len*(f: Fields): int = f.keys.len

proc find(f: Fields; key: string): int =
  var i = 0
  while i < f.keys.len:
    if f.keys[i] == key:
      return i
    inc i
  -1

proc has*(f: Fields; key: string): bool = f.find(key) >= 0

proc keyAt*(f: Fields; i: int): string = f.keys[i]
proc valueAt*(f: Fields; i: int): string = f.vals[i]

proc put*(f: var Fields; key, value: string) =
  ## Set `key`, replacing an earlier value in place (order is kept).
  let i = f.find(key)
  if i >= 0:
    f.vals[i] = value
  else:
    f.keys.add key
    f.vals.add value

proc put*(f: var Fields; key: string; value: int) = f.put(key, $value)
proc put*(f: var Fields; key: string; value: bool) =
  f.put(key, if value: "1" else: "0")
proc put*(f: var Fields; key: string; value: float) =
  var s = ""
  s.addFloat(value)
  f.put(key, s)

proc get*(f: Fields; key: string; default = ""): string =
  let i = f.find(key)
  if i < 0: default else: f.vals[i]

proc getInt*(f: Fields; key: string; default = 0): int =
  let i = f.find(key)
  if i < 0:
    return default
  var n: BiggestInt = 0
  let s = f.vals[i]
  if s.len == 0 or parseBiggestInt(s.toOpenArray(0, s.len - 1), n) != s.len:
    return default
  int(n)

proc getFloat*(f: Fields; key: string; default = 0.0): float =
  let i = f.find(key)
  if i < 0:
    return default
  var x: BiggestFloat = 0.0
  let s = f.vals[i]
  if s.len == 0 or parseBiggestFloat(s.toOpenArray(0, s.len - 1), x) != s.len:
    return default
  float(x)

proc getBool*(f: Fields; key: string; default = false): bool =
  let i = f.find(key)
  if i < 0:
    return default
  let s = f.vals[i]
  s == "1" or s == "true" or s == "yes"

proc fields*(pairs: openArray[(string, string)]): Fields =
  ## A bag from literal pairs: `fields({"title": "Hi", "body": "..."})`.
  result = Fields()
  for p in pairs:
    result.put(p[0], p[1])

proc `==`*(a, b: Fields): bool =
  a.keys == b.keys and a.vals == b.vals

## --- wire form --------------------------------------------------------------------

const Hex = "0123456789ABCDEF"

proc escapeInto(r: var string; s: string) =
  for c in s:
    if c in {'A'..'Z', 'a'..'z', '0'..'9', '.', '_', '~', '-'}:
      r.add c
    else:
      r.add '%'
      r.add Hex[(ord(c) shr 4) and 15]
      r.add Hex[ord(c) and 15]

proc hexVal(c: char): int =
  case c
  of '0'..'9': ord(c) - ord('0')
  of 'A'..'F': ord(c) - ord('A') + 10
  of 'a'..'f': ord(c) - ord('a') + 10
  else: -1

proc unescape(s: string; lo, hi: int): string =
  ## `s[lo ..< hi]` with its `%XX` escapes decoded; a broken escape is
  ## kept literally.
  result = ""
  var i = lo
  while i < hi:
    let c = s[i]
    if c == '%' and i + 2 < hi:
      let a = hexVal(s[i + 1])
      let b = hexVal(s[i + 2])
      if a >= 0 and b >= 0:
        result.add char(a * 16 + b)
        i += 3
        continue
    result.add c
    inc i

proc encode*(f: Fields): string =
  ## The one-line wire form: `key=value` pairs joined by `&`.
  result = ""
  var i = 0
  while i < f.keys.len:
    if i > 0:
      result.add '&'
    escapeInto(result, f.keys[i])
    result.add '='
    escapeInto(result, f.vals[i])
    inc i

proc decode*(s: string): Fields =
  ## Parse `encode`'s output. Empty segments are skipped; a segment
  ## without `=` is a key with an empty value.
  result = Fields()
  var start = 0
  while start <= s.len:
    var stop = s.find('&', start)
    if stop < 0:
      stop = s.len
    if stop > start:
      let eq = s.find('=', start)
      if eq >= 0 and eq < stop:
        result.put(unescape(s, start, eq), unescape(s, eq + 1, stop))
      else:
        result.put(unescape(s, start, stop), "")
    start = stop + 1

proc putList*(f: var Fields; key: string; items: openArray[string]) =
  ## A list as one value: each item escaped, joined by `,`.
  var v = ""
  var i = 0
  while i < items.len:
    if i > 0:
      v.add ','
    escapeInto(v, items[i])
    inc i
  f.put(key, v)

proc getList*(f: Fields; key: string): seq[string] =
  result = @[]
  let i = f.find(key)
  if i < 0:
    return
  let s = f.vals[i]
  if s.len == 0:
    return
  var start = 0
  while start <= s.len:
    var stop = s.find(',', start)
    if stop < 0:
      stop = s.len
    result.add unescape(s, start, stop)
    start = stop + 1

proc putFields*(f: var Fields; key: string; nested: Fields) =
  ## A whole bag as one value (its wire form) -- a dialog's arguments
  ## travel inside the request this way.
  f.put(key, encode(nested))

proc getFields*(f: Fields; key: string): Fields =
  decode(f.get(key))

## --- records -----------------------------------------------------------------------
##
## Any record of plain fields round-trips through `Fields` without a hand
## written conversion: `fieldsOf` stores every field under its own name,
## `fillFrom` reads the keys the bag has -- absent ones keep the record's
## own values, so a freshly made draft carries its defaults into a dialog.
## Field types: string, bool, int, float, uint64 and enums; anything else
## wants its own `put`/`readInto` overload, which is also how a nested
## record or a list of strings joins the round trip.

proc put*(f: var Fields; key: string; value: uint64) = f.put(key, value.int)
proc put*[E: enum](f: var Fields; key: string; value: E) =
  f.put(key, value.ord)

proc readInto*(v: var string; f: Fields; key: string) =
  if f.has(key): v = f.get(key)
proc readInto*(v: var int; f: Fields; key: string) =
  if f.has(key): v = f.getInt(key)
proc readInto*(v: var bool; f: Fields; key: string) =
  if f.has(key): v = f.getBool(key)
proc readInto*(v: var float; f: Fields; key: string) =
  if f.has(key): v = f.getFloat(key)
proc readInto*(v: var uint64; f: Fields; key: string) =
  if f.has(key): v = f.getInt(key).uint64
proc readInto*[E: enum](v: var E; f: Fields; key: string) =
  if f.has(key): v = E(f.getInt(key))

proc fieldsOf*[T: tuple|object](x: T): Fields =
  ## Every field of `x`, stored under its name.
  result = Fields()
  for k, v in x.fieldPairs:
    result.put(k, v)

proc fillFrom*[T: tuple|object](x: var T; f: Fields) =
  ## Set the fields of `x` that `f` carries; the rest keep their values.
  for k, v in x.fieldPairs:
    v.readInto(f, k)

proc withFields*[T: tuple|object](x: sink T; f: Fields): T =
  ## `x` filled from `f` -- reading a form's record back from the result:
  ## `members.add blank().withFields(r.fields)`.
  result = x
  result.fillFrom(f)
