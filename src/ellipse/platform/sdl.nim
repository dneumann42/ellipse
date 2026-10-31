import std/[os, strutils]

import sdl3, sdl3_ttf, sdl3_image, chroma, errors, gpu, display
export chroma
export gpu except Texture
export display except Fd

# Interface over sdl3, allowing replacement and keeping external dependencies localized.

type
  DisplayMode* = enum
    ## Where an application's window comes from.
    DisplayLocal
      ## The app opens and owns its own window (the default).
    DisplayAttached
      ## Development mode: another process -- the display server, see
      ## `platform/display` -- owns the on-screen window. This app draws as
      ## it always does, into a hidden window of its own, and mirrors every
      ## finished frame to the server over a socket; input comes back the
      ## other way. The game loop can be killed and restarted while the
      ## window stays up -- the seam hot-loading builds on.

  App* = object
    window: Window
    renderer: Renderer
    device: Device
    width*, height*: int
    mode*: DisplayMode = DisplayLocal
    display: DisplayServer ## the connection while attached; nil when local

  AppConfig* = object
    appname*, appversion*: string
    width* = 1280
    height* = 720
    displayMode*: DisplayMode = DisplayLocal

  Font* = object
    data*: sdl3_ttf.Font
    size*: float32
    ascent*, descent*, lineHeight*: int

  Texture* = object
    data*: sdl3.Texture
    width*, height*: int

  ResourceLoader* = ref object
    renderer: Renderer

proc loadTexture*(res: ResourceLoader, path: string): Texture =
  result = Texture()
  result.data = sdl3_image.loadTexture(res.renderer, path)

proc renderClear*(app: App, clearColor: chroma.Color) =
  let c = clearColor.to(ColorRGBA)
  checkSdl setRenderDrawColor(app.renderer, c.r, c.g, c.b, c.a), "Failed to set draw color"
  checkSdl renderClear(app.renderer), "Failed to clear renderer"

proc render*(app: App) =
  checkSdl renderPresent(app.renderer), "Failed to present renderer"

proc displayWanted(envKey, flag: string): bool =
  let e = getEnv(envKey)
  if e.len > 0 and e != "0" and e != "false" and e != "no":
    return true
  for i in 1 .. paramCount():
    if paramStr(i) == flag:
      return true
  false

var attachedFlag = false

proc displayAttachedRequested*(): bool =
  ## `--display-attach` in the command line or `ELLIPSE_DISPLAY_ATTACH=1`:
  ## run the game loop against a display server's window instead of opening
  ## one of our own. The flag is remembered here because `ellipse.nim` reads
  ## it before `createApplication` runs; `served` apps reach it through the
  ## environment as well.
  if displayWanted("ELLIPSE_DISPLAY_ATTACH", "--display-attach"):
    attachedFlag = true
  attachedFlag

proc displayServerRequested*(): bool =
  ## `--display-serve` / `ELLIPSE_DISPLAY_SERVE=1`: this run is the display
  ## server -- open the window, answer attaches, never enter the game loop.
  displayWanted("ELLIPSE_DISPLAY_SERVE", "--display-serve")

proc initApp*(cfg: AppConfig): App =
  result.width = cfg.width
  result.height = cfg.height
  if cfg.displayMode == DisplayAttached:
    # Development mode: mirror frames to the server's window (see
    # `platform/display`). A fresh attach starts from that side: ask the
    # server for its size and draw at it; otherwise keep the configured one.
    var disp = connectDisplay()
    if disp.isNil and ensureDisplayServer():
      # nothing was serving: raise the dev window from this game's own image
      # (its `start` honours `--display-serve`) and dial the fresh server
      disp = connectDisplay()
    if disp.isNil:
      raise EllipseError.newException(
        "no ellipse display server on " & displaySocketPath() &
        "; start one with `make run_display`, or pass --display-serve to any" &
        " ellipse game, or drop attached mode")
    if not disp.handshake(cfg.appname):
      closeDisplay(disp)
      raise EllipseError.newException("display server refused the handshake")
    result.mode = DisplayAttached
    result.display = disp
    let size = disp.pixelSize()
    if size.w > 0 and size.h > 0:
      result.width = size.w.int
      result.height = size.h.int
    # The private canvas: a hidden window, so the artist gets a real swapchain
    # to render into and an event queue to receive the forwarded input on,
    # while every pixel that matters travels to the server each frame.
    result.window = createWindow(cstring(cfg.appname),
                                 result.width.cint,
                                 result.height.cint,
                                 WINDOW_RESIZABLE or WINDOW_HIGH_PIXEL_DENSITY or
                                 WINDOW_HIDDEN)
    if result.window.isNil:
      raiseSdlError("Failed to create the attached app's canvas window")
    # Forwarded input is re-stamped with this id, so the pump treats it as
    # coming from the window it knows.
    disp.setWindowId(result.window.getWindowID())
    result.renderer = createRenderer(result.window, cstring("gpu"))
    if result.renderer.isNil:
      raiseSdlError("Failed to create the attached app's renderer")
    checkSdl setRenderVSync(result.renderer, 0), "Failed to disable vsync"
    result.device = initDevice(result.renderer)
    return
  result.window = createWindow(cstring(cfg.appname), 
                               cfg.width.cint, 
                               cfg.height.cint, 
                               WINDOW_RESIZABLE or WINDOW_HIGH_PIXEL_DENSITY)
  if result.window.isNil:
    raiseSdlError("Failed to create window")
  checkSdl showWindow(result.window), "Failed to show window"
  result.renderer = createRenderer(result.window, cstring("gpu"))
  if result.renderer.isNil:
    raiseSdlError("Failed to create renderer")
  checkSdl setRenderVSync(result.renderer, 0), "Failed to disable vsync"
  result.device = initDevice(result.renderer)

proc gpuDevice*(app: App): Device =
  app.device

func designAspect*(app: App): float32 =
  ## Aspect ratio the application was configured with; used as the
  ## letterbox reference so resizing never crops or distorts content.
  if app.height > 0: app.width.float32 / app.height.float32 else: 0

proc gpuSwapchainFormat*(app: App): TextureFormat =
  swapchainFormat(app.device, app.window)

proc gpuFrame*(app: var App): GpuFrame =
  ## Local: acquire the window's swapchain. Attached: ask the *server* for a
  ## frame first -- its queue holds the forwarded input, and waiting out its
  ## tick paces this app to the display like a present would -- then acquire
  ## our own hidden one to draw into. The reply also carries the server's
  ## live size; when it changed, resize the canvas before drawing.
  if app.mode == DisplayAttached:
    let served = beginServedFrame(app.display)
    if served.resized:
      discard setWindowSize(app.window, served.width.cint, served.height.cint)
      app.width = served.width.int
      app.height = served.height.int
    beginFrame(app.device, app.window)
  else:
    beginFrame(app.device, app.window)

proc mirrorPresented*(app: var App, frame: GpuFrame) =
  ## An attached frame is finished: copy it out and hand the picture to the
  ## server. `readbackPixels` submits and drains the frame itself, so the
  ## caller must not end it again. A local app ends its frame normally here;
  ## a dead connection means the server is gone: present locally instead of
  ## stalling, so the game stays playable while its window's partner died.
  if app.mode != DisplayAttached:
    frame.endFrame()
    return
  if app.display == nil or app.display.gone:
    frame.endFrame()
    return
  let pixels = readbackPixels(frame)
  if pixels.len > 0:
    discard mirrorFrame(app.display, pixels, frame.width, frame.height)

proc servedQuitAsked*(app: var App): bool =
  ## Attached: the display server (or the person at its window) asked this
  ## app to quit, or the connection died. Local apps never see one. Whatever
  ## arrived since the last look -- input, ticks, quits -- is drained into
  ## this process's queue first, so nothing is missed between frames.
  if app.mode != DisplayAttached or app.display == nil:
    return false
  for ev in pollInput(app.display):
    if ev.kind == evQuit:
      return true
  app.display.gone

proc `=copy`*(app: var App, source: App) {.error.}
proc `=destroy`*(app: var App) =
  app.device.forget() # resources outliving the app must not touch its device
  if not app.renderer.isNil:
    destroyRenderer(app.renderer)
    app.renderer = nil
  if not app.window.isNil:
    destroyWindow(app.window)
    app.window = nil
  if app.display != nil:
    # Whatever owns the window now, this process's part in it ends here.
    closeDisplay(app.display)
    app.display = nil

proc configureVideoDriver*() =
  if (
      getEnv("SDL_VIDEO_DRIVER").len == 0 and getEnv("SDL_VIDEODRIVER").len == 0 and 
      getEnv("WAYLAND_DISPLAY").len > 0
  ):
    discard setHint("SDL_VIDEO_DRIVER", "wayland")

proc initialize*() =
  if not sdl3.init(INIT_VIDEO or INIT_AUDIO or INIT_GAMEPAD):
    raiseSdlError("Failed to initialize SDL")
  if not sdl3_ttf.init():
    raiseSdlError("Failed to initialize SDL_ttf")

proc deinitialize*() =
  sdl3_ttf.quit()
  sdl3.quit()

import ./platform except Window, Renderer

proc pixelSize*(app: App): tuple[width, height: int] =
  ## The window's drawable size in device pixels -- the shape an offscreen
  ## UI picture must match to cover it exactly. Falls back to the logical
  ## size before the window has one.
  var w, h: cint
  if getWindowSizeInPixels(app.window, w, h) and w > 0 and h > 0:
    (w.int, h.int)
  else:
    (app.width, app.height)

proc processEvents*(running: var bool): void =
  ## Drain SDL's event queue once through the UI platform (see
  ## `ellipse/platform/platform`): widgets need the pointer, keys, wheel
  ## and close requests, and the polled keyboard state the game reads is
  ## refreshed by the same pump. SDL's queue has exactly one consumer --
  ## pumping it here would starve the other -- so this loop only turns
  ## the quit signal into `running = false`.
  platform.pumpEvents()
  if platform.quitAsked():
    running = false
