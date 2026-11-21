## Sortable, virtualized tables. Data and selection remain owned by the caller.
{.push gcsafe.}
import std/[algorithm, math, unicode]
import clay
import ../ui
import ./[common, scrollbars]

type
  TableColumn* = object
    title*: string
    width*: SizingAxis
    align*: AlignX
    sortable*: bool
  TableSort* = object
    column*: int = -1
    descending*: bool
  TableAction* = object
    row*: int = -1 ## Original data index, independent of display sort order.
    sort*: TableSort
    sortChanged*: bool
  TableCellRenderer* = proc(row, column: int) {.closure, gcsafe.}
  TableCompare* = proc(a, b, column: int): int {.closure, gcsafe.}
  TableRowKey* = proc(row: int): string {.closure, gcsafe.}

func tableColumn*(title: string, width = grow(120), align = left,
                  sortable = true): TableColumn =
  TableColumn(title: title,width: width,align: align,sortable: sortable)

func nextTableSort*(sort: TableSort, column: int): TableSort =
  TableSort(column: column,descending: sort.column == column and not sort.descending)

proc tableOrder*(count: int, sort: TableSort, compare: TableCompare = nil): seq[int] =
  ## Stable ties retain source order, including when descending.
  result = newSeq[int](max(0,count))
  for i in 0..<result.len: result[i] = i
  if sort.column >= 0 and compare != nil:
    result.sort(proc(a,b: int): int =
      let value = if sort.descending: compare(b,a,sort.column) else: compare(a,b,sort.column)
      if value == 0: cmp(a,b) else: value)

func tableVisibleRows*(count: int, rowHeight, viewport, scrollY: float32,
                       overscan = 2): tuple[first, last: int] =
  ## Half-open visible range. Clamps stale scroll offsets after data shrinks.
  if count <= 0 or rowHeight <= 0: return (0,0)
  let height = max(rowHeight,viewport)
  let offset = clamp(-scrollY,0f,max(0f,count.float32*rowHeight-height))
  result.first = max(0,int(floor(offset/rowHeight))-max(0,overscan))
  result.last = min(count,int(ceil((offset+height)/rowHeight))+max(0,overscan))

func tableHeaderId*(id: ElementId, column: int): ElementId =
  localIdWithIndex("table.header",column.uint32,id.id)
func tableBodyId*(id: ElementId): ElementId = localId("table.body",id.id)
func tableRowId*(id: ElementId, key: string): ElementId = localId("table.row." & key,id.id)

const TableCellPadding = 10

var activeTableCell {.threadvar.}: ElementId

proc fitTableText*(value: string, width: float32, cfg: TextConfig): string =
  if width <= 0: value else: ellipsizeText(currentContext(), value, width, cfg)

widget TableTooltip(id: ElementId, value: string, config: TextConfig):
  let theme = activeTheme
  let width = max(1f, min(560f, layoutDimensions().width - 32f))
  let z = max(30020'i16, min(enclosingZIndex(), 32766'i16) + 1'i16)
  item(localId("table.tooltip", id.id), col(padding = padAll(8))
      .bg(theme.palette.panelBg).border(1, theme.palette.panelBorder).corner(theme.radii.panel)
      .floating(attachElementId, parentId = id.id, zIndex = z, offset = vec2(0, 4),
        points = AttachPoints(element: pointLeftTop, parent: pointLeftBottom),
        capture = passThroughPointer, fitViewport = true)):
    var remaining = value
    while remaining.len > 0:
      let count = max(1, fittingTextPrefix(currentContext(), remaining, width, config))
      let line = remaining.runeSubStr(0, count)
      textElement(line, config)
      remaining = remaining[line.len .. ^1]

proc tableText*(value: string, muted = false) =
  ## Fit cell text against this frame's layout and reveal the full value on hover.
  let theme = activeTheme
  var config = TextConfig(fontSize: theme.text.caption, wrap: noWrap,
    color: (if muted: theme.palette.dimColor else: theme.palette.textColor))
  let cell = activeTableCell
  if cell.id != 0 and pointerOver(cell):
    let box = elementData(cell).box
    let width = max(0f, box.width - 2 * TableCellPadding)
    if box.width > 0 and ellipsizeText(currentContext(), value, width, config) != value:
      var tooltipConfig = config
      tooltipConfig.color = theme.palette.textColor
      TableTooltip(cell, value, tooltipConfig)
  config.ellipsis = cell.id != 0
  textElement(value, config)

const TableScrollbarGutter = 16

widget TableContainer(id: ElementId, columns: openArray[TableColumn],
                      tableHeight = grow(), minWidth = 0f, content: proc(): void):
  ## Frames the table and scrolls the header and body together horizontally.
  let containerId = id
  let horizontalId = localId("table.horizontal", containerId.id)
  let theme = activeTheme
  var minimum = 0f
  for column in columns:
    minimum += max(40f, column.width.min)
  minimum = max(minWidth - TableScrollbarGutter.float32, minimum)
  item(containerId, col(width = grow(), height = tableHeight,
      padding = Padding(right: TableScrollbarGutter))
      .bg(theme.palette.fieldBg).border(1, theme.palette.panelBorder).corner(theme.radii.panel)):
    item(horizontalId, col(width = grow(), height = grow())
        .clip(horizontal = true, vertical = false, childOffset = currentScrollOffset())):
      container(col(width = grow(minimum), height = grow())):
        content()
      scrollbar(localId("table.hbar", containerId.id), horizontalId)

widget TableHead(content: proc(): void):
  ## A fixed-height header above the vertically scrollable body.
  container(row(width = grow(), height = fixedPx(36)).bg(activeTheme.palette.panelBg)):
    content()

widget TableBody(id: ElementId, content: proc(): void):
  ## A vertically scrollable region beneath the header.
  let bodyId = tableBodyId(id)
  item(bodyId, col(width = grow(), height = grow())
      .clip(horizontal = false, vertical = true, childOffset = currentScrollOffset())):
    content()
    scrollbar(localId("table.vbar", id.id), bodyId, verticalAnchor = id)

widget TableRow(id: ElementId, index: int, rowHeight = 38f,
                selected = false, selectable = false, content: proc(): void):
  let rowId = id
  let theme = activeTheme
  if selectable:
    registerFocus(rowId)
  let background =
    if selected: theme.palette.selectedBg
    elif selectable and pointerOver(rowId): theme.palette.buttonHoverBg
    elif index mod 2 == 0: theme.palette.fieldBg
    else: theme.palette.panelBg
  item(rowId, row(width = grow(), height = fixedPx(rowHeight)).bg(background).focusRing(rowId)):
    content()

func tableCellLayout(column: TableColumn): ElementDeclaration =
  var width = column.width
  width.ignoreContent = true
  row(width = width, height = grow(), alignX = column.align, alignY = centerY,
    padding = Padding(left: TableCellPadding, right: TableCellPadding))

template tableCellContent(id: ElementId, layout: ElementDeclaration, content: untyped) =
  let cellId = id
  item(cellId, layout):
    let previousCell = activeTableCell
    activeTableCell = cellId
    content
    activeTableCell = previousCell

widget TableCell(rowId: ElementId, index: int, column: TableColumn, content: proc(): void):
  ## Lays out a cell with arbitrary content. tableText fits to the cell width.
  tableCellContent(localIdWithIndex("table.cell", index.uint32, rowId.id),
    tableCellLayout(column)):
    content()

widget TableHeaderCell(id: ElementId, index: int, column: TableColumn,
                       sort = TableSort(), interactive = true) -> bool:
  ## Draws a column label and reports activation for a sortable header.
  let headerId = tableHeaderId(id, index)
  let canSort = column.sortable and interactive
  let theme = activeTheme
  var layout = tableCellLayout(column)
  if canSort:
    registerFocus(headerId)
    if pointerOver(headerId):
      layout.background = theme.palette.buttonHoverBg
  let sorted = sort.column == index
  if sorted:
    layout.border = BorderConfig(color: theme.palette.accent, width: BorderWidth(bottom: 2))
  tableCellContent(headerId, layout.focusRing(headerId)):
    let indicator = if not sorted: "" elif sort.descending: " v" else: " ^"
    tableText(column.title & indicator)
  result = canSort and (clickedIn(headerId) or keyActivated(headerId))

proc dataTable*(id: ElementId, columns: openArray[TableColumn], count: int,
    cell: TableCellRenderer, sort = TableSort(), compare: TableCompare = nil,
    selectedRow = -1, selectable = false, rowKey: TableRowKey = nil,
    emptyText = "No rows to display.", height = grow(), rowHeight = 38f,
    minWidth = 0f): TableAction =
  ## Sortable, virtualized table built from the composable table widgets.
  var action = TableAction(row: -1, sort: sort)
  let rh = max(24f, rowHeight)
  let bodyId = tableBodyId(id)
  let order = tableOrder(count, sort, compare)
  let tableColumns = @columns
  TableContainer(id, tableColumns, height, minWidth):
    TableHead:
      for index, column in tableColumns:
        if TableHeaderCell(id, index, column, sort, interactive = compare != nil):
          action.sort = nextTableSort(sort, index)
          action.sortChanged = true
    TableBody(id):
      let data = scrollContainerData(bodyId)
      let viewport = if data.found and data.containerDimensions.height > 0:
        data.containerDimensions.height else: 600f
      let maxScroll = max(0f, order.len.float32 * rh - viewport)
      let scrollY = clamp(data.position.y, -maxScroll, 0f)
      if data.found and scrollY != data.position.y:
        setScrollPosition(bodyId, vec2(0, scrollY))
      let visible = tableVisibleRows(order.len, rh, viewport, scrollY)
      if order.len == 0:
        container(col(width = grow(), height = fixedPx(64), padding = padAll(12))):
          tableText(emptyText, true)
      else:
        if visible.first > 0:
          container(col(width = grow(), height = fixedPx(visible.first.float32 * rh))): discard
        for displayIndex in visible.first ..< visible.last:
          let source = order[displayIndex]
          let rowId = tableRowId(id, if rowKey == nil: $source else: rowKey(source))
          TableRow(rowId, displayIndex, rh, source == selectedRow, selectable):
            for index, column in tableColumns:
              TableCell(rowId, index, column):
                cell(source, index)
          if selectable and (clickedIn(rowId) or keyActivated(rowId)):
            action.row = source
        if visible.last < order.len:
          container(col(width = grow(), height = fixedPx((order.len - visible.last).float32 * rh))): discard
  result = action
