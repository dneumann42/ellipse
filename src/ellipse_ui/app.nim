## The app shell: logging, the F1 debug overlay, the per-frame
## `updateUI` + `layout` pass, the render and the paced loop, behind one
## `run`. See `documentation/nim-tutorial.md` §12 (The app shell and its
## hooks) and `documentation/README.md` for the two quick starts.

import std/envvars

import clay
import ellipse/hotload
import ellipse/logger
import ellipse/platform/platform
import ellipse/platform/renderer
import ./ui
import ./widgets
import ./debug
import ./dialogs

export clay, logger, platform, renderer, ui, widgets, debug, dialogs

type
  AppFn* = proc () {.closure.}

  App* = object
    window*: WindowConfig      ## title, size, or a docked layer-shell bar
    debugMode*: bool = true    ## F1 toggles the debug overlay
    log*: bool = true          ## install the standard stdout logger
    prepare*: AppFn        ## first, in every process (dialogs too)
    setup*: AppFn          ## once, after `bootup` (main process only)
    input*: InputHook      ## every frame, inside `updateUI`
    before*: AppFn         ## every frame, before the layout pass
    view*: AppFn           ## every frame, inside `layout`
    after*: AppFn          ## every frame, after the layout pass

var current: App

proc frame*()  =
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

proc render()  =
  drawCommands()

proc launch*(app: App)  =
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
  startHotLoading()
  if app.debugMode:
    installDebugMode()
  let input = app.input
  if input != nil:
    onInputFrame(input)
  let setup = app.setup
  if setup != nil:
    setup()

proc runDialogProcess(app: App)  =
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

proc shotScript(path: string): AppFn =
  ## `ELLIPSE_SCREENSHOT=<path>`: a few frames to settle, the picture saved
  ## as a BMP, then out -- for comparing apps headless
  ## (`SDL_VIDEODRIVER=offscreen`).
  result = proc () {.closure.} =
    for i in 0 ..< 6:
      frame()
    if not saveScreenshot(path, bg = activeTheme.palette.bg):
      discard error("could not write the screenshot ", path)

proc run*(app: App; script: AppFn = nil) =
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
    let shot = getEnv("ELLIPSE_SCREENSHOT")
    if script != nil:
      script()
    elif shot.len > 0:
      shotScript(shot)()
    else:
      start(frame, render)
  except CatchableError:
    discard
  shutdownDialogs()
