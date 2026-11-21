import std/[unittest, math, sequtils, strutils]
import ellipse_ui
import ellipse/platform/damage

proc measure(text: string, cfg: TextConfig): Size =
  size(text.len.float32*cfg.fontSize.float32*0.5,cfg.fontSize.float32)
proc setup(w = 700f, h = 400f) =
  setCurrentContext(initContext(size(w,h)))
  setMeasureText(measure)
  setPointerState(vec2(-100,-100),false)

suite "tables and line charts":
  test "numeric sorting uses source indices and stable descending ties":
    let values = [10,2,10,-1]
    let compare: TableCompare = proc(a,b,c: int): int = cmp(values[a],values[b])
    check tableOrder(4,TableSort(column: 0),compare) == @[3,1,0,2]
    check tableOrder(4,TableSort(column: 0,descending: true),compare) == @[0,2,1,3]
    check nextTableSort(TableSort(column: 0),0).descending
    check not nextTableSort(TableSort(column: 0,descending: true),1).descending
  test "virtualization bounds actual cell work for ten thousand rows and scrolls over cells":
    setup()
    let id = hashId("largeTable")
    var cells = 0
    proc frame() =
      beginLayout()
      discard dataTable(id,[tableColumn("Name"),tableColumn("Number",fixedPx(100),right)],10000,
        proc(r,c: int) =
          inc cells
          tableText($r))
      endLayout()
    frame()
    cells = 0
    frame()
    check cells < 100
    let body = tableBodyId(id)
    let data = scrollContainerData(body)
    check data.contentDimensions.height > 300000
    let row = elementData(tableRowId(id,"0")).box
    setPointerState(vec2(row.x+20,row.y+10),false)
    updateScrollContainers(false,vec2(0,-10),0.1)
    frame()
    check scrollContainerData(body).position.y < 0
    setScrollPosition(body,vec2(0,-38000))
    cells = 0
    frame()
    check cells < 100
    let visible = tableVisibleRows(10000,38,364,-38000)
    check visible.first > 990
    check visible.last-visible.first < 20
    check tableVisibleRows(2,38,364,-38000).first == 0
  test "header sorting and sorted row activation return original records":
    setup()
    let id = hashId("table")
    let values = [20,3,8]
    let sort = TableSort(column: 0)
    proc frame(): TableAction =
      beginLayout()
      result = dataTable(id,[tableColumn("Value")],3,
        proc(r,c: int) = tableText($values[r]),sort = sort,
        compare = proc(a,b,c: int): int = cmp(values[a],values[b]),
        selectable = true,rowKey = proc(r: int): string = "key" & $r)
      endLayout()
    discard frame()
    for target in [tableHeaderId(id,0),tableRowId(id,"key1")]:
      let box = elementData(target).box
      setPointerState(vec2(box.x+10,box.y+10),false)
      discard frame()
      setPointerState(vec2(box.x+10,box.y+10),true)
      notePressState()
      let action = frame()
      if target == tableHeaderId(id,0):
        check action.sortChanged
        check action.sort.descending
        check action.row == -1
      else:
        check not action.sortChanged
        check action.row == 1
      setPointerState(vec2(-100,-100),false)
      discard frame()
  test "nested table scroll axes keep the vertical bar pinned and jump on press":
    setup(w = 400, h = 300)
    let id = hashId("pinnedTable")
    let bodyId = tableBodyId(id)
    let horizontalId = localId("table.horizontal", id.id)
    let verticalBar = localId("table.vbar", id.id)
    let horizontalBar = localId("table.hbar", id.id)
    let verticalTrack = localId("sb.vtrack", verticalBar.id)
    let horizontalTrack = localId("sb.htrack", horizontalBar.id)
    let verticalThumb = localId("sb.vthumb", verticalBar.id)
    let firstRow = tableRowId(id, "0")
    proc frame() =
      beginLayout()
      discard dataTable(id, [tableColumn("Name", fixedPx(800))], 100,
        proc(r, c: int) = tableText($r))
      endLayout()
    frame()
    frame()
    let startTrack = elementData(verticalTrack).box
    let startRow = elementData(firstRow).box
    setPointerState(vec2(startRow.x + 30, startRow.y + 10), false)
    updateScrollContainers(false, vec2(-12, -4), 0.1)
    frame()
    check scrollContainerData(horizontalId).position.x < 0
    check scrollContainerData(bodyId).position.y < 0
    check elementData(firstRow).box.x < startRow.x
    check elementData(verticalTrack).box.x == startTrack.x
    check elementData(verticalTrack).box.y == startTrack.y
    check elementData(horizontalTrack).box.x + elementData(horizontalTrack).box.width <= startTrack.x

    let beforeX = scrollContainerData(horizontalId).position.x
    let beforeY = scrollContainerData(bodyId).position.y
    let beforeThumb = elementData(verticalThumb).box.y
    setPointerState(vec2(startTrack.x + startTrack.width / 2,
                         startTrack.y + startTrack.height * 0.75), true)
    notePressState()
    frame()
    check scrollContainerData(bodyId).position.y < beforeY
    check scrollContainerData(horizontalId).position.x == beforeX
    check elementData(verticalThumb).box.y > beforeThumb

    setPointerState(vec2(-100, -100), false)
    frame()
    let track = elementData(horizontalTrack).box
    setPointerState(vec2(track.x + track.width * 0.9, track.y + track.height / 2), true)
    notePressState()
    frame()
    check scrollContainerData(horizontalId).position.x < beforeX
    check elementData(verticalTrack).box.x == startTrack.x
  test "table columns align on the first resize frame and clipped cells reveal full text":
    setup(w = 1600, h = 280)
    let id = hashId("resizingTable")
    const longName = "Æ" & repeat("long-service-name/", 8)
    const longPath = "/usr/lib/systemd/" & repeat("long-path-segment/", 10)
    let columns = [tableColumn("Name", grow(140)), tableColumn("Scope", fixedPx(80)),
                   tableColumn("Unit file", grow(220))]
    proc draw() =
      beginLayout()
      discard dataTable(id, columns, 2, proc(row, column: int) =
        let values = if row == 0: [longName, "User", longPath]
                     else: ["short.service", "System", "/short"]
        tableText(values[column]))
      endLayout()
    proc cellId(row, column: int): ElementId =
      localIdWithIndex("table.cell", column.uint32, tableRowId(id, $row).id)
    proc checkColumns() =
      for column in 0 ..< columns.len:
        let header = elementData(tableHeaderId(id, column)).box
        for row in 0 .. 1:
          let cell = elementData(cellId(row, column)).box
          check cell.x == header.x
          check cell.width == header.width

    draw()
    checkColumns()
    setLayoutDimensions(size(520, 280))
    draw()
    checkColumns()
    let nameBox = elementData(cellId(0, 0)).box
    let clipped = renderCommands().filterIt(it.kind == renderText and lineText(it).startsWith("Æ"))
    check clipped.len == 1
    if clipped.len == 1:
      check lineText(clipped[0]).endsWith("…")
      check clipped[0].box.x + clipped[0].box.width <= nameBox.x + nameBox.width

    setPointerState(vec2(nameBox.x + 20, nameBox.y + 10), false)
    draw()
    let tooltip = renderCommands().filterIt(it.kind == renderText and it.zIndex >= 30020)
    check tooltip.len > 1
    check tooltip.mapIt(lineText(it)).join("") == longName
    for line in tooltip:
      check line.box.x >= 0
      check line.box.x + line.box.width <= 520
    let shortBox = elementData(cellId(1, 0)).box
    setPointerState(vec2(shortBox.x + 20, shortBox.y + 10), false)
    draw()
    check not renderCommands().anyIt(it.kind == renderText and it.zIndex >= 30020)
    setPointerState(vec2(-100, -100), false)
    setLayoutDimensions(size(300, 280))
    draw()
    checkColumns()
    let horizontalId = localId("table.horizontal", id.id)
    setScrollPosition(horizontalId, vec2(-90, 0))
    draw()
    checkColumns()
  test "text ellipsis preserves Unicode boundaries":
    setup()
    let clipped = fitTableText("Ægir the merchant",64,TextConfig(fontSize: 12))
    check clipped.endsWith("…")
    check not clipped.contains("\xEF\xBF\xBD")
    check measure(clipped,TextConfig(fontSize: 12)).width <= 64
  test "chart ranges include negative values, ignore hidden lines and handle empty data":
    let lines = @[ChartLine(values: @[-5.0,10.0]),ChartLine(values: @[10000.0],visible: false)]
    let bounds = chartRange(lines)
    check bounds.low < -5
    check bounds.high > 10 and bounds.high < 20
    check bounds.count == 2
    let empty = chartRange(@[])
    check empty.high > empty.low
    check chartRange(@[ChartLine(values: @[NaN,Inf,-Inf,1.0])]).high < 2
  test "charts emit one plot command and checkbox toggles exactly one line":
    setup()
    let id = hashId("chart")
    let lines = @[ChartLine(label: "Revenue",values: @[1.0,2,3],color: rgb(255,180,90)),
      ChartLine(label: "Net",values: @[-1.0,1,2],color: rgb(90,210,180))]
    proc frame(): ChartAction =
      beginLayout()
      result = lineChart(id,lines)
      endLayout()
    discard frame()
    check renderCommands().filterIt(it.kind == renderCustom).len == 1
    let box = elementData(lineToggleId(id,1)).box
    setPointerState(vec2(box.x+10,box.y+10),false)
    discard frame()
    setPointerState(vec2(box.x+10,box.y+10),true)
    notePressState()
    let action = frame()
    check action.toggled == 1
    check not action.visible
  test "custom content versions participate in retained paint invalidation":
    setup()
    beginLayout()
    clay "custom", row(width = fixedPx(100),height = fixedPx(100)).custom(cast[pointer](1),1): discard
    endLayout()
    let before = signature(renderCommands().filterIt(it.kind == renderCustom)[0], "")
    beginLayout()
    clay "custom", row(width = fixedPx(100),height = fixedPx(100)).custom(cast[pointer](1),2): discard
    endLayout()
    let after = signature(renderCommands().filterIt(it.kind == renderCustom)[0], "")
    check before != after
