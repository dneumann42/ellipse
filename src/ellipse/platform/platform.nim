{.passL: "-lSDL3 -no-pie".}

import std/[monotimes, strutils, envvars]

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

const
  ## SDL3 scancodes for the keys the UI edits with (USB HID usage page 0x07).
  ScanEnter = 40'i32
  ScanEscape = 41'i32
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
  ## The chords a text app binds beyond letters: minus(45), equals(46) and
  ## the digits 1..9,0 (30..39); with Ctrl they arrive as `kevLetter`
  ## carrying the *unshifted meaning* char ('-', '+', '1'..'9', '0').
  ScanMinus = 45'i32
  ScanEquals = 46'i32
  ScanDigit1 = 30'i32
  ScanDigit0 = 39'i32
  ## Keypad minus / plus, same `kevLetter` treatment as the chords above.
  ScanKPMinus = 86'i32
  ScanKPPlus = 87'i32
  ## QWERTY home-row letters, as SDL3 scancodes: A..Z run 4..29, so a
  ## scancode in this range maps to `chr('a' + scancode - 4)`.
  ScanA = 4'i32
  ScanZ = 29'i32
  ## SDL3 keymods: Shift = LSHIFT | RSHIFT, Ctrl = LCTRL | RCTRL,
  ## Alt = LALT | RALT.
  ModShift = 0x00000003'i32
  ModCtrl = 0x000000C0'i32
  ModAlt = 0x00000300'i32

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
proc SDL_SetAppMetadata(appname, appversion, appidentifier: cstring): bool {.importc: "SDL_SetAppMetadata", header: "<SDL3/SDL.h>".}
proc SDL_CreateWindowAndRenderer(title: cstring; width, height: int32; flags: uint32; window: ptr ptr SDL_Window; renderer: ptr ptr SDL_Renderer): bool {.importc: "SDL_CreateWindowAndRenderer", header: "<SDL3/SDL.h>".}
proc SDL_StartTextInput(win: ptr SDL_Window): bool {.importc: "SDL_StartTextInput", header: "<SDL3/SDL.h>".}
proc SDL_StopTextInput(win: ptr SDL_Window): bool {.importc: "SDL_StopTextInput", header: "<SDL3/SDL.h>".}
proc SDL_GetCurrentVideoDriver(): cstring {.importc: "SDL_GetCurrentVideoDriver", header: "<SDL3/SDL.h>".}
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
proc SDL_PollEvent(event: ptr SDL_Event): bool {.importc: "SDL_PollEvent", header: "<SDL3/SDL.h>".}
proc SDL_PushEvent(event: ptr SDL_Event): bool {.importc: "SDL_PushEvent", header: "<SDL3/SDL.h>".}
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
  KeyEventKind* = enum
    ## What a `KeyEvent` carries. Printable input arrives as `kevText`
    ## (SDL text events, keyboard-layout independent); the rest are the
    ## navigation keys the UI widgets edit with. Ctrl/Alt + a letter (the
    ## Emacs-style editing chords) arrive as `kevLetter` with `ch` set --
    ## and so do the Ctrl/Alt chords on '-', '+' and the digits, carrying
    ## that char. `kevNone` marks ignored keys and never enters the queue.
    kevNone, kevText, kevLetter, kevBackspace, kevDelete, kevLeft, kevRight,
    kevUp, kevDown, kevHome, kevEnd, kevEnter, kevEscape,
    kevPageUp, kevPageDown,
    kevF1, kevF2, kevF3, kevF4, kevF5, kevF6,
    kevF7, kevF8, kevF9, kevF10, kevF11, kevF12

  KeyEvent* = object
    kind*: KeyEventKind
    shift*: bool
    ctrl*: bool
    alt*: bool
    ch*: char          ## kevLetter only: the lowered letter of the chord
    text*: string      ## kevText only: the composed string of one keypress

type
  PlatformApplication* = object
    window: Window
    renderer: Renderer
    pointer: PointerState
    width, height: float32
    running: bool
    keyPending: seq[KeyEvent]   ## events pumped since the last input frame
    keyFrame: seq[KeyEvent]     ## the events `keyEvents()` hands to widgets
    wheelPending: tuple[x, y: float32]
    wheelFrame: tuple[x, y: float32]
    doublePending: bool         ## a left-button click with SDL's click
    doubleFrame: bool           ## counter >= 2, per input frame

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

var inputDebug = getEnv("ELLIPSE_INPUT_DEBUG") != ""
  ## When set, pumpEvents logs every raw SDL event (type + key fields),
  ## revealing exactly what the platform backend delivers.

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
  # NOTE: text input (SDL_StartTextInput / the IME path) is deliberately NOT
  # started here. SDL >= 3.4 only emits SDL_EVENT_TEXT_INPUT once it is on --
  # and while it is on, active input methods (X11/ibus, Wayland text-input-v3)
  # may consume the raw key presses, killing Backspace/arrows/Enter. So the
  # default mode derives printable characters from the keydown events'
  # keycodes themselves (see keyEventFor); `setTextInputEnabled(true)` opts
  # into the IME path when full international composition is wanted.
  activeApp.width = 1280.0
  activeApp.height = 720.0
  if inputDebug:
    discard info("sdl video driver: ", fromCString(SDL_GetCurrentVideoDriver()))

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
  if activeApp.window.raw != nil:
    if enabled:
      discard SDL_StartTextInput(activeApp.window.raw)
    else:
      discard SDL_StopTextInput(activeApp.window.raw)

proc textInputEnabled*(): bool =
  textImeActive

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

proc keyEventFor(scancode, key, modifiers: int32): KeyEvent =
  ## Maps a keydown to a `KeyEvent`; unknown keys yield `kevNone`.
  ## Ctrl/Alt + letter becomes a `kevLetter` chord -- and so do Ctrl/Alt
  ## chords on '-', '+', the keypad +/-. and the digit row, carrying that
  ## char. The function row arrives as `kevF1`..`kevF12`, PgUp/PgDn as
  ## `kevPageUp`/`kevPageDown`. With the IME path off, printable keys also
  ## synthesize a `kevText` from the event's keycode -- the platform
  ## keymap already resolved the layout, shift and dead keys into it --
  ## so text entry works without StartTextInput stealing raw key presses
  ## from an input method.
  result = KeyEvent(kind: kevNone,
    shift: (modifiers and ModShift) != 0,
    ctrl: (modifiers and ModCtrl) != 0,
    alt: (modifiers and ModAlt) != 0)
  case scancode
  of ScanEnter, ScanKeypadEnter: result.kind = kevEnter
  of ScanEscape: result.kind = kevEscape
  of ScanBackspace: result.kind = kevBackspace
  of ScanDelete: result.kind = kevDelete
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
    if scancode >= ScanA and scancode <= ScanZ and (result.ctrl or result.alt):
      result.kind = kevLetter
      result.ch = char(ord('a') + int(scancode - ScanA))
    elif result.ctrl or result.alt:
      # The chords a text app binds beyond letters: minus, equals (delivered
      # as '+', its shifted meaning), the keypad +/-. and the digit row.
      case scancode
      of ScanMinus, ScanKPMinus:
        result.kind = kevLetter
        result.ch = '-'
      of ScanEquals, ScanKPPlus:
        result.kind = kevLetter
        result.ch = '+'
      of ScanDigit1 .. ScanDigit0:
        result.kind = kevLetter
        # 30..38 are '1'..'9'; 39 is '0' -- wrap the tenth step back.
        result.ch = char(ord('0') + (int(scancode - ScanDigit1) + 1) mod 10)
      else:
        discard
    elif not result.ctrl and not result.alt and not textImeActive:
      var cp = key
      if cp == 0:   # some backends leave `key` unset; consult the keymap
        # key_event=false = full modifier translation (shift applies to all
        # layers); with true, SDL only applies caps-lock to letters.
        cp = SDL_GetKeyFromScancode(scancode, modifiers, false)
      if cp >= 32 and cp != 127 and (cp and 0x40000000) == 0:
        result.kind = kevText
        result.text = utf8Of(cp)

proc pumpEvents(app: var PlatformApplication) =
  var event = default(SDL_Event)
  while SDL_PollEvent(addr event):
    let kind = cast[ptr SDL_CommonEvent](addr event)[].typ
    if inputDebug:
      let kb = cast[ptr SDL_KeyboardEvent](addr event)[]
      discard info("sdl-event ", $kind, " sc=", $kb.scancode, " key=",
        $kb.key, " mod=", $kb.modifiers)
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
        if e.clicks >= 2:
          app.doublePending = true
    elif kind == EventMouseButtonUp:
      let e = cast[ptr SDL_MouseButtonEvent](addr event)[]
      if e.button == ButtonLeft:
        app.pointer.down = false
    elif kind == EventKeyDown:
      let e = cast[ptr SDL_KeyboardEvent](addr event)[]
      if e.down:   # SDL delivers autorepeat as repeated downs: forward them
        let ev = keyEventFor(e.scancode, e.key, e.modifiers.int32)
        if ev.kind != kevNone:
          app.keyPending.add ev
    elif kind == EventTextInput:
      let e = cast[ptr SDL_TextInputEvent](addr event)[]
      if not e.text.isNil:   # printable input, already keyboard-layout applied
        app.keyPending.add KeyEvent(kind: kevText, text: fromCString(e.text))
    elif kind == EventMouseWheel:
      let e = cast[ptr SDL_MouseWheelEvent](addr event)[]
      app.wheelPending.x += e.x
      app.wheelPending.y += e.y

proc pointerState*(): PointerState =
  ## The pointer as of the most recent event pump; feed it to
  ## `clay.setPointerState` once per update tick.
  activeApp.pointer

proc quit*() =
  ## End the `start` loop at the next iteration -- an app's File > Exit.
  activeApp.running = false

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

proc keyEvents*(): seq[KeyEvent] =
  ## Keyboard/text events collected since the last `beginInputFrame`.
  activeApp.keyFrame

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
  let m = SDL_GetModState().int32
  (ctrl: (m and ModCtrl) != 0, shift: (m and ModShift) != 0,
   alt: (m and ModAlt) != 0)

proc setWindowTitle*(title: string) =
  ## Rename the window. A no-op before `initialize()`.
  if activeApp.window.raw != nil:
    var t = title
    discard SDL_SetWindowTitle(activeApp.window.raw, t.toCString)

proc getClipboard*(): string =
  ## The system clipboard as text; empty when nothing is (or SDL is not
  ## up yet, which is the state headless tests run in).
  if activeApp.window.raw == nil:
    return ""
  let cstr = SDL_GetClipboardText()
  if cstr.isNil:
    return ""
  result = fromCString(cstr)
  SDL_free(cstr)

proc setClipboard*(text: string) =
  ## Put `text` on the system clipboard. No-op before `initialize()`.
  if activeApp.window.raw == nil:
    return
  var t = text
  discard SDL_SetClipboardText(t.toCString)

proc pushKeyEvent*(ev: KeyEvent) =
  ## Feed a synthetic event into the queue -- the seam for tests, on-screen
  ## keyboards and gamepad text input.
  activeApp.keyPending.add ev

proc pushDoubleClick*() =
  ## Mark a double-click edge on the next input frame -- the same seam
  ## `pushKeyEvent` is for tests and synthetic pointers.
  activeApp.doublePending = true

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
  t.text = pushedTexts[^1].toCString
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

proc pushSdlQuit*() =
  ## A quit event onto the SDL queue -- ends the `start` loop through the
  ## same path a window-manager close takes.
  var ev = default(SDL_Event)
  let q = cast[ptr SDL_CommonEvent](addr ev)
  q.typ = EventQuit
  discard SDL_PushEvent(addr ev)

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
