

type Row* = object
  cells*: CellMap
  constant*: KiwiScalar

func initRow*(constant: KiwiScalar = KiwiScalar(0.0)): Row =
  Row(cells: initCellMap(), constant: constant)

func add*(row: var Row, value: KiwiScalar): KiwiScalar =
  row.constant += value
  row.constant

func addProductFor*(row: var Row, symbol: Symbol, value: KiwiScalar): bool =
  result = false
  let index = row.cells.findIndex(symbol)
  if index >= 0:
    discard row.add(value * row.cells.entries[index].coefficient)
    result = true

func insert*(row: var Row, symbol: Symbol, coefficient: KiwiScalar = KiwiScalar(1.0)) =
  row.cells.add(symbol, coefficient)

func insert*(row: var Row, other: Row, coefficient: KiwiScalar = KiwiScalar(1.0)) =
  row.constant += other.constant * coefficient
  for index in 0 ..< other.cells.entries.len:
    row.cells.add(
      other.cells.entries[index].symbol,
      other.cells.entries[index].coefficient * coefficient
    )

func remove*(row: var Row, symbol: Symbol) =
  row.cells.del(symbol)

func reverseSign*(row: var Row) =
  row.constant = -row.constant
  for index in 0 ..< row.cells.entries.len:
    row.cells.entries[index].coefficient = -row.cells.entries[index].coefficient

func solveFor*(row: var Row, symbol: Symbol) {.raises.} =
  let coeff = -1 / row.cells[symbol]
  row.cells.del(symbol)
  row.constant *= coeff
  for index in 0 ..< row.cells.entries.len:
    row.cells.entries[index].coefficient *= coeff

func solveFor*(row: var Row, lhs, rhs: Symbol) {.raises.} =
  row.insert(lhs, -1)
  row.solveFor(rhs)

func coefficientFor*(row: Row, symbol: Symbol): KiwiScalar =
  row.cells.getOrDefault(symbol, KiwiScalar(0.0))

func substitute*(row: var Row, symbol: Symbol, other: Row) =
  var coefficient = KiwiScalar(0.0)
  if row.cells.pop(symbol, coefficient):
    row.insert(other, coefficient)
