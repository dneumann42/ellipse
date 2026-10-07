## Nest -- A project management tool
##
## Run:   make run
##        F1 in the window for the debug overlay

import ellipse

# ellipse:imports -- `ellipse new widget` adds widget modules here

proc view() {.raises.} =
  let t = activeTheme
  clay "root", col(width = grow(), height = grow(), gap = 12,
                   padding = padAll(24)).bg(t.palette.bg):
    heading("Nest", 1)
    caption("Edit src/nest.nim, then `make run`.")

when isMainModule:
  run App(window: WindowConfig(title: "Nest", width: 1280,
                               height: 720),
          view: view)
