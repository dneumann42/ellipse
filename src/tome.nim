import std/[syncio]

import clay
import ellipse/logger
import ellipse/platform/platform
import ellipse/platform/renderer
import ellipse_ui/ui
import ellipse_ui/widgets

addHandler initStandardLogger()

widget Page(body: proc(): void):
  clay "app", col(width = grow(), height = grow(), alignX = centerX, padding = padAll(8))
      .bg(bgColor):
    body()

widget Toolbar(body: proc(): void):
  toolBar("toolbar", body)

widget Scroll(body: proc(): void):
  scrollPanel "scroll", col(width = grow(), height = grow(), padding = padAll(28))
      .clip(horizontal = false, vertical = true,
            childOffset = currentScrollOffset()):
    clay "content", col(width = grow(max = 820), height = fit(), gap = 10,
                        alignX = centerX):
      body()

widget TaskList(body: proc(): void):
  Scroll:
    body()

widget Task(title: string, content: string):
  Card(title = title, actions = emptySlot):
    bodyText(content)

let tasks = block:
  var ts: seq[tuple[title, content: string]] = @[]
  for i in 0 ..< 1000:
    ts.add (title: "HELLO " & $i, content: "Hello, World 123 test test test")
  ts

proc update() {.raises.} =
  updateUI()
  layout:
    Page:
      Toolbar:
        menu("File") do():
          if menuItem("Increment", "Ctrl++"): discard
          if menuItem("Decrement", "Ctrl+-"): discard
          menuSeparator()
          if menuItem("Scroll to top"):
            setScrollPosition(hashId("scroll"), vec2(0.0, 0.0))
          if menuItem("Reset gallery"): discard
        menu("View") do():
          if menuItem("Intro text"): discard
          if menuItem("Large count"): discard
        spacer()
        menu("+ New") do():
          if menuItem("New Task"): discard
          if menuItem("New Board"): discard
          
      TaskList:
        for (title, content) in tasks:
          Task(title, content)

proc render() {.raises.} =
  drawCommands()

when isMainModule:
  try:
    initialize()
    initializeRenderer()
    let (w, h) = windowPixelSize()
    setCurrentContext(initContext(size(w, h)))
    setMeasureText(measureText)
    start(update, render)
  except ErrorCode:
    discard
