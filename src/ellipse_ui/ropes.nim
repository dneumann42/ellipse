import std/[options, sequtils, strutils]

type
  Rope* = ref object
    left, right: Rope
    cachedLen: int
    weight: int
    lexeme: string

const
  maxLeafLen* = 64
  rebalanceThreshold = 2

proc len*(rope: Rope): int =
  if rope.isNil:
    return
  if rope.left.isNil and rope.right.isNil:
    return rope.lexeme.len
  if rope.cachedLen == 0:
    rope.cachedLen = rope.left.len + rope.right.len
  result = rope.cachedLen

proc height(rope: Rope): int =
  if rope.isNil:
    return
  if rope.left.isNil and rope.right.isNil:
    return 1
  let l = rope.left.height
  let r = rope.right.height
  result = (if l > r: l else: r) + 1

proc isEmpty*(rope: Rope): bool =
  rope.len == 0

proc init*(T: typedesc[Rope], s: sink string): T =
  new(result)
  result.lexeme = s

proc chunkify(tokens: openArray[string]): seq[string] =
  var cur = ""
  for token in tokens:
    if token.len > maxLeafLen and cur.len == 0:
      result.add(token)
    elif cur.len + token.len > maxLeafLen:
      result.add(cur)
      cur = token
    else:
      cur.add(token)
  if cur.len > 0:
    result.add(cur)

proc build(chunks: sink seq[string]): Rope =
  if chunks.len == 0:
    return Rope()
  var level = chunks.mapIt(Rope(lexeme: it))
  while level.len > 1:
    var next: seq[Rope] = @[]
    var i = 0
    while i + 1 < level.len:
      next.add(Rope(left: level[i], right: level[i+1], weight: level[i].len))
      i += 2
    if i < level.len:
      next.add(level[i])
    level = next
  level[0]

proc init*(T: typedesc[Rope], tokens: openArray[string]): T =
  build(tokens.chunkify)

proc collectLeaves(rope: Rope, chunks: var seq[string]) =
  if rope.isNil:
    return
  if rope.left.isNil and rope.right.isNil:
    if rope.lexeme.len > 0:
      chunks.add(rope.lexeme)
  else:
    rope.left.collectLeaves(chunks)
    rope.right.collectLeaves(chunks)

iterator chunks*(rope: Rope): string =
  var pending = @[rope]
  while pending.len > 0:
    let node = pending.pop()
    if node.isNil: continue
    if node.left.isNil and node.right.isNil:
      if node.lexeme.len > 0: yield node.lexeme
    else:
      pending.add node.right
      pending.add node.left

proc flatten*(rope: Rope): string =
  var chunks: seq[string] = @[]
  rope.collectLeaves(chunks)
  for chunk in chunks:
    result.add(chunk)

proc rebalance*(rope: Rope): Rope =
  if rope.isNil or (rope.left.isNil and rope.right.isNil):
    return rope
  var chunks: seq[string] = @[]
  rope.collectLeaves(chunks)
  build(chunks)

proc `[]`*(rope: Rope, index: int): Option[char] =
  if rope.isNil or index < 0 or index >= rope.len:
    return
  if rope.left.isNil and rope.right.isNil:
    return some(rope.lexeme[index])
  if index < rope.weight:
    return rope.left[index]
  return rope.right[index - rope.weight]

proc `&`*(a, b: Rope): Rope =
  if a.isNil or a.isEmpty:
    return b
  if b.isNil or b.isEmpty:
    return a
  result = Rope(left: a, right: b, weight: a.len)
  if abs(a.height - b.height) > rebalanceThreshold:
    result = result.rebalance

proc `$`*(rope: Rope): string =
  rope.flatten

proc slice*(rope: Rope, start, stop: int): Rope =
  let n = rope.len
  if n == 0 or stop <= start:
    return Rope.init("")
  let lo = clamp(start, 0, n)
  let hi = clamp(stop, 0, n)
  proc walk(node: Rope, offset: int): Rope =
    if node.isNil or hi <= offset or lo >= offset + node.len:
      return nil
    if lo <= offset and hi >= offset + node.len:
      return node
    if node.left.isNil and node.right.isNil:
      return Rope.init(node.lexeme[max(lo - offset, 0) ..< min(hi - offset, node.lexeme.len)])
    walk(node.left, offset) & walk(node.right, offset + node.weight)
  walk(rope, 0)

proc insert*(rope: Rope, index: int, sub: sink string): Rope =
  let at = clamp(index, 0, rope.len)
  result = rope.slice(0, at) & Rope.init(sub) & rope.slice(at, rope.len)

proc insert*(rope: Rope, index: int, sub: Rope): Rope =
  if sub.isNil or sub.isEmpty:
    return rope
  let at = clamp(index, 0, rope.len)
  result = rope.slice(0, at) & sub & rope.slice(at, rope.len)

proc insert*(rope: Rope, index: int, c: char): Rope =
  rope.insert(index, $c)

proc delete*(rope: Rope, start, stop: int): Rope =
  let n = rope.len
  let lo = clamp(start, 0, n)
  let hi = clamp(stop, lo, n)
  if hi <= lo:
    return rope
  rope.slice(0, lo) & rope.slice(hi, n)

proc append*(rope: Rope, sub: sink string): Rope =
  rope & Rope.init(sub)

proc append*(rope: Rope, c: char): Rope =
  rope & Rope.init($c)

proc prepend*(rope: Rope, sub: sink string): Rope =
  Rope.init(sub) & rope

proc remove*(rope: Rope, c: char): Rope =
  let s = rope.flatten.replace($c, "")
  Rope.init(chunkify(@[s]))
