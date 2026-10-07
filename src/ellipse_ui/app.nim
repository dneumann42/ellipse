## The app shell: everything an ellipse_ui program used to spell out in
## its `main` -- stdout logging, `bootup`, the F1 debug overlay, the
## per-frame `updateUI` + `layout` pass, the `drawCommands` render and the
## paced `start` loop -- behind one `run`.
##
##   import ellipse_ui/app
##
##   var count = 0
##
##   proc view() {.raises.} =
##     clay "root", col(width = grow(), height = grow()).bg(bgColor):
##       if textLink(hashId("more"), "Clicked " & $count): inc count
##
##   when isMainModule:
##     run App(window: WindowConfig(title: "counter"), view: view)
##
## Importing this module brings the whole kit along: clay, the platform
## and renderer, the logger, `ui`, the widget set and the debug overlay.
##
## A frame runs, in order:
##
##   hook      when                               typical use
##   --------+----------------------------------+------------------------------
##   input     inside `updateUI`, before focus,   app-wide bindings that take
##             widgets and scrolling see input    keys (`consumeKeys`) or the
##                                                wheel (`holdWheel`)
##   before    after `updateUI`, before layout    chords read from `keyEvents`
##   view      inside `layout`                    the widget tree
##   after     after layout                       focus restores, window title
##
## `setup` runs once, after the window is up and before the first frame.

import clay
import ellipse/logger
import ellipse/platform/platform
import ellipse/platform/renderer
import ./ui
import ./widgets
import ./debug

export clay, logger, platform, renderer, ui, widgets, debug

type
  AppFn* = proc () {.closure, raises.}

  App* = object
    window*: WindowConfig      ## title, size, or a docked layer-shell bar
    debugMode*: bool = true    ## F1 toggles the debug overlay
    log*: bool = true          ## install the standard stdout logger
    setup*: nil AppFn          ## once, after `bootup`
    input*: nil InputHook      ## every frame, inside `updateUI`
    before*: nil AppFn         ## every frame, before the layout pass
    view*: nil AppFn           ## every frame, inside `layout`
    after*: nil AppFn          ## every frame, after the layout pass

var current: App

proc frame*() {.raises.} =
  ## One update pass of the launched app: input, hooks, layout. The loop
  ## runs this every paced frame; a `script` drives it by hand.
  updateUI()
  let before = current.before
  if before != nil:
    before()
  let view = current.view
  layout:
    if view != nil:
      view()
  let after = current.after
  if after != nil:
    after()

proc render() {.raises.} =
  drawCommands()

proc launch*(app: App) {.raises.} =
  ## Open the window and wire the app in without entering the loop: the
  ## logger, `bootup`, the debug overlay, the input hook, then `setup`.
  current = app
  if app.log:
    addHandler initStandardLogger()
  bootup(app.window)
  if app.debugMode:
    installDebugMode()
  let input = app.input
  if input != nil:
    onInputFrame(input)
  let setup = app.setup
  if setup != nil:
    setup()

proc run*(app: App; script: nil AppFn = nil) =
  ## `launch` the app and hand it to the paced loop until the window
  ## closes. With a `script` the loop is skipped and the script runs
  ## instead, driving `frame` itself -- the headless screenshot/test seam
  ## (`SDL_VIDEODRIVER=offscreen`). Startup errors end the program quietly,
  ## like every hand-written `main` before this did.
  try:
    launch(app)
    if script != nil:
      script()
    else:
      start(frame, render)
  except ErrorCode:
    discard
