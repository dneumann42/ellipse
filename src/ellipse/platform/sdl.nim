import std/[os]

import sdl3, sdl3_ttf, sdl3_image, chroma, errors, gpu
export chroma
export gpu except Texture

# Interface over sdl3, allowing replacement and keeping external dependencies localized.

type
  App* = object
    window: Window
    renderer: Renderer
    device: Device
    width*, height*: int

  AppConfig* = object
    appname*, appversion*: string
    width* = 1280
    height* = 720

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

proc initApp*(cfg: AppConfig): App =
  result.width = cfg.width
  result.height = cfg.height
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

proc gpuFrame*(app: App): GpuFrame =
  beginFrame(app.device, app.window)

proc `=copy`*(app: var App, source: App) {.error.}
proc `=destroy`*(app: var App) =
  if not app.renderer.isNil:
    destroyRenderer(app.renderer)
    app.renderer = nil
  if not app.window.isNil:
    destroyWindow(app.window)
    app.window = nil

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
