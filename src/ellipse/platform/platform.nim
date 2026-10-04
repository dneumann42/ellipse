{.passL: "-lSDL3 -no-pie".}

import std/[monotimes, strutils]

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

const
  EventQuit          = 0x00000100'u32
  EventTerminating   = 0x00000101'u32
  EventWindowShown   = 0x00000202'u32
  EventWindowHidden  = 0x00000203'u32
  EventWindowResized = 0x00000206'u32
  EventWindowPixelResized = 0x00000207'u32
  EventWindowCloseRequested = 0x00000210'u32
  EventKeyDown       = 0x00000300'u32
  EventKeyUp         = 0x00000301'u32
  EventTextInput     = 0x00000303'u32
  EventMouseMotion   = 0x00000400'u32
  EventMouseButtonDown = 0x00000401'u32
  EventMouseButtonUp = 0x00000402'u32
  EventMouseWheel    = 0x00000403'u32

const
  ButtonLeft = 1'u8          ## SDL_BUTTON_LEFT
  ButtonLeftMask = 1'u32     ## SDL_BUTTON_LMASK, the `state` bit for it

type
  SDL_Window {.importc: "SDL_Window", header: "<SDL3/SDL.h>".} = object
  SDL_Renderer* {.importc: "SDL_Renderer", header: "<SDL3/SDL.h>".} = object
  SDL_Event {.importc: "SDL_Event", header: "<SDL3/SDL.h>".} = object

  SDL_CommonEvent = object
    typ: uint32
    reserved: uint32
    timestamp: uint64

  SDL_WindowEvent = object
    typ: uint32
    reserved: uint32
    timestamp: uint64
    windowId: uint32
    data1: int32
    data2: int32

  SDL_KeyboardEvent = object
    typ: uint32
    reserved: uint32
    timestamp: uint64
    windowId: uint32
    which: uint32
    scancode: int32
    key: int32
    modifiers: int32
    raw: uint16
    down: bool
    repeat: bool

  SDL_TextInputEvent = object
    typ: uint32
    reserved: uint32
    timestamp: uint64
    windowId: uint32
    text: cstring

  SDL_MouseMotionEvent = object
    typ: uint32
    reserved: uint32
    timestamp: uint64
    windowId: uint32
    which: uint32
    state: uint32
    x: float32
    y: float32
    xrel: float32
    yrel: float32

  SDL_MouseButtonEvent = object
    typ: uint32
    reserved: uint32
    timestamp: uint64
    windowId: uint32
    which: uint32
    button: uint8
    down: bool
    clicks: uint8
    padding: uint8
    x: float32
    y: float32

  SDL_MouseWheelEvent = object
    typ: uint32
    reserved: uint32
    timestamp: uint64
    windowId: uint32
    which: uint32
    x: float32
    y: float32
    direction: int32
    mouseX: float32
    mouseY: float32
    integerX: int32
    integerY: int32

proc SDL_Init(flags: uint32): bool {.importc: "SDL_Init", header: "<SDL3/SDL.h>".}
proc SDL_GetError(): cstring {.importc: "SDL_GetError", header: "<SDL3/SDL.h>".}
proc SDL_SetAppMetadata(appname, appversion, appidentifier: cstring): bool {.importc: "SDL_SetAppMetadata", header: "<SDL3/SDL.h>".}
proc SDL_CreateWindowAndRenderer(title: cstring; width, height: int32; flags: uint32; window: ptr ptr SDL_Window; renderer: ptr ptr SDL_Renderer): bool {.importc: "SDL_CreateWindowAndRenderer", header: "<SDL3/SDL.h>".}
proc SDL_DestroyWindow(win: ptr SDL_Window) {.importc: "SDL_DestroyWindow", header: "<SDL3/SDL.h>".}
proc SDL_DestroyRenderer(ren: ptr SDL_Renderer) {.importc: "SDL_DestroyRenderer", header: "<SDL3/SDL.h>".}
proc SDL_PollEvent(event: ptr SDL_Event): bool {.importc: "SDL_PollEvent", header: "<SDL3/SDL.h>".}
proc SDL_Delay(ms: uint32) {.importc: "SDL_Delay", header: "<SDL3/SDL.h>".}
proc SDL_SetRenderDrawColor(ren: ptr SDL_Renderer; r, g, b, a: uint8): bool {.importc: "SDL_SetRenderDrawColor", header: "<SDL3/SDL.h>".}
proc SDL_RenderClear(ren: ptr SDL_Renderer): bool {.importc: "SDL_RenderClear", header: "<SDL3/SDL.h>".}
proc SDL_RenderPresent(ren: ptr SDL_Renderer): bool {.importc: "SDL_RenderPresent", header: "<SDL3/SDL.h>".}

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
  PointerState* = object
    ## Primary-pointer position (window pixels) and left-button state, as
    ## last seen by `pumpEvents`. The UI's layout root is the window, so the
    ## position is also clay-relative.
    x*, y*: float32
    down*: bool

type
  PlatformApplication* = object
    window: Window
    renderer: Renderer
    pointer: PointerState
    width, height: float32
    running: bool

proc `=destroy`(app: var PlatformApplication) =
  `=destroy`(app.renderer)
  `=destroy`(app.window)

proc sdlHandle(ok: bool, id: string) {.raises.} =
  if not ok:
    let cstr = SDL_GetError()
    let detail =
      if cstr.isNil: ""
      else: fromCString(cstr)
    error id, " failed: ", detail
    raise Failure

var activeApp: PlatformApplication

proc sdlRenderer*(): ptr SDL_Renderer =
  ## The live SDL_Renderer handle, for drawing modules (see
  ## `ellipse/platform/renderer`). Only valid inside the main loop.
  activeApp.renderer.raw

type
  FrameFn* = proc() {.closure, raises.}

proc initialize*() {.raises.} =
  activeApp = PlatformApplication()

  var an = "ellipse"
  var av = "0.1.0"
  var aid = "org.ellipse.platform"

  sdlHandle(SDL_SetAppMetadata(an.toCString, av.toCString, aid.toCString), "SDL_SetAppMetadata()")
  sdlHandle(SDL_Init(Video or Audio), "SDL_Init()")
  sdlHandle(SDL_CreateWindowAndRenderer("ellipse/renderer", 1280, 720, WindowResizable, addr activeApp.window.raw, addr activeApp.renderer.raw), "SDL_CreateWindowAndRenderer()")
  activeApp.width = 1280.0
  activeApp.height = 720.0

const
  TicksPerSecond = 60'i64
  NanosPerSecond = 1_000_000_000'i64
  SpinWindowNs = 1_000_000'i64

type
  GameEngine = object
    epoch: int64
    debugStart: int64
    simulatedTick: int64
    renderFrame: int64
    frames: int64
    updates: int64
    requiredTicks: int64

proc tickDeadline(epoch: int64; tick: int64): int64 =
  epoch + (tick * NanosPerSecond + TicksPerSecond - 1) div TicksPerSecond

proc currentTick(engine: GameEngine): int64 =
  (getMonoTime().ticks - engine.epoch) * TicksPerSecond div NanosPerSecond

proc waitUntil(deadline: int64) =
  let now = getMonoTime().ticks
  if deadline > now + SpinWindowNs:
    SDL_Delay(uint32((deadline - SpinWindowNs - now) div 1_000_000'i64))
  while getMonoTime().ticks < deadline:
    discard

proc beginFrame(engine: var GameEngine) =
  waitUntil(tickDeadline(engine.epoch, engine.renderFrame))
  engine.requiredTicks = currentTick(engine)

proc pumpEvents(app: var PlatformApplication) =
  var event = default(SDL_Event)
  while SDL_PollEvent(addr event):
    let kind = cast[ptr SDL_CommonEvent](addr event)[].typ
    if kind == EventQuit or kind == EventTerminating or kind == EventWindowCloseRequested:
      app.running = false
    elif kind == EventWindowPixelResized:
      # Track the live window size so the UI can re-layout the moment the
      # window is resized. `data1`/`data2` carry the new drawable size in
      # renderer pixels -- the space we draw and report pointer positions in.
      let e = cast[ptr SDL_WindowEvent](addr event)[]
      if e.data1 > 0 and e.data2 > 0:
        app.width = float32(e.data1)
        app.height = float32(e.data2)
    elif kind == EventMouseMotion:
      let e = cast[ptr SDL_MouseMotionEvent](addr event)[]
      app.pointer.x = e.x
      app.pointer.y = e.y
      app.pointer.down = (e.state and ButtonLeftMask) != 0
    elif kind == EventMouseButtonDown:
      let e = cast[ptr SDL_MouseButtonEvent](addr event)[]
      if e.button == ButtonLeft:
        app.pointer.down = true
    elif kind == EventMouseButtonUp:
      let e = cast[ptr SDL_MouseButtonEvent](addr event)[]
      if e.button == ButtonLeft:
        app.pointer.down = false

proc pointerState*(): PointerState =
  ## The pointer as of the most recent event pump; feed it to
  ## `clay.setPointerState` once per update tick.
  activeApp.pointer

proc windowPixelSize*(): tuple[width, height: float32] =
  ## The window's drawable size in renderer pixels, as of the most recent
  ## event pump. Feed it to `clay.setLayoutDimensions` each update tick so
  ## the layout tracks live window resizes.
  (activeApp.width, activeApp.height)

proc drawFrame(app: var PlatformApplication; render: FrameFn) {.raises.} =
  sdlHandle(SDL_SetRenderDrawColor(app.renderer.raw, 0, 0, 0, 255), "SDL_SetRenderDrawColor()")
  sdlHandle(SDL_RenderClear(app.renderer.raw), "SDL_RenderClear()")
  render()
  sdlHandle(SDL_RenderPresent(app.renderer.raw), "SDL_RenderPresent()")

proc tick(engine: var GameEngine; update: FrameFn) {.raises.} =
  while engine.simulatedTick < engine.requiredTicks:
    update()
    inc engine.simulatedTick
    inc engine.updates

proc endFrame(engine: var GameEngine) =
  inc engine.renderFrame
  inc engine.frames
  let wallTick = currentTick(engine) + 1
  if wallTick > engine.renderFrame:
    engine.renderFrame = wallTick

proc reportFPS(engine: var GameEngine) =
  let now = getMonoTime().ticks
  let elapsed = float64(now - engine.debugStart) / float64(NanosPerSecond)
  if elapsed >= 1.0:
    let fps = float64(engine.frames) / elapsed
    let ups = float64(engine.updates) / elapsed
    info "FPS: ", $fps, " | UPS: ", $ups
    engine.frames = 0
    engine.updates = 0
    engine.debugStart = now

proc start*(update: FrameFn; render: FrameFn) {.raises.} =
  var engine = GameEngine()
  engine.epoch = getMonoTime().ticks
  engine.debugStart = engine.epoch

  activeApp.running = true
  while activeApp.running:
    pumpEvents(activeApp)
    beginFrame(engine)
    tick(engine, update)
    drawFrame(activeApp, render)
    endFrame(engine)
    reportFPS(engine)
