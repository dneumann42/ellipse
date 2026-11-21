## Sparse X/Z broad phase for derived collision geometry. Indices are runtime
## data; owners rebuild them when their authored geometry changes.
{.push gcsafe.}


import std/[math, tables]

type
  SpatialBounds* = object
    x0*, x1*, z0*, z1*: float
  SpatialIndex* = object
    cells: Table[tuple[x, z: int], seq[int]]
    bounds: seq[SpatialBounds]

const spatialCell = 32.0

func cell(at: float): int = floor(at / spatialCell).int

proc add*(index: var SpatialIndex, b: SpatialBounds): int =
  ## Insert in authored order; useful while accepting procedural placements.
  result = index.bounds.len
  index.bounds.add b
  for x in cell(b.x0) .. cell(b.x1):
    for z in cell(b.z0) .. cell(b.z1):
      index.cells.mgetOrPut((x, z), @[]).add result

proc rebuild*(index: var SpatialIndex, bounds: openArray[SpatialBounds]) =
  index.cells.clear()
  index.bounds.setLen(0)
  for b in bounds:
    discard index.add(b)

iterator nearby*(index: SpatialIndex, x0, x1, z0, z1: float): int =
  ## A spanning rectangle can list an index in several cells. Yield it only
  ## from the first overlapping cell, avoiding allocations for deduplication.
  let firstX = cell(x0)
  let firstZ = cell(z0)
  for x in firstX .. cell(x1):
    for z in firstZ .. cell(z1):
      # Borrow the bucket; a value-returning getter copies its sequence.
      index.cells.withValue((x,z),indices):
        for i in indices:
          let b = index.bounds[i]
          if x == max(firstX, cell(b.x0)) and z == max(firstZ, cell(b.z0)) and
              b.x1 >= x0 and b.x0 <= x1 and b.z1 >= z0 and b.z0 <= z1:
            yield i

func overlaps*(b: SpatialBounds, x0, x1, z0, z1: float): bool =
  b.x1 >= x0 and b.x0 <= x1 and b.z1 >= z0 and b.z0 <= z1
