## The app shell: logging, the F1 debug overlay, the per-frame
## `updateUI` + `layout` pass, the render and the paced loop, behind one
## `run`. See `documentation/nim-tutorial.md` §12 (The app shell and its
## hooks) and `documentation/README.md` for the two quick starts.

import std/[envvars, syncio, os, tempfiles, base64, strutils]
when defined(posix):
  import std/posix

import clay
import ellipse/hotload
export hotload
import ellipse/logger
import ellipse/platform/display
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
    hotApp*: bool = false      ## watch src/, rebuild on save, re-exec over
                               ## this process (whole-app hot-loading; the
                               ## display server's window survives it)
    buildCommand*: string = "" ## what `hotApp` runs to rebuild (default
                               ## "make build")
    prepare*: AppFn        ## first, in every process (dialogs too)
    setup*: AppFn          ## once, after `bootup` (main process only)
    beforeReload*: proc (): string {.closure.}
      ## Called before whole-process re-exec. Return opaque state bytes.
    afterReload*: proc (state: string) {.closure.}
      ## Called after setup, before the first frame, only following re-exec.
    input*: InputHook      ## every frame, inside `updateUI`
    before*: AppFn         ## every frame, before the layout pass
    view*: AppFn           ## every frame, inside `layout`
    after*: AppFn          ## every frame, after the layout pass

var current: App

const reloadStateEnv = "ELLIPSE_RELOAD_STATE"
const reloadPidEnv = "ELLIPSE_RELOAD_PID"
const reloadEnvelope = "ellipse-ui-reload:1\n"

proc restoreReloadState(app: App) =
  let path = getEnv(reloadStateEnv)
  let owner = getEnv(reloadPidEnv)
  delEnv(reloadStateEnv)
  delEnv(reloadPidEnv)
  # exec keeps the PID. Dialogs and other child processes must not consume
  # their parent's snapshot if they inherit the environment.
  if path.len == 0 or owner != $getCurrentProcessId():
    return
  try:
    let bytes = readFile(path)
    if bytes.startsWith(reloadEnvelope):
      let saved = parseJson(bytes[reloadEnvelope.len .. ^1])
      if app.afterReload != nil and saved["application"].kind != JNull:
        app.afterReload(base64.decode(saved["application"].getStr()))
      restoreUiState(saved["ui"])
    elif app.afterReload != nil:
      # Accept snapshots from a running build predating the UI envelope.
      app.afterReload(bytes)
  except CatchableError as exc:
    raise newException(IOError, "could not restore reload state from " &
                       path & ": " & exc.msg)
  removeFile(path)


proc frame*()  =
  ## One update pass of the launched app: input, hooks, layout. The loop
  ## runs this every paced frame; a `script` drives it by hand.
  pumpProjectWakes()
  syncAttachedSurface()
  updateUI()
  updateDialogs()
  checkProjectSettled()
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
  if app.hotApp:
    # whole-app reload: watch src/, rebuild on a save, become the new binary
    # (see `ellipse/hotload.startProjectWatching`); nothing is rebuilt or
    # swapped unless this process was asked to watch at all
    startProjectWatching(app.buildCommand)
  else:
    startHotLoading()
  if app.debugMode:
    installDebugMode()
  let input = app.input
  if input != nil:
    onInputFrame(input)
  let setup = app.setup
  if setup != nil:
    setup()
  restoreReloadState(app)

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

proc relaunch*(): bool =
  ## Replace this process with a freshly built copy of itself, in place:
  ## same pid, new image, and (attached or not) the window is simply taken
  ## over again. The whole-app hot loader calls it after a successful
  ## rebuild; an app can also bind it to a key. A successful call never
  ## returns -- false means the restart could not happen and the old build
  ## keeps serving.
  when defined(posix):
    saveRestartArgs()
    if restartArgs.len == 0 or restartArgs[0].len == 0:
      return false
    var argv = newSeq[cstring](restartArgs.len + 1)
    var held = newSeq[string](restartArgs.len)
    for i in 0 ..< restartArgs.len:
      held[i] = restartArgs[i] & ""   # deep copy, pinned until execv returns:
      argv[i] = held[i].cstring       # a `cstring` is just a pointer
    argv[restartArgs.len] = nil
    var statePath = ""
    try:
      let state = if current.beforeReload != nil: current.beforeReload() else: ""
      let envelope = newJObject()
      envelope["application"] = if current.beforeReload != nil:
        %base64.encode(state) else: newJNull()
      envelope["ui"] = saveUiState()
      let (file, path) = createTempFile("ellipse-reload-", ".bif")
      statePath = path
      try:
        file.write(reloadEnvelope & $envelope)
      finally:
        file.close()
      putEnv(reloadStateEnv, path)
      putEnv(reloadPidEnv, $getCurrentProcessId())
      discard execv(restartArgs[0].cstring, cast[cstringArray](addr argv[0]))
    except CatchableError as exc:
      stderr.writeLine("hot: could not save reload state: " & exc.msg)
    finally:
      # Successful exec never returns. Failed saves/execs leave no marker
      # for a later ordinary launch and no orphaned temporary file.
      delEnv(reloadStateEnv)
      delEnv(reloadPidEnv)
      if statePath.len > 0:
        removeFile(statePath)
    # execv only returns on failure: keep the old build serving
    false


proc run*(app: App; script: AppFn = nil) =
  ## `launch` the app and hand it to the paced loop until the window
  ## closes. With a `script` the loop is skipped and the script runs
  ## instead, driving `frame` itself -- the headless screenshot/test seam
  ## (`SDL_VIDEODRIVER=offscreen`). Startup errors end the program quietly,
  ## like every hand-written `main` before this did. A whole-app reload
  ## that rebuilt successfully ends the loop through `takeRestart`; this is
  ## where the old image becomes the new one (see `relaunch`).
  try:
    if displayServeRequested():
      # `--display-serve`: this run *is* the dev window every attached app
      # mirrors into -- no UI, no loop, it never returns (see
      # `platform/display.serveDisplay`). An attached app raises one from its
      # own image when nothing answers the socket, so `make hot` alone keeps
      # the window through reloads.
      when not defined(windows):
        serveDisplay(app.window.title, app.window.width, app.window.height)
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
  except CatchableError as exc:
    stderr.writeLine("ellipse: " & exc.msg)
    quit(1)
  if takeRestart():
    ## Nothing of this build must survive into the next frame of the user's
    ## session: become the freshly compiled program, in place -- *before* any
    ## shutdown. The display server keeps its window and slot through an
    ## execv; a close-on-exec socket dies with the image quietly, while
    ## teardown code that touches it (or SDL) can fail or hang first. The new
    ## image dials fresh. If the exec fails outright, fall through to the
    ## normal shutdown so the old build keeps serving gracefully.
    stderr.writeLine("hot: restarting application")
    if not relaunch():
      stderr.writeLine("hot: restart failed")
  shutdownDialogs()
  if takeRestart():
    # something killed the loop between the first attempt and here: one last
    # try at becoming the new image before exiting for real
    if not relaunch():
      quit(1)
