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
proc processEvents*(running: var bool): void =
  var sdlEvent: sdl3.Event
  while pollEvent(sdlEvent):
    if sdlEvent.`type` == EVENT_QUIT:
      running = false
      return
