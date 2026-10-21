import ./termmode
export termmode

# SDL3 is linked only when the window backend is built in (see `withSdl`);
# `-d:ellipseNoSdl` builds a terminal-only program with no SDL at all.
when withSdl:
  when defined(windows):
    {.passL: "-lSDL3".}
  elif defined(library):
    # `-no-pie` suits the app's startup layout and would pull crt1.o into
    # a shared-library link (the hot widget libraries); `-shared` alone.
    {.passL: "-lSDL3".}
  else:
    {.passL: "-lSDL3 -no-pie".}

import std/[math, monotimes, strutils, envvars, base64]

import ../logger
import ../failure
import ./pacing
export pacing
import ./layershell
import ./keyevents
export keyevents
import ../terminal/[tty, terminput]
import ./fdwatch
export fdwatch
export layershell

when withSdl:
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
    WindowAlwaysOnTop  = 0x00010000'u32
    WindowMouseCapture = 0x00004000'u32

  const
    EventQuit          = 0x00000100'u32
    EventTerminating   = 0x00000101'u32
    EventWindowShown   = 0x00000202'u32
    EventWindowHidden  = 0x00000203'u32
    EventWindowExposed = 0x00000204'u32
    EventWindowResized = 0x00000206'u32
    EventWindowPixelResized = 0x00000207'u32
    EventWindowMinimized = 0x00000209'u32
    EventWindowRestored = 0x0000020B'u32
    EventWindowMouseLeave = 0x0000020D'u32
    EventWindowFocusGained = 0x0000020E'u32
    EventWindowFocusLost = 0x0000020F'u32
    EventWindowDisplayChanged = 0x00000213'u32
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
    ButtonRight = 3'u8         ## SDL_BUTTON_RIGHT, the 3D views' look key
    ButtonRightMask = 4'u32    ## SDL_BUTTON_RMASK, the `state` bit for it

  const
    ## SDL3 scancodes for the keys the UI edits with (USB HID usage page 0x07).
    ScanEnter = 40'i32
    ScanEscape = 41'i32
    ScanTab = 43'i32
    ScanBackspace = 42'i32
    ScanDelete = 76'i32
    ScanHome = 74'i32
    ScanEnd = 77'i32
    ScanRight = 79'i32
    ScanLeft = 80'i32
    ScanDown = 81'i32
    ScanUp = 82'i32
    ## Keypad Enter: a separate HID usage from the main Enter key; both edit
    ## as `kevEnter`.
    ScanKeypadEnter = 88'i32
    ## PgUp / PgDn: the page motions a text editor scrolls by.
    ScanPageUp = 75'i32
    ScanPageDown = 78'i32
    ## F1..F12: the function row, delivered as `kevF1`..`kevF12`.
    ScanF1 = 58'i32
    ScanF2 = 59'i32
    ScanF3 = 60'i32
    ScanF4 = 61'i32
    ScanF5 = 62'i32
    ScanF6 = 63'i32
    ScanF7 = 64'i32
    ScanF8 = 65'i32
    ScanF9 = 66'i32
    ScanF10 = 67'i32
    ScanF11 = 68'i32
    ScanF12 = 69'i32
    ## Insert, and the digit row 1..9,0 (30..39): with Ctrl/Alt a digit
    ## chord carries its digit whatever the layout prints on the key (the
    ## French row types '&' unshifted).
    ScanInsert = 73'i32
    ScanDigit1 = 30'i32
    ScanDigit0 = 39'i32
    ## The keypad: / * - + (84..87), 1..9 (89..97), 0 (98), . (99). With
    ## NumLock on they type their symbol; off, the digits are the navigation
    ## keys printed under them.
    ScanKPDivide = 84'i32
    ScanKPMultiply = 85'i32
    ScanKPMinus = 86'i32
    ScanKPPlus = 87'i32
    ScanKP1 = 89'i32
    ScanKP9 = 97'i32
    ScanKP0 = 98'i32
    ScanKPPeriod = 99'i32
    ## QWERTY home-row letters, as SDL3 scancodes: A..Z run 4..29, so a
    ## scancode in this range maps to `chr('a' + scancode - 4)`.
    ScanA = 4'i32
    ScanZ = 29'i32
    ## SDL3 keymods: Shift = LSHIFT | RSHIFT, Ctrl = LCTRL | RCTRL,
    ## Alt = LALT | RALT; NumLock, CapsLock and Mode (AltGr, the third
    ## level some layouts type '@', '{' or '|' on).
    ModShift = 0x00000003'i32
    ModCtrl = 0x000000C0'i32
    ModAlt = 0x00000300'i32
    ModNum = 0x00001000'i32
    ModCaps = 0x00002000'i32
    ModMode = 0x00004000'i32

  type
    SDL_Window {.importc: "SDL_Window", header: "<SDL3/SDL.h>".} = object
    SDL_Renderer* {.importc: "SDL_Renderer", header: "<SDL3/SDL.h>".} = object
    SDL_Event {.importc: "SDL_Event", header: "<SDL3/SDL.h>".} = object
    SDL_DisplayMode {.importc: "SDL_DisplayMode", header: "<SDL3/SDL.h>".} = object
      refresh_rate: float32
    SDL_IRect {.importc: "SDL_Rect", header: "<SDL3/SDL.h>".} = object
      x, y, w, h: int32

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
      modifiers: uint16   ## SDL3's SDL_Keymod is Uint16; `raw` is the *next*
      raw: uint16         ## two-byte field, then the one-byte `down`/`repeat`
      down: bool          ## flags. A wider `modifiers` would shift `down` past
      repeat: bool        ## the struct, into union padding that is always 0.

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
      clicks: uint8       ## SDL3's click counter: 1 = single, 2 = double
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
  when not defined(windows):
    proc setenv(name, value: cstring; overwrite: cint): cint {.
      importc: "setenv", header: "<stdlib.h>".}
  proc SDL_SetAppMetadata(appname, appversion, appidentifier: cstring): bool {.importc: "SDL_SetAppMetadata", header: "<SDL3/SDL.h>".}
  proc SDL_CreateWindowAndRenderer(title: cstring; width, height: int32; flags: uint32; window: ptr ptr SDL_Window; renderer: ptr ptr SDL_Renderer): bool {.importc: "SDL_CreateWindowAndRenderer", header: "<SDL3/SDL.h>".}
  proc SDL_StartTextInput(win: ptr SDL_Window): bool {.importc: "SDL_StartTextInput", header: "<SDL3/SDL.h>".}
  proc SDL_StopTextInput(win: ptr SDL_Window): bool {.importc: "SDL_StopTextInput", header: "<SDL3/SDL.h>".}
  proc SDL_GetCurrentVideoDriver(): cstring {.importc: "SDL_GetCurrentVideoDriver", header: "<SDL3/SDL.h>".}
  proc SDL_GetMouseFocus(): ptr SDL_Window {.
    importc: "SDL_GetMouseFocus", header: "<SDL3/SDL.h>".}
  proc SDL_SetWindowRelativeMouseMode(win: ptr SDL_Window; enabled: bool): bool {.
    importc: "SDL_SetWindowRelativeMouseMode", header: "<SDL3/SDL.h>".}
  proc SDL_SetWindowMouseGrab(win: ptr SDL_Window; enabled: bool): bool {.
    importc: "SDL_SetWindowMouseGrab", header: "<SDL3/SDL.h>".}
  proc SDL_WarpMouseInWindow(win: ptr SDL_Window; x, y: float32) {.
    importc: "SDL_WarpMouseInWindow", header: "<SDL3/SDL.h>".}
  proc SDL_HideCursor(): bool {.importc: "SDL_HideCursor", header: "<SDL3/SDL.h>".}
  proc SDL_ShowCursor(): bool {.importc: "SDL_ShowCursor", header: "<SDL3/SDL.h>".}
  proc SDL_SetWindowTitle(win: ptr SDL_Window; title: cstring): bool {.
    importc: "SDL_SetWindowTitle", header: "<SDL3/SDL.h>".}
  proc SDL_GetClipboardText(): cstring {.
    importc: "SDL_GetClipboardText", header: "<SDL3/SDL.h>".}
  proc SDL_SetClipboardText(text: cstring): bool {.
    importc: "SDL_SetClipboardText", header: "<SDL3/SDL.h>".}
  proc SDL_free(mem: pointer) {.importc: "SDL_free", header: "<SDL3/SDL.h>".}
  proc SDL_GetModState(): uint32 {.importc: "SDL_GetModState", header: "<SDL3/SDL.h>".}
  proc SDL_GetKeyFromScancode(scancode, modstate: int32; key_event: bool): int32 {.
    importc: "SDL_GetKeyFromScancode", header: "<SDL3/SDL.h>".}
  proc SDL_DestroyWindow(win: ptr SDL_Window) {.importc: "SDL_DestroyWindow", header: "<SDL3/SDL.h>".}
  proc SDL_DestroyRenderer(ren: ptr SDL_Renderer) {.importc: "SDL_DestroyRenderer", header: "<SDL3/SDL.h>".}
  type
    SDL_Surface {.importc: "SDL_Surface", header: "<SDL3/SDL.h>".} = object
      ## Opaque here: only SDL's calls touch its contents.
  proc SDL_CreateSurface(w, h: int32; format: uint32): ptr SDL_Surface {.
    importc: "SDL_CreateSurface", header: "<SDL3/SDL.h>".}
  proc SDL_DestroySurface(surf: ptr SDL_Surface) {.
    importc: "SDL_DestroySurface", header: "<SDL3/SDL.h>".}
  proc SDL_CreateSoftwareRenderer(surf: ptr SDL_Surface): ptr SDL_Renderer {.
    importc: "SDL_CreateSoftwareRenderer", header: "<SDL3/SDL.h>".}
  proc SDL_PollEvent(event: ptr SDL_Event): bool {.importc: "SDL_PollEvent", header: "<SDL3/SDL.h>".}
  proc SDL_PushEvent(event: ptr SDL_Event): bool {.importc: "SDL_PushEvent", header: "<SDL3/SDL.h>".}
  proc SDL_CreateProperties(): uint32 {.importc: "SDL_CreateProperties", header: "<SDL3/SDL.h>".}
  proc SDL_DestroyProperties(props: uint32) {.importc: "SDL_DestroyProperties", header: "<SDL3/SDL.h>".}
  proc SDL_SetBooleanProperty(props: uint32; name: cstring; value: bool): bool {.
    importc: "SDL_SetBooleanProperty", header: "<SDL3/SDL.h>".}
  proc SDL_SetNumberProperty(props: uint32; name: cstring; value: int64): bool {.
    importc: "SDL_SetNumberProperty", header: "<SDL3/SDL.h>".}
  proc SDL_SetStringProperty(props: uint32; name: cstring; value: cstring): bool {.
    importc: "SDL_SetStringProperty", header: "<SDL3/SDL.h>".}
  proc SDL_GetPointerProperty(props: uint32; name: cstring; default: nil pointer): nil pointer {.
    importc: "SDL_GetPointerProperty", header: "<SDL3/SDL.h>".}
  proc SDL_GetWindowProperties(win: ptr SDL_Window): uint32 {.
    importc: "SDL_GetWindowProperties", header: "<SDL3/SDL.h>".}
  proc SDL_GetGlobalProperties(): uint32 {.importc: "SDL_GetGlobalProperties", header: "<SDL3/SDL.h>".}
  proc SDL_CreateWindowWithProperties(props: uint32): ptr SDL_Window {.
    importc: "SDL_CreateWindowWithProperties", header: "<SDL3/SDL.h>".}
  proc SDL_CreateRenderer(win: ptr SDL_Window; name: nil cstring): ptr SDL_Renderer {.
    importc: "SDL_CreateRenderer", header: "<SDL3/SDL.h>".}
  proc SDL_SetWindowSize(win: ptr SDL_Window; w, h: int32): bool {.
    importc: "SDL_SetWindowSize", header: "<SDL3/SDL.h>".}
  proc SDL_ShowWindow(win: ptr SDL_Window): bool {.
    importc: "SDL_ShowWindow", header: "<SDL3/SDL.h>".}
  proc SDL_RaiseWindow(win: ptr SDL_Window): bool {.
    importc: "SDL_RaiseWindow", header: "<SDL3/SDL.h>".}
  proc SDL_SetWindowPosition(win: ptr SDL_Window; x, y: int32): bool {.
    importc: "SDL_SetWindowPosition", header: "<SDL3/SDL.h>".}
  proc SDL_GetWindowPosition(win: ptr SDL_Window; x, y: ptr int32): bool {.
    importc: "SDL_GetWindowPosition", header: "<SDL3/SDL.h>".}
  proc SDL_GetWindowSize(win: ptr SDL_Window; w, h: ptr int32): bool {.
    importc: "SDL_GetWindowSize", header: "<SDL3/SDL.h>".}
  proc SDL_GetWindowSizeInPixels(win: ptr SDL_Window; w, h: ptr int32): bool {.
    importc: "SDL_GetWindowSizeInPixels", header: "<SDL3/SDL.h>".}
  proc SDL_GetPrimaryDisplay(): uint32 {.importc: "SDL_GetPrimaryDisplay", header: "<SDL3/SDL.h>".}
  proc SDL_GetDisplayBounds(display: uint32; r: ptr SDL_IRect): bool {.
    importc: "SDL_GetDisplayBounds", header: "<SDL3/SDL.h>".}
  proc SDL_GetDisplayUsableBounds(display: uint32; r: ptr SDL_IRect): bool {.
    importc: "SDL_GetDisplayUsableBounds", header: "<SDL3/SDL.h>".}

  let
    PropCreateFlags {.importc: "SDL_PROP_WINDOW_CREATE_FLAGS_NUMBER", header: "<SDL3/SDL.h>".}: cstring
    PropCreateTitle {.importc: "SDL_PROP_WINDOW_CREATE_TITLE_STRING", header: "<SDL3/SDL.h>".}: cstring
    PropCreateWidth {.importc: "SDL_PROP_WINDOW_CREATE_WIDTH_NUMBER", header: "<SDL3/SDL.h>".}: cstring
    PropCreateHeight {.importc: "SDL_PROP_WINDOW_CREATE_HEIGHT_NUMBER", header: "<SDL3/SDL.h>".}: cstring
    PropCreateOpenGL {.importc: "SDL_PROP_WINDOW_CREATE_OPENGL_BOOLEAN", header: "<SDL3/SDL.h>".}: cstring
    PropCustomRole {.importc: "SDL_PROP_WINDOW_CREATE_WAYLAND_SURFACE_ROLE_CUSTOM_BOOLEAN", header: "<SDL3/SDL.h>".}: cstring
    PropWlDisplay {.importc: "SDL_PROP_WINDOW_WAYLAND_DISPLAY_POINTER", header: "<SDL3/SDL.h>".}: cstring
    PropWlSurface {.importc: "SDL_PROP_WINDOW_WAYLAND_SURFACE_POINTER", header: "<SDL3/SDL.h>".}: cstring
    PropGlobalWlDisplay {.importc: "SDL_PROP_GLOBAL_VIDEO_WAYLAND_WL_DISPLAY_POINTER", header: "<SDL3/SDL.h>".}: cstring

  proc SDL_WaitEventTimeout(event: ptr SDL_Event; timeoutMS: int32): bool {.
    importc: "SDL_WaitEventTimeout", header: "<SDL3/SDL.h>".}
  proc SDL_DelayNS(ns: uint64) {.importc: "SDL_DelayNS", header: "<SDL3/SDL.h>".}
  proc SDL_SetRenderVSync(ren: ptr SDL_Renderer; vsync: int32): bool {.
    importc: "SDL_SetRenderVSync", header: "<SDL3/SDL.h>".}
  proc SDL_GetDisplayForWindow(win: ptr SDL_Window): uint32 {.
    importc: "SDL_GetDisplayForWindow", header: "<SDL3/SDL.h>".}
  proc SDL_GetCurrentDisplayMode(display: uint32): ptr SDL_DisplayMode {.
    importc: "SDL_GetCurrentDisplayMode", header: "<SDL3/SDL.h>".}
  proc SDL_SetRenderDrawColor(ren: ptr SDL_Renderer; r, g, b, a: uint8): bool {.importc: "SDL_SetRenderDrawColor", header: "<SDL3/SDL.h>".}
  proc SDL_RenderClear(ren: ptr SDL_Renderer): bool {.importc: "SDL_RenderClear", header: "<SDL3/SDL.h>".}
  proc SDL_RenderPresent(ren: ptr SDL_Renderer): bool {.importc: "SDL_RenderPresent", header: "<SDL3/SDL.h>".}

when withSdl:
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
else:
  type
    Window* = object
    Renderer* = object

type
  PointerState* = object
    ## Primary-pointer position (window pixels) and button state, as last
    ## seen by `pumpEvents`. The UI's layout root is the window, so the
    ## position is also clay-relative.
    x*, y*: float32
    down*, rightDown*: bool

type
  PlatformApplication* = object
    window: Window
    renderer: Renderer
    when withSdl:
      surface: ptr SDL_Surface ## the offscreen picture's backbuffer
      surfaceWidth, surfaceHeight: int32
    pointer: PointerState
    width, height: float32
    running: bool
    keyPending: seq[KeyEvent]   ## events pumped since the last input frame
    keyFrame: seq[KeyEvent]     ## the events `keyEvents()` hands to widgets
    wheelPending: tuple[x, y: float32]
    wheelFrame: tuple[x, y: float32]
    motionPending: tuple[x, y: float32] ## pointer motion unread by a view
    doublePending: bool         ## a left-button click with SDL's click
    doubleFrame: bool           ## counter >= 2, per input frame
    vsync: bool                 ## presents are paced by the display
    visible: bool               ## not hidden / minimized: worth presenting
    docked: bool                ## a wlr-layer-shell surface (see `layershell`)
    offscreen: bool             ## no window of ours: a host app owns the
                                ## screen and draws our picture itself (see
                                ## `initializeOffscreen`)

when withSdl:
  proc `=destroy`(app: var PlatformApplication) =
    `=destroy`(app.renderer)
    `=destroy`(app.window)
    if not app.surface.isNil:
      SDL_DestroySurface(app.surface)
      app.surface = nil

when withSdl:
  {.compile: "sdl_wake.c".}
  proc ellipse_sdl_fdwake_start(): uint32 {.importc: "ellipse_sdl_fdwake_start".}

  var fdWakeType = 0'u32
    ## The SDL user event fdwatch's helper thread pushes (see `sdl_wake.c`).

  proc sdlHandle(ok: bool, id: string)  =
    if not ok:
      let cstr = SDL_GetError()
      let detail =
        if cstr.isNil: ""
        else: $cstr
      error id, " failed: ", detail
      raise Failure()

var activeApp: PlatformApplication

type
  CloseHandler* = proc (): bool {.closure.}

var closeHandler: CloseHandler = nil

proc setCloseHandler*(f: CloseHandler) =
  ## Ask `f` when the person asks to close the app -- a window's close
  ## button, Ctrl+Q in the terminal: true closes it now, false keeps it
  ## running (an app with unsaved work asks first, then calls `quit`). nil
  ## closes at once, the default. Termination signals always close.
  closeHandler = f

var inputDebug = getEnv("ELLIPSE_INPUT_DEBUG") != ""
  ## When set, pumpEvents logs every raw SDL event (type + key fields),
  ## revealing exactly what the platform backend delivers.

when withSdl:
  proc sdlRenderer*(): ptr SDL_Renderer =
    ## The live SDL_Renderer handle, for drawing modules (see
    ## `ellipse/platform/renderer`). Only valid inside the main loop.
    activeApp.renderer.raw

  proc offscreenSurface*(): pointer =
    ## The offscreen picture's `SDL_Surface*` (see `initializeOffscreen`),
    ## nil when the app has a window of its own. The renderer paints
    ## straight into it and reads the changed pixels back from it.
    if activeApp.offscreen: activeApp.surface else: nil

var quitSignaled = false
  ## Set once anything asked the app to close: a quit or window-close event,
  ## a signal, `quit()`. The host loop reads it through `quitAsked`.

proc quitAsked*(): bool =
  ## A close was asked for: the host that drives `pumpEvents` from its own
  ## loop ends itself when this says true.
  quitSignaled

proc closeAsked(app: var PlatformApplication) =
  let h = closeHandler
  if h == nil or h():
    app.running = false
    quitSignaled = true
  wake()

type
  FrameFn* = proc() {.closure.}

type
  WindowConfig* = object
    ## What `initialize` opens. With `layer.enabled` the window becomes a
    ## docked layer surface where the compositor supports wlr-layer-shell,
    ## and a borderless always-on-top window of the same shape elsewhere
    ## (GNOME, X11, Windows) -- see `docked()`.
    title*: string = "ellipse"
    width*: int32 = 1280
    height*: int32 = 720
    resizable*: bool = true
    hidden*: bool = false      ## start unmapped; `showWindow` maps it
    layer*: LayerConfig

when withSdl:
  proc createPlainWindow(app: var PlatformApplication; cfg: WindowConfig;
                         w, h: int32; flags: uint32)  =
    var title = cfg.title
    sdlHandle(SDL_CreateWindowAndRenderer(title.cstring, w, h, flags,
      addr app.window.raw, addr app.renderer.raw), "SDL_CreateWindowAndRenderer()")
    app.width = float32(w)
    app.height = float32(h)

  proc tryLayerWindow(app: var PlatformApplication; cfg: WindowConfig): bool  =
    ## The layer-shell path: a roleless SDL surface given the layer role.
    ## False (nothing created) when the compositor lacks the protocol.
    if $SDL_GetCurrentVideoDriver() != "wayland":
      return false
    let display = SDL_GetPointerProperty(SDL_GetGlobalProperties(),
                                         PropGlobalWlDisplay, nil)
    if display == nil or not layerShellAvailable(display):
      return false
    let (rw, rh) = requestSize(cfg.layer)
    # Start at the size the compositor will most likely configure -- the
    # output's span along the edge -- so the first buffer already fits.
    var bounds = SDL_IRect()
    var iw = rw
    var ih = rh
    if SDL_GetDisplayBounds(SDL_GetPrimaryDisplay(), addr bounds):
      if iw <= 0: iw = bounds.w
      if ih <= 0: ih = bounds.h
    let props = SDL_CreateProperties()
    var title = cfg.title
    discard SDL_SetStringProperty(props, PropCreateTitle, title.cstring)
    discard SDL_SetBooleanProperty(props, PropCustomRole, true)
    # OpenGL (an EGL window): SDL resizes it on `SDL_SetWindowSize`, which is
    # the only size signal a custom surface has. Its Vulkan/GPU renderers keep
    # the swapchain they were created with, so they are not asked for.
    discard SDL_SetBooleanProperty(props, PropCreateOpenGL, true)
    discard SDL_SetNumberProperty(props, PropCreateWidth, int64(max(iw, 1'i32)))
    discard SDL_SetNumberProperty(props, PropCreateHeight, int64(max(ih, 1'i32)))
    let win = SDL_CreateWindowWithProperties(props)
    SDL_DestroyProperties(props)
    if win == nil:
      return false
    app.window.raw = win
    var drivers = "opengl,opengles2,software"
    let ren = SDL_CreateRenderer(win, drivers.cstring)
    if ren == nil:
      return false
    app.renderer.raw = ren
    let wins = SDL_GetWindowProperties(win)
    let wlDisplay = SDL_GetPointerProperty(wins, PropWlDisplay, nil)
    let wlSurface = SDL_GetPointerProperty(wins, PropWlSurface, nil)
    if wlDisplay == nil or wlSurface == nil:
      return false
    if not attachLayer(wlDisplay, wlSurface, cfg.layer):
      return false
    # The compositor picked the size (the spanned edge's length): tell SDL,
    # whose custom surfaces get no size notifications of their own.
    let (_, w, h) = takeLayerSize()
    let fw = if w > 0: w else: max(iw, 1'i32)
    let fh = if h > 0: h else: max(ih, 1'i32)
    discard SDL_SetWindowSize(win, fw, fh)
    app.width = float32(fw)
    app.height = float32(fh)
    app.docked = true
    return true

## --- the terminal backend ---------------------------------------------------------
##
## With `terminalMode()` (`--tui`, `ELLIPSE_TUI=1`) no window opens: SDL
## runs only its event queue, and the terminal is the window. Its input
## descriptor and a signal pipe are watched with `fdwatch`, so key presses,
## mouse reports and resizes wake the very same paced loop a window's
## events do, between frames. The layout is the terminal's cells in
## virtual pixels (`cellWidth` x `cellHeight` each); the pointer sits at
## the centre of the cell the mouse is over.
##
## Ctrl+Q closes the app, as a window's close button would.
##
## When stdout is not a terminal (a pipe, a test, `ELLIPSE_SCREENSHOT`) the
## backend runs headless at `ELLIPSE_TUI_SIZE` (`120x40` by default) and
## writes nothing.

var
  termDecoder: Decoder
  termSigFd = -1'i32
  termHeadless = false
  termMods: tuple[ctrl, shift, alt: bool]
  termClipboard = ""
  termLastClick = 0'i64
  termLastClickCell = (-1, -1)

const DoubleClickNs = 400_000_000'i64

proc headlessSize(): tuple[cols, rows: int] =
  result = (120, 40)
  let spec = getEnv("ELLIPSE_TUI_SIZE")
  let x = spec.find('x')
  if x > 0:
    try:
      result = (max(parseInt(spec.substr(0, x - 1)), 1),
                max(parseInt(spec.substr(x + 1)), 1))
    except:
      discard

proc terminalHeadless*(): bool =
  ## The terminal backend is drawing for nobody (see above).
  termHeadless

proc terminalSize*(): tuple[cols, rows: int] =
  ## The terminal's size in cells.
  if termHeadless: headlessSize() else: ttySize()

var termCaret: tuple[shown: bool, x, y: float32]

proc setTerminalCaret*(x, y: float32) =
  ## Put the terminal's own cursor at layout point (x, y) for this frame --
  ## what a focused text field does instead of painting a caret bar. The
  ## renderer shows it after the frame and hides it on frames nobody asks.
  termCaret = (true, x, y)

proc takeTerminalCaret*(): tuple[shown: bool, x, y: float32] =
  ## This frame's cursor request (and forget it for the next).
  result = termCaret
  termCaret = (false, 0'f32, 0'f32)

proc terminalWrite*(s: string) =
  ## Send `s` to the terminal (escape sequences included); dropped headless.
  if not termHeadless:
    ttyWrite(s)

proc termResize(app: var PlatformApplication) =
  let (cols, rows) = terminalSize()
  let w = float32(cols) * cellWidth
  let h = float32(rows) * cellHeight
  if w != app.width or h != app.height:
    app.width = w
    app.height = h
    requestFullRedraw()
    wake()

proc termPointer(app: var PlatformApplication; col, row: int) =
  app.pointer.x = (float32(col) + 0.5'f32) * cellWidth
  app.pointer.y = (float32(row) + 0.5'f32) * cellHeight

proc termInput(app: var PlatformApplication; evs: seq[TermEvent]) =
  for ev in evs:
    case ev.kind
    of teKey:
      let k = ev.key
      if k.kind == kevLetter and k.ctrl and not k.alt and k.ch == 'q':
        closeAsked(app)
        continue
      termMods = (ctrl: k.ctrl, shift: k.shift, alt: k.alt)
      app.keyPending.add k
      wake()
    of teMouse:
      termMods = (ctrl: ev.ctrl, shift: ev.shift, alt: ev.alt)
      termPointer(app, ev.col, ev.row)
      if ev.motion:
        app.pointer.down = ev.pressed and ev.button == mbLeft
        if not frameWanted(monoNow()) and
            motionWakes(app.pointer.x, app.pointer.y, app.pointer.down):
          wake()
      else:
        if ev.button == mbLeft:
          app.pointer.down = ev.pressed
          if ev.pressed:
            let now = monoNow()
            if now - termLastClick < DoubleClickNs and
                termLastClickCell == (ev.col, ev.row):
              app.doublePending = true
              termLastClick = 0
            else:
              termLastClick = now
            termLastClickCell = (ev.col, ev.row)
        elif not ev.pressed:
          app.pointer.down = false
        wake()
    of teWheel:
      termMods = (ctrl: ev.ctrl, shift: ev.shift, alt: ev.alt)
      termPointer(app, ev.wcol, ev.wrow)
      app.wheelPending.x += ev.dx
      app.wheelPending.y += ev.dy
      wake()
    of tePaste:
      # Lines as typed: text, Enter, text.
      var line = ""
      for ch in ev.text:
        if ch == '\r':
          continue
        if ch == '\n':
          if line.len > 0:
            app.keyPending.add KeyEvent(kind: kevText, text: line)
          app.keyPending.add KeyEvent(kind: kevEnter)
          line = ""
        else:
          line.add ch
      if line.len > 0:
        app.keyPending.add KeyEvent(kind: kevText, text: line)
      wake()
    of teFocus:
      wake()

proc readTerminalInput() =
  let (data, eof) = ttyRead(0'i32)
  if data.len > 0:
    termInput(activeApp, termDecoder.feed(data))
  if eof:
    activeApp.running = false
    wake()

proc readTerminalSignals() =
  let (data, _) = ttyRead(termSigFd)
  for b in data:
    if b == 'w':
      termResize(activeApp)
    elif b == 'q':
      activeApp.running = false
      wake()

proc setTerminalTitle(title: string) =
  terminalWrite("\e]2;" & title & "\a")

proc initTerminal(app: var PlatformApplication; cfg: WindowConfig)  =
  # No SDL here: the loop sleeps in poll() on the watched descriptors.
  useDirectWait()
  app.visible = true
  app.vsync = false
  termHeadless = not ttyIsTty()
  if not termHeadless:
    termSigFd = ttyOpen()
    if termSigFd < 0:
      error "could not put the terminal in raw mode"
      raise Failure()
    discard watchFd(0'i32, proc () = readTerminalInput())
    discard watchFd(termSigFd, proc () = readTerminalSignals())
    setTerminalTitle(cfg.title)
  termResize(app)

when withSdl:
  proc initWindow(cfg: WindowConfig)  =
    var an = "ellipse"
    var av = "0.1.0"
    var aid = "org.ellipse.platform"

    sdlHandle(SDL_SetAppMetadata(an.cstring, av.cstring, aid.cstring), "SDL_SetAppMetadata()")
    # A compositor that publishes WAYLAND_DISPLAY should get a wayland
    # window: left to itself SDL may still reach for X11 (XWayland), where
    # GLX context creation fails outright on some drivers (proprietary
    # nvidia) -- BadValue before a frame is ever drawn. An explicit
    # SDL_VIDEODRIVER/SDL_VIDEO_DRIVER always wins; offscreen test runs set
    # one.
    when not defined(windows):
      if getEnv("WAYLAND_DISPLAY").len > 0 and
          getEnv("SDL_VIDEODRIVER").len == 0 and
          getEnv("SDL_VIDEO_DRIVER").len == 0:
        discard setenv("SDL_VIDEODRIVER", "wayland", 1)
    sdlHandle(SDL_Init(Video or Audio), "SDL_Init()")
    fdWakeType = ellipse_sdl_fdwake_start()
    if cfg.layer.enabled:
      if not tryLayerWindow(activeApp, cfg):
        `=destroy`(activeApp.renderer)
        `=destroy`(activeApp.window)
        # No layer shell (GNOME, X11, Windows): a borderless always-on-top
        # window of the dock's shape. It does not reserve screen space.
        var bounds = SDL_IRect()
        var spanW = 1280'i32
        var spanH = 720'i32
        if SDL_GetDisplayUsableBounds(SDL_GetPrimaryDisplay(), addr bounds):
          spanW = bounds.w
          spanH = bounds.h
        let t = cfg.layer.thickness
        let along = cfg.layer.length
        let (w, h) = case cfg.layer.edge
          of edgeTop, edgeBottom: ((if along > 0: along else: spanW), t)
          of edgeLeft, edgeRight: (t, (if along > 0: along else: spanH))
        info "layer shell unavailable (", $SDL_GetCurrentVideoDriver(),
          "): opening a plain borderless window; it will not dock or reserve space"
        createPlainWindow(activeApp, cfg, w, h, WindowBorderless or WindowAlwaysOnTop)
    else:
      var flags = if cfg.resizable: WindowResizable else: 0'u32
      if cfg.hidden:
        flags = flags or WindowHidden
      createPlainWindow(activeApp, cfg, cfg.width, cfg.height, flags)
    # NOTE: text input (SDL_StartTextInput / the IME path) is deliberately NOT
    # started here. SDL >= 3.4 only emits SDL_EVENT_TEXT_INPUT once it is on --
    # and while it is on, active input methods (X11/ibus, Wayland text-input-v3)
    # may consume the raw key presses, killing Backspace/arrows/Enter. So the
    # default mode derives printable characters from the keydown events'
    # keycodes themselves (see keyEventFor); `setTextInputEnabled(true)` opts
    # into the IME path when full international composition is wanted.
    activeApp.visible = not cfg.hidden
    # Present on vsync: frames that run at all run at the display rate, and the
    # swap paces them. Drivers without it (offscreen) fall back to a timer.
    activeApp.vsync = SDL_SetRenderVSync(activeApp.renderer.raw, 1)
    if inputDebug:
      discard info("sdl video driver: ", $SDL_GetCurrentVideoDriver())

proc initialize*(cfg: WindowConfig)  =
  ## Start SDL and open the app's window as `cfg` describes -- or take over
  ## the terminal in `terminalMode()` (always, in a build without SDL).
  activeApp = PlatformApplication()
  if terminalMode():
    initTerminal(activeApp, cfg)
    return
  when withSdl:
    initWindow(cfg)

var textImeActive = false

proc setTextInputEnabled*(enabled: bool) =
  ## Toggle the platform IME text-input path (SDL_StartTextInput/Stop).
  ## Off by default: printable characters are then synthesized from keydown
  ## events, which keeps Backspace/arrows/Enter deliverable on systems where
  ## an active input method would otherwise swallow them. On, the IME owns
  ## the keyboard and text arrives as `kevText` from TEXT_INPUT commits --
  ## enabling international composition at the cost of raw editing keys.
  if enabled == textImeActive:
    return
  textImeActive = enabled
  when withSdl:
    if activeApp.window.raw != nil:
      if enabled:
        discard SDL_StartTextInput(activeApp.window.raw)
      else:
        discard SDL_StopTextInput(activeApp.window.raw)

proc initialize*()  =
  ## The default window: 1280x720, resizable.
  initialize(WindowConfig())

when withSdl:
  const PixelFormatARGB8888 = 0x16362004'u32  ## SDL_PIXELFORMAT_ARGB8888

  proc openOffscreen(app: var PlatformApplication; w, h: int32)  =
    ## (Re)build the offscreen picture: an ARGB surface with a software
    ## renderer on it. Nothing about it is visible; the renderer module
    ## paints commands into it and `readPicture` copies it out.
    `=destroy`(app.renderer)
    if not app.surface.isNil:
      SDL_DestroySurface(app.surface)
      app.surface = nil
    app.surface = SDL_CreateSurface(w, h, PixelFormatARGB8888)
    if app.surface.isNil:
      raise Failure()
    app.renderer.raw = SDL_CreateSoftwareRenderer(app.surface)
    if app.renderer.raw.isNil:
      raise Failure()
    app.surfaceWidth = w
    app.surfaceHeight = h

proc initializeOffscreen*(width, height: int32)  =
  ## The platform app without a window of its own: SDL stays as the host
  ## found it, the UI paints into an offscreen surface, and the host pumps
  ## `pumpEvents` for its widgets and takes the picture through
  ## `renderer.readPicture` to draw over its own scene. No window, no
  ## present, no paced loop.
  activeApp = PlatformApplication()
  activeApp.running = true
  activeApp.width = width.float32
  activeApp.height = height.float32
  when withSdl:
    activeApp.offscreen = true
    openOffscreen(activeApp, width, height)

proc resizeOffscreen*(width, height: int32) =
  ## Give the offscreen picture the host window's new shape. The renderer
  ## module rebinds its text engine and repaints in full afterwards; the
  ## clay context follows `windowPixelSize` on the next input frame.
  when withSdl:
    if not activeApp.offscreen or width <= 0 or height <= 0:
      return
    if width == activeApp.surfaceWidth and height == activeApp.surfaceHeight:
      return
    openOffscreen(activeApp, width, height)
    activeApp.width = width.float32
    activeApp.height = height.float32

proc docked*(): bool =
  ## The window is a wlr-layer-shell surface (not the fallback window).
  activeApp.docked

proc textInputEnabled*(): bool =
  textImeActive

proc updateRefreshPeriod(app: PlatformApplication) =
  ## Pace to the refresh rate of the display the window is on (60 Hz when
  ## the driver does not say).
  when withSdl:
    if app.window.raw == nil:
      return
    let mode = SDL_GetCurrentDisplayMode(SDL_GetDisplayForWindow(app.window.raw))
    if mode != nil and mode[].refresh_rate > 1.0'f32:
      setRefreshPeriod(int64(1_000_000_000.0'f64 / float64(mode[].refresh_rate)))
    else:
      setRefreshPeriod(16_666_667'i64)

when withSdl:
  proc utf8Of(cp: int32): string =
    ## Encode one Unicode code point as UTF-8 (no std dependency).
    result = ""
    if cp < 0x80:
      result.add char(cp)
    elif cp < 0x800:
      result.add char(0xC0 or (cp shr 6))
      result.add char(0x80 or (cp and 0x3F))
    elif cp < 0x10000:
      result.add char(0xE0 or (cp shr 12))
      result.add char(0x80 or ((cp shr 6) and 0x3F))
      result.add char(0x80 or (cp and 0x3F))
    else:
      result.add char(0xF0 or (cp shr 18))
      result.add char(0x80 or ((cp shr 12) and 0x3F))
      result.add char(0x80 or ((cp shr 6) and 0x3F))
      result.add char(0x80 or (cp and 0x3F))

  proc printable(cp: int32): bool =
    ## A keycode that is a character (not a control or a named key).
    cp >= 32 and cp != 127 and (cp and 0x40000000) == 0

  proc keypadKey(scancode: int32, numLock: bool): tuple[kind: KeyEventKind, ch: char] =
    ## The keypad: its operators always type, its digits and '.' type with
    ## NumLock on and are the navigation keys printed under them with it off.
    ## `kevNone` with `ch` = 0 for scancodes off the keypad.
    case scancode
    of ScanKPDivide: (kevText, '/')
    of ScanKPMultiply: (kevText, '*')
    of ScanKPMinus: (kevText, '-')
    of ScanKPPlus: (kevText, '+')
    of ScanKP1 .. ScanKP9, ScanKP0, ScanKPPeriod:
      let d =
        if scancode == ScanKP0: '0'
        elif scancode == ScanKPPeriod: '.'
        else: char(ord('1') + int(scancode - ScanKP1))
      if numLock:
        (kevText, d)
      else:
        case d
        of '1': (kevEnd, '\0')
        of '2': (kevDown, '\0')
        of '3': (kevPageDown, '\0')
        of '4': (kevLeft, '\0')
        of '6': (kevRight, '\0')
        of '7': (kevHome, '\0')
        of '8': (kevUp, '\0')
        of '9': (kevPageUp, '\0')
        of '0': (kevInsert, '\0')
        of '.': (kevDelete, '\0')
        else: (kevNone, '\0')
    else: (kevNone, '\0')

  proc chordChar(scancode: int32): char =
    ## The char a Ctrl/Alt chord on `scancode` carries: letters by position
    ## (QWERTY, so `Ctrl+Z` stays put on any layout), digits likewise, the
    ## rest the layout's unshifted symbol. 0 when the key types nothing.
    if scancode >= ScanA and scancode <= ScanZ:
      return char(ord('a') + int(scancode - ScanA))
    if scancode >= ScanDigit1 and scancode <= ScanDigit0:
      # 30..38 are '1'..'9'; 39 is '0' -- wrap the tenth step back.
      return char(ord('0') + (int(scancode - ScanDigit1) + 1) mod 10)
    let cp = SDL_GetKeyFromScancode(scancode, 0'i32, false)
    if printable(cp) and cp < 127:
      return char(cp)
    return '\0'

  proc keyEventFor(scancode, key, modifiers: int32): KeyEvent =
    ## Maps a keydown to a `KeyEvent`; unknown keys yield `kevNone`.
    ## Named keys (Enter, arrows, F1..F12, ...) keep their kind whatever the
    ## modifiers. Ctrl or Alt on a printable key makes a `kevLetter` chord
    ## carrying the key's unshifted char (see `chordChar`). AltGr (`Mode`)
    ## is not Alt: it selects a layout level, so AltGr+Q types '@' on a
    ## German board. With the IME path off, printable keys synthesize a
    ## `kevText` from the platform keymap with Shift, CapsLock and AltGr
    ## applied -- *not* from the event's keycode, which SDL3 reports
    ## unshifted for symbols (Shift+1 is SDLK_1 there, not '!').
    let mode = (modifiers and ModMode) != 0
    result = KeyEvent(kind: kevNone,
      shift: (modifiers and ModShift) != 0,
      ctrl: (modifiers and ModCtrl) != 0,
      alt: (modifiers and ModAlt) != 0 and not mode)
    case scancode
    of ScanEnter, ScanKeypadEnter: result.kind = kevEnter
    of ScanEscape: result.kind = kevEscape
    of ScanTab: result.kind = kevTab
    of ScanBackspace: result.kind = kevBackspace
    of ScanDelete: result.kind = kevDelete
    of ScanInsert: result.kind = kevInsert
    of ScanHome: result.kind = kevHome
    of ScanEnd: result.kind = kevEnd
    of ScanPageUp: result.kind = kevPageUp
    of ScanPageDown: result.kind = kevPageDown
    of ScanRight: result.kind = kevRight
    of ScanLeft: result.kind = kevLeft
    of ScanDown: result.kind = kevDown
    of ScanUp: result.kind = kevUp
    of ScanF1: result.kind = kevF1
    of ScanF2: result.kind = kevF2
    of ScanF3: result.kind = kevF3
    of ScanF4: result.kind = kevF4
    of ScanF5: result.kind = kevF5
    of ScanF6: result.kind = kevF6
    of ScanF7: result.kind = kevF7
    of ScanF8: result.kind = kevF8
    of ScanF9: result.kind = kevF9
    of ScanF10: result.kind = kevF10
    of ScanF11: result.kind = kevF11
    of ScanF12: result.kind = kevF12
    else:
      let pad = keypadKey(scancode, (modifiers and ModNum) != 0)
      if pad.kind != kevNone and pad.kind != kevText:
        result.kind = pad.kind            # NumLock off: a navigation key
      elif result.ctrl or result.alt:
        let ch = if pad.kind == kevText: pad.ch else: chordChar(scancode)
        if ch != '\0':
          result.kind = kevLetter
          result.ch = ch
      elif pad.kind == kevText:
        if not textImeActive:
          result.kind = kevText
          result.text = ""
          result.text.add pad.ch
      elif not textImeActive:
        # The keymap, with the modifiers that pick a character applied.
        var cp = SDL_GetKeyFromScancode(scancode,
          modifiers and (ModShift or ModCaps or ModMode), false)
        if not printable(cp) and printable(key):
          cp = key                        # a backend the keymap can't answer
        if printable(cp):
          result.kind = kevText
          result.text = utf8Of(cp)

var mouseGrabbed = false
var manualGrab = false
  ## The backend declined the raw grab: motion accumulates as the
  ## pointer's own displacement, and the cursor is hidden by hand.
var manualSnap = false
  ## ...and a client-side pointer warp is honoured (X11 and friends --
  ## never Wayland, where only the compositor moves the pointer): the
  ## platform keeps yanking the cursor back to the window centre, so a
  ## sweep cannot stall on an edge (see the snap at `pumpSdlEvents`' end).

when withSdl:
  proc grabWindow(): ptr SDL_Window =
    ## The window to ask: ours when platform made it (a UI app's), the
    ## pointer's focus otherwise -- an app may build its own around this
    ## module (beyond's game loop does), and its UI-overlay boot marks
    ## the platform app offscreen without meaning there is no window.
    if activeApp.window.raw != nil: activeApp.window.raw
    else: SDL_GetMouseFocus()

  proc videoCanWarp(): bool =
    ## Whether asking SDL to teleport the pointer means anything: on
    ## Wayland the pointer belongs to the compositor and a warp without
    ## a lock (the lock we just failed to get) is silently refused.
    let d = SDL_GetCurrentVideoDriver()
    not d.isNil and cmpIgnoreStyle($d, "wayland") != 0

proc setMouseGrab*(on: bool) =
  ## Hide the cursor and report its motion as look deltas: what a 3D
  ## view does while it owns the pointer (see `mouseDelta`). The
  ## backend's own grab (relative mode -- raw deltas, a pointer the
  ## compositor anchors) is asked for first; where it declines,
  ## confinement plus a centre warp per pump do the same by hand, and
  ## the cursor is hidden either way. The wish survives on terminal and
  ## offscreen hosts, which own the pointer elsewhere.
  mouseGrabbed = on
  manualGrab = false
  manualSnap = false
  when withSdl:
    if terminalMode():
      return
    let win = grabWindow()
    if win != nil:
      if on:
        if not SDL_SetWindowRelativeMouseMode(win, true):
          manualGrab = true
          manualSnap = videoCanWarp() and SDL_SetWindowMouseGrab(win, true)
      else:
        discard SDL_SetWindowRelativeMouseMode(win, false)
        discard SDL_SetWindowMouseGrab(win, false)
    if on:
      discard SDL_HideCursor()
    else:
      discard SDL_ShowCursor()
    if inputDebug:
      discard info("mouse-grab ", $on, " win=", if win.isNil: "none" else: "found",
        " manual=", $manualGrab, " snap=", $manualSnap)

proc mouseGrab*(): bool =
  ## Whether the pointer is grabbed (see `setMouseGrab`).
  mouseGrabbed

proc mouseDelta*(): tuple[x, y: float32] =
  ## Pointer motion in renderer pixels, accumulated by `pumpEvents` since
  ## the last call -- look input a view polls once per update tick. Raw
  ## deltas while grabbed, the pointer's own displacement while free; the
  ## read clamps and clears, so a view that stopped listening cannot bank
  ## a whip when it comes back.
  result = activeApp.motionPending
  result.x = result.x.clamp(-320'f32, 320'f32)
  result.y = result.y.clamp(-320'f32, 320'f32)
  activeApp.motionPending = (0'f32, 0'f32)

proc mouseRightDown*(): bool =
  ## Whether the right button is held, as of the most recent event pump
  ## -- the fly view's hold-to-look. Tracked like `PointerState.down`
  ## (which stays the UI's left button): motion events carry the held
  ## mask and the button's own edges set and clear it, so a release
  ## stops the turn the moment it happens.
  when withSdl:
    if terminalMode():
      return false
    activeApp.pointer.rightDown
  else:
    false

when withSdl:
  proc pumpSdlEvents(app: var PlatformApplication) =
    ## Drain SDL's queue into the app state, and tell the pacer which events
    ## need a frame: everything but pointer motion that changes nothing the
    ## UI shows (see `pacing.motionWakes`).
    if app.keyPending.len > 4096:
      # A host that pumps but runs no input frame (a scene without UI):
      # stale keys are worthless -- drop them rather than grow forever.
      app.keyPending.setLen(0)
    var event = default(SDL_Event)
    while SDL_PollEvent(addr event):
      let kind = cast[ptr SDL_CommonEvent](addr event)[].typ
      if inputDebug:
        let kb = cast[ptr SDL_KeyboardEvent](addr event)[]
        discard info("sdl-event ", $kind, " sc=", $kb.scancode, " key=",
          $kb.key, " mod=", $kb.modifiers)
      if kind != 0'u32 and kind == fdWakeType:
        # A watched descriptor is readable (see `fdwatch`): its callback runs
        # here, between frames.
        runReadyFds()
      elif kind == EventTerminating:
        app.running = false
        quitSignaled = true
        wake()
      elif kind == EventQuit or kind == EventWindowCloseRequested:
        closeAsked(app)
      elif kind == EventWindowPixelResized:
        # Track the live window size so the UI can re-layout the moment the
        # window is resized. `data1`/`data2` carry the new drawable size in
        # renderer pixels -- the space we draw and report pointer positions in.
        # Each one also opens / extends the resize gesture the pacer runs at
        # vsync until the window holds still.
        # Drivers also report the initial size (and repeat sizes); only a
        # real change counts.
        let e = cast[ptr SDL_WindowEvent](addr event)[]
        if e.data1 > 0 and e.data2 > 0 and
            (float32(e.data1) != app.width or float32(e.data2) != app.height):
          app.width = float32(e.data1)
          app.height = float32(e.data2)
          noteResize(monoNow())
      elif kind == EventWindowExposed or kind == EventWindowShown or
          kind == EventWindowRestored:
        app.visible = true
        requestFullRedraw()
      elif kind == EventWindowHidden or kind == EventWindowMinimized:
        app.visible = false
      elif kind == EventWindowDisplayChanged:
        updateRefreshPeriod(app)
        requestFullRedraw()
      elif kind == EventWindowMouseLeave:
        # The pointer left the window: nothing in it is hovered any more.
        if not app.pointer.down:
          app.pointer.x = -1.0e6'f32
          app.pointer.y = -1.0e6'f32
        wake()
      elif kind == EventWindowFocusGained or kind == EventWindowFocusLost:
        wake()
      elif kind == EventMouseMotion:
        let e = cast[ptr SDL_MouseMotionEvent](addr event)[]
        if mouseGrabbed and not manualGrab:
          # grabbed for real: the position is the warp anchor, so the
          # turn lives in the raw deltas the backend hands us.
          app.motionPending.x += e.xrel
          app.motionPending.y += e.yrel
        elif app.pointer.x > -1.0e5 and app.pointer.y > -1.0e5:
          # free, or a grab the backend declined: the pointer's own
          # displacement, clamped so that leaving the window (the edge
          # parked at -1e6) and rejoining cannot whip a listening view.
          app.motionPending.x += (e.x - app.pointer.x).clamp(-80'f32, 80'f32)
          app.motionPending.y += (e.y - app.pointer.y).clamp(-80'f32, 80'f32)
        app.pointer.x = e.x
        app.pointer.y = e.y
        app.pointer.down = (e.state and ButtonLeftMask) != 0
        app.pointer.rightDown = (e.state and ButtonRightMask) != 0
        if not frameWanted(monoNow()) and
            motionWakes(e.x, e.y, app.pointer.down):
          wake()
      elif kind == EventMouseButtonDown:
        let e = cast[ptr SDL_MouseButtonEvent](addr event)[]
        if e.button == ButtonLeft:
          app.pointer.down = true
          if e.clicks >= 2:
            app.doublePending = true
        elif e.button == ButtonRight:
          app.pointer.rightDown = true
        wake()
      elif kind == EventMouseButtonUp:
        let e = cast[ptr SDL_MouseButtonEvent](addr event)[]
        if e.button == ButtonLeft:
          app.pointer.down = false
        elif e.button == ButtonRight:
          app.pointer.rightDown = false
        wake()
      elif kind == EventKeyDown:
        let e = cast[ptr SDL_KeyboardEvent](addr event)[]
        if e.down:   # SDL delivers autorepeat as repeated downs: forward them
          let ev = keyEventFor(e.scancode, e.key, e.modifiers.int32)
          if ev.kind != kevNone:
            app.keyPending.add ev
        wake()   # any key, even an unmapped one: modifier state is polled
      elif kind == EventKeyUp:
        wake()
      elif kind == EventTextInput:
        let e = cast[ptr SDL_TextInputEvent](addr event)[]
        if not e.text.isNil:   # printable input, already keyboard-layout applied
          app.keyPending.add KeyEvent(kind: kevText, text: $e.text)
          wake()
      elif kind == EventMouseWheel:
        let e = cast[ptr SDL_MouseWheelEvent](addr event)[]
        app.wheelPending.x += e.x
        app.wheelPending.y += e.y
        wake()
    if manualSnap:
      # hand-rolled capture (see `setMouseGrab`): the backend declined
      # the raw grab but honours confinement and warps, so keep yanking
      # the cursor back to the window's centre -- a view can then turn
      # without the pointer ever reaching an edge.
      let win = grabWindow()
      var pw, ph: int32
      if win != nil and SDL_GetWindowSizeInPixels(win, addr pw, addr ph) and
          pw > 0 and ph > 0:
        let cx = pw.float32 / 2.0f
        let cy = ph.float32 / 2.0f
        if abs(app.pointer.x - cx) > 4 or abs(app.pointer.y - cy) > 4 or
            app.pointer.x < 0:
          SDL_WarpMouseInWindow(win, cx, cy)
          # the warp echoes a motion event at the centre: land the
          # tracked pointer there too, so the echo counts as nothing
          # and never turns the view back on itself.
          app.pointer.x = cx
          app.pointer.y = cy

when withSdl:
  proc pumpLayer(app: var PlatformApplication) =
    ## Fold layer-surface configures (dispatched inside SDL's event pump) into
    ## the window size, the way a pixel-size event would be.
    if not app.docked:
      return
    if layerClosed():
      app.running = false
      wake()
      return
    let (changed, w, h) = takeLayerSize()
    if changed and w > 0 and h > 0:
      discard SDL_SetWindowSize(app.window.raw, w, h)
      var pw = w
      var ph = h
      discard SDL_GetWindowSizeInPixels(app.window.raw, addr pw, addr ph)
      app.width = float32(pw)
      app.height = float32(ph)
      noteResize(monoNow())

proc videoDriver*(): string =
  ## SDL's video backend: "wayland", "x11", "windows", "offscreen", ...;
  ## "" in the terminal or without SDL.
  when withSdl:
    if terminalMode():
      return ""
    let d = SDL_GetCurrentVideoDriver()
    result = if d.isNil: "" else: $d
  else:
    result = ""

when withSdl:
  proc sdlWindow*(): pointer =
    ## The live `SDL_Window*`, for native glue (see `transient`). Nil before
    ## `initialize` and in the terminal.
    activeApp.window.raw
else:
  proc sdlWindow*(): nil pointer =
    ## No window without SDL.
    nil

proc showWindow*() =
  ## Map a window opened with `WindowConfig.hidden`.
  when withSdl:
    if activeApp.window.raw != nil:
      discard SDL_ShowWindow(activeApp.window.raw)
      activeApp.visible = true

proc raiseWindow*() =
  ## Ask the window manager to bring the window to the front and focus it.
  when withSdl:
    if activeApp.window.raw != nil:
      discard SDL_RaiseWindow(activeApp.window.raw)

proc windowBounds*(): tuple[x, y, width, height: int32] =
  ## The window's position and size in screen coordinates (not pixels).
  ## Wayland never reports a position: x and y read 0 there.
  var x, y, w, h = 0'i32
  when withSdl:
    if activeApp.window.raw != nil:
      discard SDL_GetWindowPosition(activeApp.window.raw, addr x, addr y)
      discard SDL_GetWindowSize(activeApp.window.raw, addr w, addr h)
  (x, y, w, h)

proc setWindowSize*(width, height: int32) =
  ## Resize the window (screen coordinates). The layout follows from the
  ## next frame, through the resize event.
  when withSdl:
    if activeApp.window.raw != nil:
      discard SDL_SetWindowSize(activeApp.window.raw, width, height)

proc setWindowPosition*(x, y: int32) =
  ## Move the window (screen coordinates). Ignored on Wayland, where only
  ## the compositor places windows.
  when withSdl:
    if activeApp.window.raw != nil:
      discard SDL_SetWindowPosition(activeApp.window.raw, x, y)

proc windowPixelScale*(): float32 =
  ## Renderer pixels per screen coordinate: layout sizes divide by this to
  ## become window sizes.
  result = 1.0'f32
  when withSdl:
    var w, h, pw, ph = 0'i32
    if activeApp.window.raw == nil:
      return 1.0'f32
    discard SDL_GetWindowSize(activeApp.window.raw, addr w, addr h)
    discard SDL_GetWindowSizeInPixels(activeApp.window.raw, addr pw, addr ph)
    if w <= 0 or pw <= 0:
      return 1.0'f32
    result = float32(pw) / float32(w)

proc pointerState*(): PointerState =
  ## The pointer as of the most recent event pump; feed it to
  ## `clay.setPointerState` once per update tick.
  activeApp.pointer

proc quit*() =
  ## End the `start` loop at the next iteration -- an app's File > Exit.
  activeApp.running = false
  quitSignaled = true

proc windowPixelSize*(): tuple[width, height: float32] =
  ## The window's drawable size in renderer pixels, as of the most recent
  ## event pump. Feed it to `clay.setLayoutDimensions` each update tick so
  ## the layout tracks live window resizes.
  (activeApp.width, activeApp.height)

proc beginInputFrame*() =
  ## Publish the events pumped so far as *this* input frame's data: what
  ## `keyEvents` and `wheelDelta` report until the next call. The game loop
  ## pumps events once per main-loop iteration while `tick` may run several
  ## updates; only the first update of a batch consumes the events, the rest
  ## see empty frames. UI code calls this once per update, before laying out.
  activeApp.keyFrame.setLen(0)
  for ev in activeApp.keyPending:
    activeApp.keyFrame.add ev
  activeApp.keyPending.setLen(0)
  activeApp.wheelFrame = activeApp.wheelPending
  activeApp.wheelPending = (float32(0.0), float32(0.0))
  activeApp.doubleFrame = activeApp.doublePending
  activeApp.doublePending = false

proc consumeKeys*(kind: KeyEventKind) =
  ## Drop this input frame's events of `kind`: a global binding (the debug
  ## overlay's F1) takes the key before widgets and app chords see it.
  var kept: seq[KeyEvent] = @[]
  for ev in activeApp.keyFrame:
    if ev.kind != kind:
      kept.add ev
  activeApp.keyFrame = kept

proc keyEvents*(): seq[KeyEvent] =
  ## Keyboard/text events collected since the last `beginInputFrame`.
  activeApp.keyFrame

proc setKeyEvents*(evs: seq[KeyEvent]) =
  ## Replace this input frame's events: the seam key routing layers (the
  ## keymaps of `ellipse_ui/keys`) take the keys they handled out through,
  ## so nothing downstream sees them again.
  activeApp.keyFrame = evs

proc wheelDelta*(): tuple[x, y: float32] =
  ## Accumulated scroll-wheel movement since the last `beginInputFrame`,
  ## in SDL's units: positive y scrolls up/away from the user.
  activeApp.wheelFrame

proc doubleClick*(): bool =
  ## The primary button went down for the *second* click of a double click
  ## this input frame (SDL's own click counter and timing window). Widgets
  ## that offer double-click behaviour (word selection, list activation)
  ## combine this with their normal `clickedIn` edge: the frame a double
  ## click lands on is also a press edge.
  activeApp.doubleFrame

proc keyMods*(): tuple[ctrl, shift, alt: bool] =
  ## The live Ctrl/Shift/Alt modifier state -- not queued like key events
  ## but polled, so chords held *while the wheel turns* are visible (zoom
  ## widgets) even though the press itself emitted no event this frame.
  if terminalMode():
    return termMods
  when withSdl:
    let m = SDL_GetModState().int32
    result = (ctrl: (m and ModCtrl) != 0, shift: (m and ModShift) != 0,
              alt: (m and ModAlt) != 0)
  else:
    result = termMods

proc setWindowTitle*(title: string) =
  ## Rename the window. A no-op before `initialize()`.
  if terminalMode():
    setTerminalTitle(title)
    return
  when withSdl:
    if activeApp.window.raw != nil:
      var t = title
      discard SDL_SetWindowTitle(activeApp.window.raw, t.cstring)

proc getClipboard*(): string =
  ## The system clipboard as text; empty when nothing is (or SDL is not
  ## up yet, which is the state headless tests run in). In the terminal:
  ## what this app last copied (terminals do not let apps read theirs).
  if terminalMode():
    return termClipboard
  result = ""
  when withSdl:
    if activeApp.window.raw == nil:
      return ""
    let cstr = SDL_GetClipboardText()
    if cstr.isNil:
      return ""
    result = $cstr
    SDL_free(cstr)

proc setClipboard*(text: string) =
  ## Put `text` on the system clipboard. No-op before `initialize()`. In
  ## the terminal: through OSC 52, which most terminals honour.
  if terminalMode():
    termClipboard = text
    terminalWrite("\e]52;c;" & encode(text) & "\a")
    return
  when withSdl:
    if activeApp.window.raw == nil:
      return
    var t = text
    discard SDL_SetClipboardText(t.cstring)

proc pushKeyEvent*(ev: KeyEvent) =
  ## Feed a synthetic event into the queue -- the seam for tests, on-screen
  ## keyboards and gamepad text input.
  activeApp.keyPending.add ev
  wake()

proc setPointer*(x, y: float32; down: bool) =
  ## Put the primary pointer at (x, y), button `down` -- what the next
  ## input frame reads, as if the event pump had seen it. The seam for
  ## tests and scripted drags (`pushKeyEvent`'s pointer twin).
  activeApp.pointer = PointerState(x: x, y: y, down: down)

proc pushDoubleClick*() =
  ## Mark a double-click edge on the next input frame -- the same seam
  ## `pushKeyEvent` is for tests and synthetic pointers.
  activeApp.doublePending = true

when withSdl:
  ## --- raw SDL event injection ---------------------------------------------
  ##
  ## The seams *below* `pushKeyEvent`: these put events onto SDL's own queue,
  ## so the `pumpEvents` -> `beginInputFrame` plumbing itself -- event types,
  ## struct layouts, keycode synthesis, the IME-mode gate -- is testable (and
  ## on-screen keyboards or gamepad text could feed input the same way the WM
  ## does). `pushKeyEvent` skips all of that; these do not.

  var pushedTexts: seq[string] = @[]
    ## Keeps the TEXT_INPUT payload strings alive until SDL has polled them;
    ## the queue copies the struct, older SDL versions not the string.

  proc pushSdlKeydown*(scancode, key, modifiers: int32) =
    ## One key press onto the SDL queue, autorepeat-free.
    var ev = default(SDL_Event)
    let k = cast[ptr SDL_KeyboardEvent](addr ev)
    k.typ = EventKeyDown
    k.scancode = scancode
    k.key = key
    k.modifiers = uint16(modifiers)
    k.down = true
    discard SDL_PushEvent(addr ev)

  proc pushSdlTextInput*(text: string) =
    ## One composed-text commit onto the SDL queue -- what the IME path
    ## delivers when `setTextInputEnabled(true)`.
    var ev = default(SDL_Event)
    pushedTexts.add text
    let t = cast[ptr SDL_TextInputEvent](addr ev)
    t.typ = EventTextInput
    t.text = pushedTexts[^1].cstring
    discard SDL_PushEvent(addr ev)

  proc pushSdlWheel*(x, y: float32) =
    ## Scroll-wheel motion onto the SDL queue; the integer counters mirror
    ## the float units, as SDL3 fills them itself.
    var ev = default(SDL_Event)
    let w = cast[ptr SDL_MouseWheelEvent](addr ev)
    w.typ = EventMouseWheel
    w.x = x
    w.y = y
    w.integerX = int32(x)
    w.integerY = int32(y)
    discard SDL_PushEvent(addr ev)

  proc pushSdlMotion*(x, y: float32; down = false) =
    ## A pointer move onto the SDL queue -- what the frame pacer's motion
    ## filter sees from a real mouse.
    var ev = default(SDL_Event)
    let m = cast[ptr SDL_MouseMotionEvent](addr ev)
    m.typ = EventMouseMotion
    m.x = x
    m.y = y
    m.state = if down: ButtonLeftMask else: 0'u32
    discard SDL_PushEvent(addr ev)

  proc pushSdlResize*(w, h: int32) =
    ## A drawable-size change onto the SDL queue: one step of a live resize.
    var ev = default(SDL_Event)
    let e = cast[ptr SDL_WindowEvent](addr ev)
    e.typ = EventWindowPixelResized
    e.data1 = w
    e.data2 = h
    discard SDL_PushEvent(addr ev)

  proc pushSdlQuit*() =
    ## A quit event onto the SDL queue -- ends the `start` loop through the
    ## same path a window-manager close takes.
    var ev = default(SDL_Event)
    let q = cast[ptr SDL_CommonEvent](addr ev)
    q.typ = EventQuit
    discard SDL_PushEvent(addr ev)

proc drawFrame(app: var PlatformApplication; render: FrameFn): bool  =
  ## Run the render hook; present only when it painted something (see
  ## `pacing.requestPresent`) and the window can show it. Returns whether
  ## a present happened.
  render()
  if terminalMode():
    return presentRequested()   # the renderer wrote the changed cells
  when withSdl:
    if presentRequested() and app.visible:
      sdlHandle(SDL_RenderPresent(app.renderer.raw), "SDL_RenderPresent()")
      return true
  return false

proc waitFor(app: PlatformApplication; ns: int64) =
  ## Sleep until an event arrives or `ns` passes (`Never`: until an event).
  ## The event stays queued for the next `pumpEvents`. In the terminal the
  ## events are the watched descriptors turning readable (see `fdwatch`).
  if terminalMode():
    waitFds(if ns == Never: -1'i64 else: ns)
    return
  when withSdl:
    if ns == Never:
      discard SDL_WaitEventTimeout(nil, -1'i32)
    elif ns >= 2_000_000'i64:
      # ms granularity: wake a little early and finish on the precise delay
      discard SDL_WaitEventTimeout(nil, int32((ns - 1_000_000'i64) div 1_000_000'i64))
    elif ns > 0:
      SDL_DelayNS(uint64(ns))

proc pumpEvents(app: var PlatformApplication) =
  ## Take in what arrived since the last pump: the descriptors that turned
  ## readable in the terminal (key presses, mouse reports, resizes, and any
  ## other watched fd), SDL's queue and layer-surface configures in a window.
  if terminalMode():
    waitFds(0)
    runReadyFds()
    return
  when withSdl:
    pumpSdlEvents(app)
    pumpLayer(app)

proc pumpEvents*() =
  ## The game loop's seam: drain SDL's queue into the platform app once per
  ## frame -- pointer, keys, wheel, resizes, close requests -- without the
  ## `start` loop. Paired with `quitAsked` and, offscreen, the
  ## `initializeOffscreen` picture; a host that owns window and present
  ## pumps this instead of polluting the queue with a second reader.
  pumpEvents(activeApp)

var statsDebug = getEnv("ELLIPSE_FRAME_STATS") != ""
  ## When set, the loop logs once per second what the pacer did: frames,
  ## presents, why each frame woke, repainted pixels.

proc reportStats(lastReport: var int64) =
  if not statsDebug:
    return
  let now = monoNow()
  if now - lastReport < NsPerSec:
    return
  let st = takeStats()
  let secs = float64(now - lastReport) / float64(NsPerSec)
  info "frames: ", $st.frames, " presents: ", $st.presents,
    " (input ", $st.inputWakes, ", timer ", $st.timerWakes,
    ", anim ", $st.animWakes, ", resize ", $st.resizeFrames,
    ") repaint px: ", $st.damagePx, " over ", $secs, "s"
  lastReport = now

proc start*(update: FrameFn; render: FrameFn)  =
  ## The app loop. It sleeps until the pacer wants a frame -- input, a
  ## widget's refresh deadline, an animation, a resize gesture (see
  ## `pacing`) -- then runs exactly one `update` (input + layout) and one
  ## `render`, presenting only when the renderer painted. Frames never run
  ## faster than the display refreshes.
  activeApp.running = true
  updateRefreshPeriod(activeApp)
  var lastReport = monoNow()
  while activeApp.running:
    pumpEvents(activeApp)
    if not activeApp.running:
      break
    var now = monoNow()
    if not frameWanted(now):
      if overlayWanted(now):
        # Render-only pass for a debug overlay: the app does not run.
        beginOverlayPass()
        discard drawFrame(activeApp, render)
        endOverlayPass()
        continue
      waitFor(activeApp, idleWait(now))
      reportStats(lastReport)
      continue
    let earliest = earliestFrameStart(activeApp.vsync)
    if now < earliest:
      waitFor(activeApp, earliest - now)
      continue
    beginFrame(now)
    update()
    let presented = drawFrame(activeApp, render)
    endFrame(presented)
    reportStats(lastReport)
