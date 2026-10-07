## ellipse -- the whole kit behind one import.
##
##   import ellipse
##
##   proc view() {.raises.} =
##     clay "root", col(width = grow(), height = grow()).bg(bgColor):
##       heading("Hello", 1)
##
##   when isMainModule:
##     run App(window: WindowConfig(title: "hello"), view: view)
##
## Brings along the app shell (`ellipse_ui/app`, which carries clay, the
## platform and renderer, the logger, `ui`, the widget set and the debug
## overlay) and the frame clock. Programs that want less can import the
## fragments directly; see apps/ for complete examples.

import ellipse/clock
import ellipse_ui/app

export clock, app
