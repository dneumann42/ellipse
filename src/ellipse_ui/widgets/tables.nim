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
  TableCell* = proc(row, column: int) {.closure, gcsafe.}
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

var cellTextWidth {.threadvar.}: float32

proc fitTableText*(value: string, width: float32, cfg: TextConfig): string =
  ## Ellipsize on Unicode boundaries using the app's actual font measurement.
  let measure = currentContext().measureText
  if measure == nil or width <= 0: return value
  if measure(value,cfg).width <= width: return value
  if measure("…",cfg).width > width: return ""
  var lo = 0
  var hi = value.runeLen
  while lo < hi:
    let mid = (lo+hi+1) div 2
    if measure(value.runeSubStr(0,mid) & "…",cfg).width <= width: lo = mid
    else: hi = mid-1
  value.runeSubStr(0,lo) & "…"

proc tableText*(value: string, muted = false) =
  ## Single-line cell text, ellipsized to its column. Does not create a
  ## nested scroll container, so the table retains wheel ownership.
  let t = activeTheme
  let cfg = TextConfig(fontSize: t.text.caption,wrap: noWrap,
    color: (if muted: t.palette.dimColor else: t.palette.textColor))
  textElement(fitTableText(value,cellTextWidth,cfg),cfg)

proc dataTable*(id: ElementId, columns: openArray[TableColumn], count: int,
    cell: TableCell, sort = TableSort(), compare: TableCompare = nil,
    selectedRow = -1, selectable = false, rowKey: TableRowKey = nil,
    emptyText = "No rows to display.", height = grow(), rowHeight = 38f,
    minWidth = 0f): TableAction =
  ## A fixed header above a virtualized vertical body. The outer scroller
  ## moves header and body together horizontally. Cells may contain arbitrary
  ## widgets; fixed/grow column widths and alignment are shared by every row.
  ## Sorting and activation return actions, never mutate caller data. Supply
  ## a stable rowKey when backing rows can be inserted/removed while live.
  result = TableAction(row: -1,sort: sort)
  let t = activeTheme
  let rh = max(24f,rowHeight)
  let gutter = 16
  var minimum = gutter.float32
  for column in columns: minimum += max(40f,column.width.min)
  minimum = max(minWidth,minimum)
  let bodyId = tableBodyId(id)
  let horizontalId = localId("table.horizontal",id.id)
  let order = tableOrder(count,sort,compare)
  openElement(id)
  configureOpenElement(col(width = grow(),height = height)
    .bg(t.palette.fieldBg).border(1,t.palette.panelBorder).corner(t.radii.panel))
  openElement(horizontalId)
  configureOpenElement(col(width = grow(),height = grow())
    .clip(horizontal = true,vertical = false,childOffset = currentScrollOffset()))
  container(col(width = grow(minimum),height = grow())):
    container(row(width = grow(),height = fixedPx(36),
        padding = Padding(right: gutter)).bg(t.palette.panelBg)):
      for ci,column in columns:
        let headerId = tableHeaderId(id,ci)
        let canSort = column.sortable and compare != nil
        if canSort: registerFocus(headerId)
        var d = row(width = column.width,height = grow(),alignX = column.align,
          alignY = centerY,padding = Padding(left: 10,right: 10))
        if canSort and pointerOver(headerId): d.background = t.palette.buttonHoverBg
        if sort.column == ci:
          d.border = BorderConfig(color: t.palette.accent,width: BorderWidth(bottom: 2))
        openElement(headerId)
        configureOpenElement(d.focusRing(headerId))
        let previousWidth = cellTextWidth
        let headerBox = elementData(headerId).box
        cellTextWidth = max(20f,(if headerBox.width > 0: headerBox.width else: column.width.min)-20)
        tableText(column.title & (if sort.column != ci: "" elif sort.descending: " v" else: " ^"))
        cellTextWidth = previousWidth
        closeElement()
        if canSort and (clickedIn(headerId) or keyActivated(headerId)):
          result.sort = nextTableSort(sort,ci)
          result.sortChanged = true
    openElement(bodyId)
    configureOpenElement(col(width = grow(),height = grow(),padding = Padding(right: gutter))
      .clip(horizontal = false,vertical = true,childOffset = currentScrollOffset()))
    let data = scrollContainerData(bodyId)
    let viewport = if data.found and data.containerDimensions.height > 0:
      data.containerDimensions.height else: 600f
    let maxScroll = max(0f,order.len.float32*rh-viewport)
    let scrollY = clamp(data.position.y,-maxScroll,0f)
    if data.found and scrollY != data.position.y:
      setScrollPosition(bodyId,vec2(0,scrollY))
    let visible = tableVisibleRows(order.len,rh,viewport,scrollY)
    if order.len == 0:
      container(col(width = grow(),height = fixedPx(64),padding = padAll(12))):
        tableText(emptyText,true)
    else:
      if visible.first > 0:
        container(col(width = grow(),height = fixedPx(visible.first.float32*rh))): discard
      for displayIndex in visible.first..<visible.last:
        let source = order[displayIndex]
        let rowId = tableRowId(id,if rowKey == nil: $source else: rowKey(source))
        if selectable: registerFocus(rowId)
        let background = if source == selectedRow: t.palette.selectedBg
          elif selectable and pointerOver(rowId): t.palette.buttonHoverBg
          elif displayIndex mod 2 == 0: t.palette.fieldBg else: t.palette.panelBg
        openElement(rowId)
        configureOpenElement(row(width = grow(),height = fixedPx(rh))
          .bg(background).focusRing(rowId))
        for ci,column in columns:
          let cellId = localIdWithIndex("table.cell",ci.uint32,rowId.id)
          openElement(cellId)
          configureOpenElement(row(width = column.width,height = grow(),alignX = column.align,
            alignY = centerY,padding = Padding(left: 10,right: 10)))
          let previousWidth = cellTextWidth
          let box = elementData(cellId).box
          cellTextWidth = max(20f,(if box.width > 0: box.width else: column.width.min)-20)
          cell(source,ci)
          cellTextWidth = previousWidth
          closeElement()
        closeElement()
        if selectable and (clickedIn(rowId) or keyActivated(rowId)): result.row = source
      if visible.last < order.len:
        container(col(width = grow(),height = fixedPx((order.len-visible.last).float32*rh))): discard
    scrollbar(localId("table.vbar",id.id),bodyId)
    closeElement()
  scrollbar(localId("table.hbar",id.id),horizontalId)
  closeElement()
  closeElement()
