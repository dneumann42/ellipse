## Sorted symbol/coefficient cell map used by tableau rows.


type
  Cell* = object
    symbol*: Symbol
    coefficient*: KiwiScalar

  CellMap* = object
    entries*: seq[Cell]

func initCellMap*(): CellMap {.inline.} =
  CellMap(entries: @[])

func lowerIndex(map: CellMap, symbol: Symbol): int {.inline.} =
  var low = 0
  var high = map.entries.len
  while low < high:
    let mid = (low + high) shr 1
    if map.entries[mid].symbol < symbol:
      low = mid + 1
    else:
      high = mid
  low

func findIndex*(map: CellMap, symbol: Symbol): int {.inline.} =
  if map.entries.len <= 8:
    for index in 0 ..< map.entries.len:
      let current = map.entries[index].symbol
      if current == symbol:
        return index
      if symbol < current:
        return -1
    return -1

  let index = map.lowerIndex(symbol)
  if index < map.entries.len and map.entries[index].symbol == symbol: index else: -1

func len*(map: CellMap): int {.inline.} =
  map.entries.len

func hasKey*(map: CellMap, symbol: Symbol): bool {.inline.} =
  map.findIndex(symbol) >= 0

func add*(map: var CellMap, symbol: Symbol, coefficient: KiwiScalar) =
  let index = map.lowerIndex(symbol)
  if index < map.entries.len and map.entries[index].symbol == symbol:
    let next = map.entries[index].coefficient + coefficient
    if next.nearZero:
      map.entries.delete(index)
    else:
      map.entries[index].coefficient = next
  elif not coefficient.nearZero:
    map.entries.add(Cell(symbol: symbol, coefficient: coefficient))
    var position = map.entries.high
    while position > index:
      # temp copy: Nimony rejects `s[i] = s[i-1]` as aliasing
      let prev = map.entries[position - 1]
      map.entries[position] = prev
      dec position
    map.entries[index] = Cell(symbol: symbol, coefficient: coefficient)

func `[]`*(map: CellMap, symbol: Symbol): KiwiScalar {.inline, raises.} =
  let index = map.findIndex(symbol)
  if index < 0:
    raise KeyError
  map.entries[index].coefficient

func `[]=`*(map: var CellMap, symbol: Symbol, coefficient: KiwiScalar) {.inline.} =
  let index = map.lowerIndex(symbol)
  if index < map.entries.len and map.entries[index].symbol == symbol:
    map.entries[index].coefficient = coefficient
  else:
    map.entries.add(Cell(symbol: symbol, coefficient: coefficient))
    var position = map.entries.high
    while position > index:
      let prev = map.entries[position - 1]
      map.entries[position] = prev
      dec position
    map.entries[index] = Cell(symbol: symbol, coefficient: coefficient)

func del*(map: var CellMap, symbol: Symbol) {.inline.} =
  let index = map.findIndex(symbol)
  if index >= 0:
    map.entries.delete(index)

func pop*(
    map: var CellMap, symbol: Symbol, coefficient: var KiwiScalar
): bool {.inline.} =
  result = false
  let index = map.findIndex(symbol)
  if index >= 0:
    coefficient = map.entries[index].coefficient
    map.entries.delete(index)
    result = true

func getOrDefault*(
    map: CellMap, symbol: Symbol, default: KiwiScalar
): KiwiScalar {.inline.} =
  let index = map.findIndex(symbol)
  if index >= 0:
    map.entries[index].coefficient
  else:
    default

iterator keys*(map: CellMap): Symbol =
  for cell in map.entries:
    yield cell.symbol

iterator pairs*(map: CellMap): (Symbol, KiwiScalar) =
  for cell in map.entries:
    yield (cell.symbol, cell.coefficient)
