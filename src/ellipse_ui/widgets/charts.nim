## Live line charts with caller-owned checkbox visibility and bounded drawing.
{.push gcsafe.}
import std/[math, tables, strutils]
import clay
import ../ui
import ./[common, checkboxes, texts]
import ellipse/platform/renderer

type
  ChartLine* = object
    label*: string
    color*: Color
    values*: seq[float]
    visible*: bool = true
  ChartAction* = object
    toggled*: int = -1
    visible*: bool
  ChartRange* = object
    low*, high*: float
    count*: int
  ChartDrawing = object
    lines: seq[ChartLine]
    bounds: ChartRange
    grid: Color
    hover: int
    version: uint64
var drawings {.threadvar.}: Table[uint32,ChartDrawing]
var drawingContext {.threadvar.}: Context

func chartRange*(lines: openArray[ChartLine]): ChartRange =
  result.low = 0
  result.high = 0
  for line in lines:
    if not line.visible: continue
    result.count = max(result.count,line.values.len)
    for value in line.values:
      if classify(value) in {fcNan,fcInf,fcNegInf}: continue
      result.low = min(result.low,value)
      result.high = max(result.high,value)
  if result.high == result.low: result.high = result.low+1
  else:
    let pad = (result.high-result.low)*0.06
    if result.low < 0: result.low -= pad
    result.high += pad

func chartPoint*(bounds: ChartRange, box: Rect, index: int, value: float): Vec2 =
  vec2(box.x+(if bounds.count <= 1: box.width else: index.float32/(bounds.count-1).float32*box.width),
    box.y+box.height-((value-bounds.low)/(bounds.high-bounds.low)).float32*box.height)

proc paintChart(cmd: RenderCommand) =
  if not drawings.hasKey(cmd.id): return
  let drawing = drawings[cmd.id]
  let box = rect(cmd.box.x+2,cmd.box.y+2,max(1f,cmd.box.width-4),max(1f,cmd.box.height-4))
  for tick in 0..4:
    let y = box.y+box.height*tick.float32/4
    paintPolyline([vec2(box.x,y),vec2(box.x+box.width,y)],drawing.grid,1)
  if drawing.bounds.low < 0:
    let p = chartPoint(drawing.bounds,box,0,0)
    paintPolyline([vec2(box.x,p.y),vec2(box.x+box.width,p.y)],drawing.grid,2)
  for line in drawing.lines:
    if not line.visible: continue
    var points: seq[Vec2]
    # Right-align shorter series to the latest observation.
    let first = drawing.bounds.count-line.values.len
    for i,value in line.values:
      if classify(value) in {fcNan,fcInf,fcNegInf}:
        paintPolyline(points,line.color)
        points.setLen(0)
      else: points.add chartPoint(drawing.bounds,box,first+i,value)
    paintPolyline(points,line.color)
    if points.len == 1:
      overlayRect(rect(points[0].x-2,points[0].y-2,4,4),line.color)
  if drawing.hover >= 0:
    let x = chartPoint(drawing.bounds,box,drawing.hover,0).x
    paintPolyline([vec2(x,box.y),vec2(x,box.y+box.height)],drawing.grid,1)

proc paintChartCells(buf: var CellBuffer, cmd: RenderCommand, area: CellRect) =
  if not drawings.hasKey(cmd.id): return
  let drawing = drawings[cmd.id]
  for line in drawing.lines:
    if not line.visible: continue
    for i,value in line.values:
      if classify(value) in {fcNan,fcInf,fcNegInf}: continue
      let point = chartPoint(drawing.bounds,cmd.box,drawing.bounds.count-line.values.len+i,value)
      let cell = buf.toCells(rect(point.x,point.y,1,1))
      if cell.c0 >= area.c0 and cell.c0 < area.c1 and cell.r0 >= area.r0 and cell.r0 < area.r1:
        buf.shadeGlyph(cell.c0,cell.r0,"•",line.color)
let chartPainter = registerCellPainter(paintChartCells)
registerCommandPainter(chartPainter,paintChart)

func lineToggleId*(id: ElementId, index: int): ElementId =
  localIdWithIndex("chart.toggle",index.uint32,id.id)
func chartPlotId*(id: ElementId): ElementId = localId("chart.plot",id.id)

func chartNumber(value: float): string =
  if abs(value) >= 1000000: result = formatFloat(value/1000000,ffDecimal,1) & "m"
  elif abs(value) >= 10000: result = formatFloat(value/1000,ffDecimal,1) & "k"
  elif abs(value) < 10 and value != value.int.float: result = formatFloat(value,ffDecimal,1)
  else: result = formatFloat(value,ffDecimal,0)
  if result.endsWith("."): result.setLen(result.len-1)

proc lineChart*(id: ElementId, lines: seq[ChartLine], height = fixedPx(160),
    legendColumns = 2, unit = "", oldestLabel = "120s ago", latestLabel = "Now"): ChartAction =
  ## Checkbox legends return a single visibility change; callers own it.
  ## Values are oldest-first, evenly spaced and share one labelled Y axis.
  ## Use separate charts for different units. Negative and empty series,
  ## one-point histories and nonfinite gaps are supported. The plot emits
  ## one custom render command, with geometry batched per visible line.
  result.toggled = -1
  let t = activeTheme
  let bounds = chartRange(lines)
  let plotId = chartPlotId(id)
  let box = elementData(plotId).box
  var hover = -1
  if pointerOver(plotId) and box.width > 0 and bounds.count > 0:
    hover = clamp(int(round((currentContext().pointerData().position.x-box.x)/box.width*(bounds.count-1).float)),0,bounds.count-1)
  if drawingContext != currentContext():
    drawings.clear()
    drawingContext = currentContext()
  var grid = t.palette.panelBorder
  grid.a = 80
  let previous = drawings.getOrDefault(plotId.id)
  let version = previous.version+(if previous.lines != lines or previous.grid != grid or previous.hover != hover: 1'u64 else: 0'u64)
  if drawings.len >= 128 and not drawings.hasKey(plotId.id): drawings.clear()
  drawings[plotId.id] = ChartDrawing(lines: lines,bounds: bounds,grid: grid,hover: hover,version: version)
  openElement(id)
  configureOpenElement(col(width = grow(),height = fit(),gap = 6))
  let columns = max(1,legendColumns)
  for start in countup(0,lines.high,columns):
    container(row(width = grow(),height = fit(),gap = 8)):
      for index in start..<min(start+columns,lines.len):
        let line = lines[index]
        container(row(width = grow(),height = fit(),gap = 5,alignY = centerY)):
          container(row(width = fixedPx(8),height = fixedPx(8)).bg(line.color)): discard
          let at = if hover < 0: line.values.high else: hover-(bounds.count-line.values.len)
          let value = if at in 0..<line.values.len: "  " & chartNumber(line.values[at]) & unit else: ""
          let visible = checkbox(lineToggleId(id,index),line.label & value,line.visible,fontSize = t.text.caption)
          if visible != line.visible:
            result.toggled = index
            result.visible = visible
  container(row(width = grow(),height = height,gap = 6)):
    container(col(width = fixedPx(52),height = grow())):
      for tick in 0..4:
        container(col(width = grow(),height = (if tick == 4: fit() else: grow()),alignX = right)):
          textElement(chartNumber(bounds.high-(bounds.high-bounds.low)*tick.float/4),
            TextConfig(fontSize: t.text.caption,color: t.palette.dimColor,wrap: noWrap))
    openElement(plotId)
    configureOpenElement(col(width = grow(),height = grow()).bg(t.palette.fieldBg)
      .custom(chartPainter,version))
    closeElement()
  container(row(width = grow(),height = fit(),padding = Padding(left: 58))):
    caption(if bounds.count == 0: "No visible samples yet" else: oldestLabel)
    spacer()
    caption(if hover >= 0: $(bounds.count-1-hover) & "s ago" else: latestLabel)
  closeElement()
