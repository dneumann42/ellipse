{.push gcsafe.}

{.localPassC: "-O3 -fno-math-errno".} # see parallel.nim
{.push stackTrace: off, lineTrace: off.}
import std/[algorithm, math]

import ./[parallel, heightfields]
export heightfields

{.push boundChecks: off, overflowChecks: off, rangeChecks: off.}

const
  CoarseBuckets = 4096
  FineBuckets = 256

type
  Search = ref object
    ## Exact rank-th lowest sample via two parallel histogram passes over the
    ## bit pattern; only the final bucket is sorted.
    surface: Grid[float32]
    rows: seq[uint32] # one private histogram per chunk, CoarseBuckets wide
    coarse: seq[uint32]
    fine: seq[uint32]
    starts: seq[int]
    cell: seq[float32]
    total: int
    chunks: int

func orderable*(value: float32): uint32 =
  ## Float bits mapped so unsigned order matches float order.
  let bits = cast[uint32](value)
  if (bits and 0x8000_0000'u32) != 0: not bits else: bits or 0x8000_0000'u32

func coarseBits(order: uint32): int = int(order shr 20)

func fineBits(order: uint32): int = int((order shr 12) and (FineBuckets - 1))

func rank(field: Field, q: float32): int =
  (q * (field.size * field.size - 1).float32).int

func bucket(totals: openArray[uint32], buckets, rank: int): tuple[bucket, below: int] =
  var below = 0
  for index in 0 ..< buckets:
    let count = int(totals[index])
    if below + count > rank:
      return (index, below)
    inc below, count
  (buckets - 1, below) # only reachable if the counts miss the rank

proc merge(search: Search, totals: var seq[uint32], buckets: int) =
  let
    rows = buffer(search.rows)
    parts = search.chunks
  for index in `||`(0, buckets - 1, balanced):
    var sum = 0'u32
    for part in 0 ..< parts:
      inc sum, rows[part * CoarseBuckets + index]
    totals[index] = sum

proc count(search: Search, coarse: int) =
  ## Coarse histogram when `coarse < 0`, else the fine one within `coarse`.
  let
    surface = search.surface
    rows = buffer(search.rows)
    total = search.total
    parts = search.chunks
  for part in `||`(0, parts - 1, balanced):
    let
      lo = total * part div parts
      hi = total * (part + 1) div parts
      row = part * CoarseBuckets
    for index in 0 ..< CoarseBuckets:
      rows[row + index] = 0
    if coarse < 0:
      for index in lo ..< hi:
        inc rows[row + coarseBits(orderable(surface[index]))]
    else:
      for index in lo ..< hi:
        let order = orderable(surface[index])
        if coarseBits(order) == coarse:
          inc rows[row + fineBits(order)]
  if coarse < 0:
    merge(search, search.coarse, CoarseBuckets)
  else:
    merge(search, search.fine, FineBuckets)

proc gather(search: Search, coarse, fine: int) =
  let rows = buffer(search.rows)
  var landed = 0
  for part in 0 ..< search.chunks:
    search.starts[part] = landed
    inc landed, int(rows[part * CoarseBuckets + fine])
  search.starts[search.chunks] = landed
  search.cell.setLen(landed)
  let
    surface = search.surface
    starts = buffer(search.starts)
    into = buffer(search.cell)
    total = search.total
    parts = search.chunks
  for part in `||`(0, parts - 1, balanced):
    var at = starts[part]
    for index in total * part div parts ..< total * (part + 1) div parts:
      let order = orderable(surface[index])
      if coarseBits(order) == coarse and fineBits(order) == fine:
        into[at] = surface[index]
        inc at

proc quantile(search: Search, rank: int): float32 =
  let
    (coarse, below) = bucket(search.coarse, CoarseBuckets, rank)
  search.count(coarse)
  let
    (fine, within) = bucket(search.fine, FineBuckets, rank - below)
  search.gather(coarse, fine)
  sort(search.cell)
  search.cell[rank - below - within]

proc newSearch(field: Field): Search =
  let
    total = field.size * field.size
    parts = chunkCount(total)
  result = Search(
    surface: grid(field.data, field.size),
    rows: newSeq[uint32](parts * CoarseBuckets),
    coarse: newSeq[uint32](CoarseBuckets),
    fine: newSeq[uint32](FineBuckets),
    starts: newSeq[int](parts + 1),
    total: total,
    chunks: parts,
  )
  result.count(coarse = -1)

proc normalize*(field: Field, lowQ, highQ: float32) =
  ## Scales the field so the two quantiles land at 0 and 1.
  let
    search = newSearch(field)
    low = search.quantile(field.rank(lowQ))
    high = search.quantile(field.rank(highQ))
    surface = search.surface
    span = high - low
  for index in `||`(0, search.total - 1, balanced):
    surface[index] = clamp((surface[index] - low) / span, 0, 1)

{.pop.} # keep the checks-off region over `normalize`: an OpenMP structured
        # block may not contain the exception branches that `--checks:on`
        # generates for its indexed accesses
