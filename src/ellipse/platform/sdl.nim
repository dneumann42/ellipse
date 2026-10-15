import std/[os]

import sdl3

# Interface over sdl3, allowing replacement and keeping external dependencies localized.

type
  App* = object
    window: Window
    renderer: Renderer

  AppConfig* = object
    appname*, appversion*: string
    width* = 1280
    height* = 720

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
