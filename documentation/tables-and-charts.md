# Tables and line charts

`import ellipse_ui` exports both APIs. They are immediate mode: the app owns
selection, sorting and line visibility. Widgets return actions to apply after
layout; they never reorder or mutate the input records.

## Tables

```nim
var sort = TableSort(column: 0)
let action = dataTable(hashId("stock"), [
  tableColumn("Name", grow(180)),
  tableColumn("Units", fixedPx(80), right)], stock.len,
  cell = proc(row, column: int) =
    if column == 0: tableText(stock[row].name)
    else: tableText($stock[row].quantity),
  sort = sort,
  compare = proc(a, b, column: int): int =
    if column == 0: cmp(stock[a].name, stock[b].name)
    else: cmp(stock[a].quantity, stock[b].quantity),
  selectable = true,
  rowKey = proc(row: int): string = stock[row].id,
  selectedRow = selected)
if action.sortChanged: sort = action.sort
if action.row >= 0: selected = action.row
```

- `TableColumn` shares width and alignment between its header and every cell.
  Fixed and growing columns can be mixed. `sortable = false` disables a header.
- `TableCompare` compares original row indices and a column. Ascending and
  descending ties retain input order. `action.row` always identifies the original
  record, even after sorting. Use durable unique `rowKey`s for changing data.
- `cell` is a slot for arbitrary widgets, including buttons. `tableText` uses the
  current font measurement and Unicode-safe ellipsis. It does not swallow wheel
  scrolling. Non-text widgets should respect their cell's width and row height.
- Header stays above the vertical viewport; horizontal scrolling moves both
  header and body together. Scrollbars support dragging. `height`, `rowHeight`,
  `minWidth` and `emptyText` configure the table.
- Only the visible rows plus overscan invoke `cell`; sorting works on integer
  indices. The table is a bounded-height widget (`grow()` by default).
- Interactive headers and rows support Tab focus and Enter/Space activation.
  `tableHeaderId`, `tableRowId`, `tableBodyId`, `tableOrder` and
  `tableVisibleRows` are available for composition and testing.

## Charts

```nim
let action = lineChart(hashId("cash"), @[
  ChartLine(label: "Sales", color: rgb(231,180,88),
    values: salesHistory, visible: showSales),
  ChartLine(label: "Net", color: rgb(94,205,176),
    values: netHistory, visible: showNet)], unit = "g")
if action.toggled == 0: showSales = action.visible
if action.toggled == 1: showNet = action.visible
```

Values are oldest first at even time intervals. Shorter series align with the
latest observation. Each line has a color, checkbox and latest/hovered value.
`height`, `legendColumns`, `oldestLabel` and `latestLabel` control presentation.
The caller should bound history and use separate plots for different units.

Range includes zero and negative values; hidden lines do not affect it. Empty
histories and one-point histories are supported. NaN/infinite values break the
line rather than contaminating the range. Hovering shows a crosshair and values.

Each plot emits one custom render command; native lines are antialiased geometry
batched per series, with normal nested clipping and retained damage handling.
Terminal plots render sample points. `lineToggleId` and `chartPlotId` expose
stable sub-elements for tests. `chartRange` and `chartPoint` expose the mapping.

Native custom widgets can register a `CommandPainter` with
`registerCommandPainter`, sharing a handle with `registerCellPainter`.
`.custom(handle, version)` must change its version when drawing data changes so
retained painting invalidates the plot. `paintPolyline` batches lines without
altering the active clip.

Run `tests/gui/tables_charts_test.nim` for sorting, virtualization, wheel input,
activation, ellipsis, chart range, checkbox and retained-paint coverage.
