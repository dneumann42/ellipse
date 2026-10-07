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
## `prepare` runs first, before the window opens, in every process the
## app starts -- dialog windows included (see `ellipse_ui/dialogs`): the
## place to define dialogs and pick the theme. `setup` runs once, after
## the window is up and before the first frame, in the main process only.
##
## Dialogs ride along every frame: `updateDialogs` right after `updateUI`
## (window dialogs that finished deliver their results), `drawDialogs`
## after the view inside `layout`. Started with `--ellipse-dialog=...`,
## `run` shows that one dialog in a window of its own instead of the app,
## and exits when it closes.

import clay
import ellipse/logger
import ellipse/platform/platform
import ellipse/platform/renderer
import ./ui
import ./widgets
import ./debug
import ./dialogs

export clay, logger, platform, renderer, ui, widgets, debug, dialogs

type
  AppFn* = proc () {.closure, raises.}

  App* = object
    window*: WindowConfig      ## title, size, or a docked layer-shell bar
    debugMode*: bool = true    ## F1 toggles the debug overlay
    log*: bool = true          ## install the standard stdout logger
    prepare*: nil AppFn        ## first, in every process (dialogs too)
    setup*: nil AppFn          ## once, after `bootup` (main process only)
    input*: nil InputHook      ## every frame, inside `updateUI`
    before*: nil AppFn         ## every frame, before the layout pass
    view*: nil AppFn           ## every frame, inside `layout`
    after*: nil AppFn          ## every frame, after the layout pass

var current: App

proc frame*() {.raises.} =
  ## One update pass of the launched app: input, hooks, layout. The loop
  ## runs this every paced frame; a `script` drives it by hand.
  updateUI()
  updateDialogs()
  let before = current.before
  if before != nil:
    before()
  let view = current.view
  layout:
    if view != nil:
      view()
    drawDialogs()
  let after = current.after
  if after != nil:
    after()

proc render() {.raises.} =
  drawCommands()

proc launch*(app: App) {.raises.} =
  ## Open the window and wire the app in without entering the loop: the
  ## logger, `prepare`, `bootup`, the debug overlay, the input hook, then
  ## `setup`.
  current = app
  if app.log:
    addHandler initStandardLogger()
  let prepare = app.prepare
  if prepare != nil:
    prepare()
  bootup(app.window)
  if app.debugMode:
    installDebugMode()
  let input = app.input
  if input != nil:
    onInputFrame(input)
  let setup = app.setup
  if setup != nil:
    setup()

proc runDialogProcess(app: App) {.raises.} =
  ## This process shows one dialog for the app that started it: the app's
  ## `prepare` (which defines the dialogs), then a window fitted to the
  ## dialog, until it answers. Logs go to stderr -- stdout carries the
  ## answer back.
  if app.log:
    addHandler initStandardLogger(toStderr = true)
  let prepare = app.prepare
  if prepare != nil:
    prepare()
  if not startDialogProcess():
    return
  current = App(view: dialogProcessView, after: dialogProcessAfter)
  bootup(dialogProcessWindow())
  if app.debugMode:
    installDebugMode()
  start(frame, render)
  endDialogProcess()

proc run*(app: App; script: nil AppFn = nil) =
  ## `launch` the app and hand it to the paced loop until the window
  ## closes. With a `script` the loop is skipped and the script runs
  ## instead, driving `frame` itself -- the headless screenshot/test seam
  ## (`SDL_VIDEODRIVER=offscreen`). Startup errors end the program quietly,
  ## like every hand-written `main` before this did.
  try:
    if isDialogProcess():
      runDialogProcess(app)
      return
    launch(app)
    if script != nil:
      script()
    else:
      start(frame, render)
  except ErrorCode:
    discard
  shutdownDialogs()
