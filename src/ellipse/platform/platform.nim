{.passL: "-lSDL3".}

import std/[strutils]

import ../logger

const
  Audio = 0x00000010'u32
  Video = 0x00000020'u32
  Joystick = 0x00000200'u32
  Haptic = 0x00001000'u32
  GamePad = 0x00002000'u32
  Events = 0x00004000'u32
  Sensor = 0x00008000'u32
  Camera = 0x00010000'u32

const
  WindowFullscreen   = 0x00000001'u32
  WindowOpenGL       = 0x00000002'u32
  WindowShown        = 0x00000004'u32
  WindowHidden       = 0x00000008'u32
  WindowBorderless   = 0x00000010'u32
  WindowResizable    = 0x00000020'u32
  WindowMinimized    = 0x00000080'u32
  WindowMaximized    = 0x00000040'u32
  WindowMouseGrabbed = 0x00000100'u32
  WindowInputFocus   = 0x00000200'u32
  WindowMouseFocus   = 0x00000400'u32
  WindowForeign      = 0x00000800'u32
  WindowAllowHighDPI = 0x00002000'u32
  WindowMouseCapture = 0x00004000'u32

type
  SDL_Window {.importc: "SDL_Window", header: "<SDL3/SDL.h>".} = object
  SDL_Renderer {.importc: "SDL_Renderer", header: "<SDL3/SDL.h>".} = object

proc SDL_Init(flags: uint32): bool {.importc: "SDL_Init", header: "<SDL3/SDL.h>".}
proc SDL_GetError(): cstring {.importc: "SDL_GetError", header: "<SDL3/SDL.h>".}
proc SDL_SetAppMetadata(appname, appversion, appidentifier: cstring): bool {.importc: "SDL_SetAppMetadata", header: "<SDL3/SDL.h>".}
proc SDL_CreateWindowAndRenderer(title: cstring; width, height: int32; flags: uint32; window: ptr ptr SDL_Window; renderer: ptr ptr SDL_Renderer): bool {.importc: "SDL_CreateWindowAndRenderer", header: "<SDL3/SDL.h>".}
proc SDL_DestroyWindow(win: ptr SDL_Window) {.importc: "SDL_DestroyWindow", header: "<SDL3/SDL.h>".}
proc SDL_DestroyRenderer(ren: ptr SDL_Renderer) {.importc: "SDL_DestroyRenderer", header: "<SDL3/SDL.h>".}

type
  Window* = object
    raw: ptr SDL_Window

proc `=destroy`*(window: var Window) =
  if window.raw == nil:
    return
  SDL_DestroyWindow(window.raw)
  window.raw = nil

proc `=copy`(dest: var Window, source: Window) {.error.}

type
  Renderer* = object
    raw: ptr SDL_Renderer

proc `=destroy`*(renderer: var Renderer) =
  if renderer.raw == nil:
    return
  SDL_DestroyRenderer(renderer.raw)
  renderer.raw = nil

proc `=copy`(dest: var Renderer, source: Renderer) {.error.}

type
  PlatformApplication* = object
    window: Window
    renderer: Renderer

proc `=destroy`(app: var PlatformApplication) =
  `=destroy`(app.renderer)
  `=destroy`(app.window)

proc sdlHandle(ok: bool, id: string) {.raises.} =
  if not ok:
    let cstr = SDL_GetError()
    let detail =
      if cstr.isNil: ""
      else: fromCString(cstr)
    error [id, " failed: ", detail]
    raise Failure

var activeApp: PlatformApplication

proc initialize*() {.raises.} =
  activeApp = PlatformApplication()

  var an = "ellipse"
  var av = "0.1.0"
  var aid = "org.ellipse.platform"

  sdlHandle(SDL_SetAppMetadata(an.toCString, av.toCString, aid.toCString), "SDL_SetAppMetadata()")
  sdlHandle(SDL_Init(Video or Audio), "SDL_Init()")
  sdlHandle(SDL_CreateWindowAndRenderer("ellipse/renderer", 1280, 720, WindowResizable, addr activeApp.window.raw, addr activeApp.renderer.raw), "SDL_CreateWindowAndRenderer()")
