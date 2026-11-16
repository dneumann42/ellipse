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
