## Development mode: an application process and a display-server process
## sharing one window.
##
## The game loop, the draw commands and all state live in the *application*
## process; the window lives in the *display server*, which mirrors the app's
## frames onto the screen. Both halves talk over one Unix socket
## (`$XDG_RUNTIME_DIR/ellipse-display.sock`, or `ELLIPSE_DISPLAY_SOCKET`),
## exchanging length-prefixed JSON messages:
##
##   - An attached game app (see `platform/sdl.initApp`) still creates its
##     own SDL "gpu" renderer -- on a hidden window it never presents -- so
##     its artist keeps building real GPU batches against a real device and
##     draws exactly as it would on screen. Each frame ends normally, into
##     that hidden swapchain; then the app copies the finished texture to the
##     CPU (`readbackPixels`) and hands the server the pixels. One memcpy
##     and one upload per frame, for now: the copy is the price of keeping
##     the two sides' GPU objects fully separate, so either can die, be
##     rebuilt and reconnect without the other holding a stale handle. The
##     server sends a tick back per presented frame, and the client waits on
##     it before drawing again -- that wait paces the game to the display,
##     exactly where a local vsync present would have.
##   - Input is the server's other stream: key, motion, button, wheel and
##     resize events are forwarded to the attached app, where they land in
##     its own SDL event queue (`pushWireEvent`) and travel through the
##     ordinary pump, so widgets see them whole. A close request quits the
##     *app*, not the window: the window survives the kill-and-relaunch
##     cycle hot-loading needs.
##   - `serveDisplay` opens a window of its own and serves attach requests
##     forever; `ellipse.nim` checks `--display-serve` before the game loop
##     starts. A game sets `cfg.displayMode = DisplayAttached` (or runs with
##     `--display-attach`) to connect instead of opening a window.
##     `make run_display` / `run_attached` wrap both sides.
##   - GUI-kit apps (ellipse_ui) keep their own window for now: this seam is
##     the game kit's.
##
## One slot: one window, one attached app at a time; a second attach takes
## over -- exactly what a relaunched game wants. With nobody attached the
## window shows a waiting field.
##
## POSIX only (the sockets here are Unix-domain); on Windows attached mode
## falls back to local windows and `connectDisplay` returns nil.

import std/[json, os, envvars, strutils, base64, options]

when not defined(windows):
  # `-no-pie`, which every windowed ellipse build already links with (see
  # `platform/platform`), keeps the static binary's layout plain; a
  # display-server build needs no more than SDL itself.
  const LibName* = "libSDL3.so"
import sdl3
import ./errors

when not defined(windows):
  import std/posix
  type Fd* = posix.SocketHandle
    ## A socket descriptor, in the currency std/posix's calls speak.
else:
  type Fd* = int
    ## Nothing dials on Windows; attached mode falls back to local windows.

type
  MsgKind* = enum
    msgHello, msgHelloReply, msgFrame, msgDetach, msgTick, evKey, evKeyUp,
    evMotion, evButton, evWheel, evResize, evQuit

  WireMsg* = object
    ## One message on the wire. Flat fields carry everything: numbers ride
    ## in `num/num2/num3`, packed floats and base64 pixels in `data`.
    ## `kind` says how to read the rest.
    kind*: MsgKind
    text*: string   ## hello: the app title; detach: a reason
    num*, num2*, num3*: int64
    data*: string

  DisplayServer* = ref object
    ## What an attached app holds in place of a window: the connection to
    ## the display server, plus the pixel path it mirrors frames through.
    fd: Fd
    buffer: string
    gone*: bool      ## the peer closed: stop sending, treat input as done
    width*, height*: int32
    title*: string
    windowId: WindowID ## this side's canvas window, to stamp forwarded events
    pendings = 0     ## client-side: frames sent whose tick has not come back
    sizeDirty = false ## a forwarded resize moved the server's window since
                      ## the last `noteUiSize`

const
  MaxMessage = 48 shl 20 ## a full-HD RGBA frame, base64'd, plus JSON slack

proc displaySocketPath*(): string =
  ## The socket both halves meet on: `ELLIPSE_DISPLAY_SOCKET`, else
  ## `$XDG_RUNTIME_DIR/ellipse-display.sock`, else under /tmp by uid.
  let e = getEnv("ELLIPSE_DISPLAY_SOCKET")
  if e.len > 0:
    return e
  let dir = getEnv("XDG_RUNTIME_DIR")
  if dir.len > 0:
    return dir / "ellipse-display.sock"
  when defined(windows):
    "/tmp/ellipse-display.sock"
  else:
    "/tmp/ellipse-display-" & $getuid() & ".sock"

proc attachedUiRequested*(): bool =
  ## `--display-attach` / `ELLIPSE_DISPLAY_ATTACH=1`: a GUI-kit app should
  ## skip its window and mirror its offscreen picture to the display server
  ## instead (see `platform/platform.initialize`). Same contract as the game
  ## kit's `displayAttachedRequested`, kept here so the UI platform needs no
  ## more of `platform/sdl` than this.
  let e = getEnv("ELLIPSE_DISPLAY_ATTACH")
  if e.len > 0 and e != "0" and e != "false" and e != "no":
    return true
  for i in 1 .. paramCount():
    if paramStr(i) == "--display-attach":
      return true
  false

proc packFloats(xs: openArray[float32]): string =
  result = ""
  for i, x in xs:
    if i > 0: result.add ','
    result.add $x

proc unpackFloats(s: string): seq[float32] =
  result = @[]
  if s.len == 0:
    return
  for part in s.split(','):
    result.add (try: parseFloat(part).float32 except: 0'f32)

proc toJson(m: WireMsg): JsonNode =
  %*{
    "k": ord(m.kind),
    "t": m.text,
    "n": m.num,
    "a": m.num2,
    "b": m.num3,
    "d": m.data,
  }

proc fromJson(j: JsonNode): WireMsg =
  result.kind =
    if j.contains("k"): MsgKind(j["k"].getInt.int)
    else: msgHello
  if j.contains("t"): result.text = j["t"].getStr
  if j.contains("n"): result.num = j["n"].getInt
  if j.contains("a"): result.num2 = j["a"].getInt
  if j.contains("b"): result.num3 = j["b"].getInt
  if j.contains("d"): result.data = j["d"].getStr

when not defined(windows):
  # std/posix spells the socket calls in terms of its own handle type.
  proc writeAll(fd: SocketHandle; bytes: openArray[byte]): bool =
    var done = 0
    while done < bytes.len:
      let n = send(fd, unsafeAddr bytes[done], bytes.len - done, MSG_NOSIGNAL.cint)
      if n <= 0:
        return false
      inc done, int(n)
    true

  proc readSome(fd: SocketHandle; sink: var string): bool =
    ## Append whatever is queued (never blocks past it); false once the peer
    ## has closed for good.
    var buf = newSeq[byte](1 shl 17)
    while true:
      let n = recv(fd, addr buf[0], buf.len, 0)
      if n == 0:
        return false # clean EOF
      if n < 0:
        return true # EAGAIN: drained
      for i in 0 ..< int(n):
        sink.add char(buf[i])
      if int(n) < buf.len:
        return true

  proc pollIn(fd: SocketHandle; ms: int): bool =
    var pfd = TPollfd(fd: cint(fd), events: POLLIN.cshort)
    discard poll(addr pfd, Tnfds(1), cint(ms))
    (pfd.revents and POLLIN.cshort) != 0'i16

proc takeMsgAt(fd: SocketHandle, buffer: var string, gone: var bool): Option[WireMsg] =
  while true:
    let nl = buffer.find('\n')
    if nl < 0:
      if buffer.len > MaxMessage:
        gone = true
      return none(WireMsg)
    let size = try: parseInt(buffer[0 ..< nl]) except: -1
    if size < 0 or size > MaxMessage:
      gone = true
      return none(WireMsg)
    if buffer.len < nl + 1 + size:
      return none(WireMsg)
    let body = buffer[nl + 1 ..< nl + 1 + size]
    buffer.delete(0 .. nl + size)
    try:
      return some(fromJson(parseJson(body)))
    except:
      gone = true
      return none(WireMsg)

proc sendMsg(disp: DisplayServer, m: WireMsg): bool =
  ## One framed message out: decimal body length, newline, JSON body.
  when defined(windows):
    false
  else:
    let body = $toJson(m)
    var bytes = newSeq[byte](body.len + 24)
    var pos = 0
    for c in ($body.len & "\n"):
      bytes[pos] = byte(c); inc pos
    for c in body:
      bytes[pos] = byte(c); inc pos
    bytes.setLen(pos)
    let ok = writeAll(disp.fd, bytes)
    if not ok:
      disp.gone = true
    ok

proc recvMsg*(disp: DisplayServer, timeoutMs: int = 0): Option[WireMsg] =
  ## Read until one whole message arrives or `timeoutMs` passes (-1: wait
  ## forever). None means timeout or a dead peer -- `disp.gone` says which.
  when defined(windows):
    none(WireMsg)
  else:
    var waited = 0
    while true:
      let m = takeMsgAt(disp.fd, disp.buffer, disp.gone)
      if m.isSome or disp.gone:
        return m
      if timeoutMs >= 0 and waited >= timeoutMs:
        return none(WireMsg)
      let budget = if timeoutMs < 0: 50 else: min(timeoutMs - waited, 50)
      if pollIn(disp.fd, budget):
        if not readSome(disp.fd, disp.buffer):
          disp.gone = true
          return none(WireMsg)
      if timeoutMs >= 0:
        inc waited, budget

proc dialUnix(path: string): Fd =
  ## Connect to a Unix stream socket; negative when nothing answers there.
  when defined(windows):
    Fd(-1)
  else:
    var sun = Sockaddr_un(sun_family: TSa_Family(AfUnix))
    let n = min(path.len, sun.sun_path.len - 1)
    for i in 0 ..< n:
      sun.sun_path[i] = path[i]
    let fd = socket(AfUnix, SOCK_STREAM, 0.cint)
    if int(fd) < 0:
      return Fd(-1)
    discard fcntl(fd, F_SETFD, FD_CLOEXEC)
    if connect(fd, cast[ptr SockAddr](addr sun), SockLen(sizeof(Sockaddr_un))) != 0:
      discard close(fd)
      return Fd(-1)
    fd

proc listenUnix(path: string): Fd =
  ## Own `path` as a private stream socket; negative when it cannot be made.
  when defined(windows):
    Fd(-1)
  else:
    var sun = Sockaddr_un(sun_family: TSa_Family(AfUnix))
    let n = min(path.len, sun.sun_path.len - 1)
    for i in 0 ..< n:
      sun.sun_path[i] = path[i]
    let fd = socket(AfUnix, SOCK_STREAM, 0.cint)
    if int(fd) < 0:
      return Fd(-1)
    discard fcntl(fd, F_SETFD, FD_CLOEXEC)
    discard unlink(path)
    let old = umask(Mode(0o077))
    let bound = bindSocket(fd, cast[ptr SockAddr](addr sun), SockLen(sizeof(Sockaddr_un)))
    discard umask(old)
    if bound != 0 or listen(fd, 4) != 0:
      discard close(fd)
      return Fd(-1)
    discard chmod(path, Mode(0o600))
    fd

proc acceptOne(fd: Fd): Fd =
  when defined(windows):
    Fd(-1)
  else:
    let c = accept(fd, nil, nil)
    if int(c) >= 0:
      discard fcntl(c, F_SETFD, FD_CLOEXEC)
    c

proc connectDisplay*(): DisplayServer =
  ## Reach the display server, or nil when none is listening.
  let fd = dialUnix(displaySocketPath())
  if int(fd) < 0:
    return nil
  DisplayServer(fd: fd)

proc handshake*(disp: DisplayServer, title: string): bool =
  ## Greet the server; it replies with the window size to render for.
  if not disp.sendMsg(WireMsg(kind: msgHello, text: title)):
    return false
  let reply = disp.recvMsg(5000)
  if reply.isNone:
    return false
  let m = reply.get()
  if m.kind != msgHelloReply:
    return false
  disp.width = int32(max(m.num, 0))
  disp.height = int32(max(m.num2, 0))
  disp.title = m.text
  true

proc pixelSize*(disp: DisplayServer): tuple[w, h: int32] =
  ## The server's window, as last reported.
  (disp.width, disp.height)

proc noteSize*(disp: DisplayServer, w, h: int32) =
  ## The client saw a forwarded resize: keep `pixelSize` honest, and leave
  ## `sizeDirty` for `noteUiSize` to report once.
  if w > 0 and h > 0:
    if disp.width != w or disp.height != h:
      disp.sizeDirty = true
    disp.width = w
    disp.height = h

proc mirrorFrame*(disp: DisplayServer, rgba: openArray[uint8], w, h: uint32): bool =
  ## One mirrored frame: the finished picture, RGBA8 row-major, base64'd.
  if int(w) * int(h) * 4 != rgba.len:
    return false
  var bytes = newString(rgba.len)
  copyMem(addr bytes[0], unsafeAddr rgba[rgba.low], rgba.len)
  inc disp.pendings
  disp.sendMsg(WireMsg(kind: msgFrame, num: int64(w), num2: int64(h),
    data: base64.encode(bytes)))

proc noteTick*(disp: DisplayServer) =
  ## The server answered this frame's tick early (a still scene): let the
  ## next `beginServedFrame` go straight through instead of waiting.
  if disp.pendings > 0:
    dec disp.pendings

proc owedTick(disp: DisplayServer): bool =
  ## Server-side view of the same ledger: a frame arrived whose tick has not
  ## gone back yet.
  disp.pendings > 0

proc pollInput*(disp: DisplayServer): seq[WireMsg] =
  ## Every whole message waiting right now (non-blocking). Empty with
  ## `disp.gone` set means the server died.
  result = @[]
  when not defined(windows):
    while not disp.gone:
      let m = disp.recvMsg(0)
      if m.isNone:
        break
      result.add m.get()

proc closeDisplay*(disp: DisplayServer) =
  ## Say goodbye and drop the connection; the server keeps the window up.
  if int(disp.fd) >= 0 and not disp.gone:
    discard disp.sendMsg(WireMsg(kind: msgDetach, text: "client closed"))
  when not defined(windows):
    if int(disp.fd) >= 0:
      discard close(disp.fd)

type
  ServedFrame* = object
    ## What the display server says when asked for a frame: the moment to
    ## present at (its swapchain wait paces the attached app the way a real
    ## present would), any size change it noticed, and whether it wants this
    ## app to stop.
    width*, height*: uint32
    resized*: bool
    quitAsked*: bool
    gone*: bool        ## the server died: fall back, do not stall


proc pushWireEvent(ev: WireMsg, windowId: WindowID) =
  ## Re-materialise one forwarded event in this process's SDL queue,
  ## stamped with *our* window id: from here the ordinary pump owns it --
  ## keys, motion, buttons, wheel, resizes, the works.
  var e = default(Event)
  case ev.kind
  of evKey, evKeyUp:
    e.`type` = if ev.kind == evKey: EVENT_KEY_DOWN else: EVENT_KEY_UP
    e.key.windowID = windowId
    e.key.scancode = Scancode(ev.num.int32)
    e.key.key = Keycode(ev.num2.uint32)
    e.key.down = (ev.num3 and 1) != 0
    e.key.repeat = ((ev.num3 shr 1) and 1) != 0
    e.key.`mod` = Keymod(uint16(ev.num3 shr 16))
  of evMotion:
    let f = unpackFloats(ev.data)
    e.`type` = EVENT_MOUSE_MOTION
    e.motion.windowID = windowId
    if f.len >= 3:
      e.motion.x = f[0]; e.motion.y = f[1]
      e.motion.state = MouseButtonFlags(f[2].uint32)
  of evButton:
    let f = unpackFloats(ev.data)
    e.`type` = if ev.num2 != 0: EVENT_MOUSE_BUTTON_DOWN else: EVENT_MOUSE_BUTTON_UP
    e.button.windowID = WindowID(uint32((ev.num3 shr 16) and 0xFFFF_FFFF))
    e.button.button = uint8(ev.num)
    e.button.down = ev.num2 != 0
    e.button.clicks = uint8(ev.num3 and 0xFF)
    if f.len >= 2:
      e.button.x = f[0]; e.button.y = f[1]
  of evWheel:
    let f = unpackFloats(ev.data)
    e.`type` = EVENT_MOUSE_WHEEL
    e.wheel.windowID = windowId
    if f.len >= 2:
      e.wheel.x = f[0]; e.wheel.y = f[1]
  of evResize:
    e.`type` = EVENT_WINDOW_PIXEL_SIZE_CHANGED
    e.window.windowID = windowId
    e.window.data1 = int32(ev.num)
    e.window.data2 = int32(ev.num2)
  else:
    return
  discard pushEvent(e)

proc setWindowId*(disp: DisplayServer, id: WindowID) =
  ## Forwarded events are re-stamped with this id once the client has made
  ## its canvas window; see `sdl.initApp`.
  disp.windowId = id

proc beginServedFrame*(disp: DisplayServer): ServedFrame =
  ## The client's beat of the frame cycle: drain every message waiting from
  ## the server -- forwarded input lands in this process's SDL queue, sizes
  ## are remembered, quits are flagged -- then, when a frame is still owed
  ## its tick, block until that tick arrives. That wait paces the app to the
  ## display, exactly where a real present would have. With no server there
  ## is nothing to wait on: report it gone and let the caller run unpaced.
  var acc = ServedFrame(width: uint32(disp.width), height: uint32(disp.height))
  template absorbBody(ev: WireMsg) =
    case ev.kind
    of evKey, evKeyUp, evMotion, evButton, evWheel:
      pushWireEvent(ev, disp.windowId)
    of evResize:
      disp.noteSize(int32(ev.num), int32(ev.num2))
      acc.width = uint32(ev.num)
      acc.height = uint32(ev.num2)
      acc.resized = true
    of evQuit:
      acc.quitAsked = true
    of msgDetach:
      disp.gone = true
    of msgTick:
      disp.noteTick()
    else:
      discard
  when defined(windows):
    acc.gone = true
  else:
    while true:
      let m = disp.recvMsg(0)
      if m.isNone:
        break
      let ev = m.get()
      absorbBody(ev)
    if disp.gone:
      acc.gone = true
    else:
      # Wait out any owed tick before drawing again: at most one frame in
      # flight, so the hidden swapchain never runs ahead of the screen.
      while disp.pendings > 0 and not disp.gone:
        let tick = disp.recvMsg(-1)
        if tick.isSome:
          let ev = tick.get()
          absorbBody(ev)
        elif disp.gone:
          acc.gone = true
  result = acc

## --- attached clients without a window of their own ----------------------------
##
## The GUI kit (`ellipse_ui`) needs the server's window but paints its UI
## offscreen, so it takes no canvas of its own: it opens nothing, pumps the
## forwarded input itself, and hands snapshots of its offscreen picture over
## the socket each frame. `initAttachedUi` is the whole handshake; `pumpEvents`
## drains what came since the last call and reports whether the app should
## quit (the server died, or someone closed at the window); `sendSnapshot`
## mirrors one finished picture.

proc initAttachedUi*(title: string, width, height: int32): DisplayServer =
  ## Connect and greet the server for a windowless client: returns nil when
  ## no server answers. `width`/`height` are the client's preferred size;
  ## the server's live window size wins when it differs.
  let disp = connectDisplay()
  if disp == nil:
    return nil
  if not disp.handshake(title):
    closeDisplay(disp)
    return nil
  disp

proc pumpEvents*(disp: DisplayServer): bool =
  ## Drain everything waiting from the server into this process's SDL event
  ## queue and report whether the app should stop: true when the connection
  ## died or the person at the window asked to quit. A windowed client uses
  ## `beginServedFrame` (paced); this variant never blocks, for loops that
  ## sleep in SDL's event queue themselves.
  var stop = false
  for ev in disp.pollInput():
    case ev.kind
    of evKey, evKeyUp, evMotion, evButton, evWheel, evResize:
      pushWireEvent(ev, disp.windowId)
    of evQuit:
      stop = true
    of msgDetach:
      stop = true
    else:
      discard
  disp.gone or stop

proc sendSnapshot*(disp: DisplayServer, rgba: openArray[uint8], w, h: uint32): bool =
  ## Mirror one finished picture. Unlike the paced path, no tick is owed: a
  ## windowless client drives its frames from the pacer, not from waits.
  if int(w) * int(h) * 4 != rgba.len or disp.gone:
    return false
  var bytes = newString(rgba.len)
  copyMem(addr bytes[0], unsafeAddr rgba[rgba.low], rgba.len)
  disp.sendMsg(WireMsg(kind: msgFrame, num: int64(w), num2: int64(h),
    data: base64.encode(bytes)))

proc noteUiSize*(disp: DisplayServer): tuple[w, h: int32, changed: bool] =
  ## The size the server last reported, and whether it moved since the
  ## previous call -- the seam a windowless client resizes its offscreen
  ## picture on.
  result.w = disp.width
  result.h = disp.height
  result.changed = disp.sizeDirty
  disp.sizeDirty = false


## --- the server ------------------------------------------------------------------

type
  DisplaySlot = ref object
    ## The window, its renderer, and whoever is attached to it.
    window: Window
    renderer: Renderer
    width, height: int32
    title: string
    listenFd: Fd
    client: DisplayServer
    quitAsked: bool

var serverSlot: DisplaySlot

proc paintWaiting(s: DisplaySlot) =
  ## No app attached: a dark field with a bar saying the slot is free.
  discard setRenderDrawColor(s.renderer, 18'u8, 20'u8, 26'u8, 255'u8)
  discard renderClear(s.renderer)
  discard setRenderDrawColor(s.renderer, 90'u8, 96'u8, 110'u8, 255'u8)
  var r = FRect(x: float32(s.width) * 0.2f, y: float32(s.height) * 0.45f,
                w: float32(s.width) * 0.6f, h: 3.0f)
  discard renderFillRect(s.renderer, r)
  discard renderPresent(s.renderer)

proc mirrorFrame(s: DisplaySlot, m: WireMsg) =
  ## Put one mirrored picture on the window: upload the decoded RGBA8 as a
  ## streaming texture, stretch it across, present, forget it.
  let pixels =
    try: base64.decode(m.data)
    except: ""
  let w = int(m.num)
  let h = int(m.num2)
  if w <= 0 or h <= 0 or pixels.len < w * h * 4:
    return
  let tex = createTexture(s.renderer, PIXELFORMAT_RGBA8888, TEXTUREACCESS_STREAMING,
                          int32(w), int32(h))
  if tex == nil:
    return
  defer: destroyTexture(tex)
  if not updateTexture(tex, nil, cast[ptr uint8](pixels[0].addr), cint(w * 4)):
    return
  discard setTextureScaleMode(tex, SCALE_MODE_NEAREST)
  discard setRenderTarget(s.renderer, nil)
  discard renderTexture(s.renderer, tex, nil, nil)
  discard renderPresent(s.renderer)

proc attachClient(s: DisplaySlot, fd: Fd): bool =
  ## Handshake with a fresh client; false (socket closed) when misbehaving.
  let tmp = DisplayServer(fd: fd)
  let hello = tmp.recvMsg(5000)
  if hello.isNone or hello.get().kind != msgHello:
    when not defined(windows):
      discard close(fd)
    return false
  if s.client != nil and int(s.client.fd) >= 0:
    # one slot: the newcomer takes over, the incumbent is dropped
    when not defined(windows):
      discard close(s.client.fd)
    s.client = nil
  s.client = tmp
  s.title = hello.get().text
  discard setWindowTitle(s.window, ("Ellipse display · " & s.title).cstring)
  var w, h: cint
  discard getWindowSizeInPixels(s.window, w, h)
  s.width = int32(w)
  s.height = int32(h)
  discard tmp.sendMsg(WireMsg(kind: msgHelloReply, text: s.title,
    num: int64(s.width), num2: int64(s.height)))
  true

proc forwardEvent(s: DisplaySlot, ev: Event) =
  ## One SDL event, translated into the compact wire form the client pumps
  ## back into its own queue. Keys fold down/repeat/modifiers into num3;
  ## clicks ride num3's high bits; positions go packed-float style.
  let c = s.client
  if c == nil or c.gone:
    return
  case ev.`type`
  of EVENT_KEY_DOWN, EVENT_KEY_UP:
    let flags = int64(if ev.key.down: 1 else: 0) or
      (int64(if ev.key.repeat: 1 else: 0) shl 1) or
      (int64(ev.key.`mod`.uint16) shl 16)
    discard c.sendMsg(WireMsg(
      kind: if ev.`type` == EVENT_KEY_DOWN: evKey else: evKeyUp,
      num: int64(ev.key.scancode.int32), num2: int64(ev.key.key.int32),
      num3: flags))
  of EVENT_MOUSE_MOTION:
    discard c.sendMsg(WireMsg(kind: evMotion,
      data: packFloats([ev.motion.x, ev.motion.y, ev.motion.state.float32])))
  of EVENT_MOUSE_BUTTON_DOWN, EVENT_MOUSE_BUTTON_UP:
    discard c.sendMsg(WireMsg(kind: evButton, num: int64(ev.button.button),
      num2: int64(if ev.button.down: 1 else: 0),
      num3: (int64(ev.button.windowID.uint32) shl 16) or int64(ev.button.clicks),
      data: packFloats([ev.button.x, ev.button.y])))
  of EVENT_MOUSE_WHEEL:
    discard c.sendMsg(WireMsg(kind: evWheel,
      data: packFloats([ev.wheel.x, ev.wheel.y])))
  else:
    discard

proc pumpClientFrames(s: DisplaySlot) =
  ## Drain what the attached client sent since the last pass; a frame
  ## message mirrors and presents, and the tick that follows it releases the
  ## client to draw the next. Only the newest picture of a batch is shown --
  ## an app faster than the display simply gets paced. Dead clients leave
  ## the slot empty.
  if s.client == nil or s.client.gone:
    return
  var latest: Option[WireMsg] = none(WireMsg)
  while true:
    let m = s.client.recvMsg(0)
    if m.isNone:
      break
    case m.get().kind
    of msgFrame:
      latest = m
    of msgDetach:
      s.client.gone = true
    else:
      discard
  if latest.isSome:
    s.mirrorFrame(latest.get())
  if s.client != nil and not s.client.gone and owedTick(s.client):
    # The client waits on a tick for every frame it sent; answer once per
    # pass so at most one picture is in flight, but the loop always turns.
    discard s.client.sendMsg(WireMsg(kind: msgTick))
  if s.client != nil and s.client.gone:
    when not defined(windows):
      discard close(s.client.fd)
    s.client = nil
    discard setWindowTitle(s.window, "Ellipse display · detached".cstring)

proc stepServerOnce(s: DisplaySlot, timeoutMs: int) =
  ## One pass of the server loop: accept a client, pump its frames, service
  ## the window's own events.
  when not defined(windows):
    var lfds = [TPollfd(fd: cint(s.listenFd), events: POLLIN.cshort)]
    if poll(addr lfds[0], Tnfds(1), 0.cint) > 0 and
        (lfds[0].revents and POLLIN.cshort) != 0'i16:
      let c = acceptOne(s.listenFd)
      if int(c) >= 0:
        discard s.attachClient(c)
    s.pumpClientFrames()
  var ev = default(Event)
  while pollEvent(ev):
    case ev.`type`
    of EVENT_WINDOW_PIXEL_SIZE_CHANGED:
      s.width = ev.window.data1
      s.height = ev.window.data2
      if s.client != nil and not s.client.gone:
        discard s.client.sendMsg(WireMsg(kind: evResize, num: int64(s.width),
          num2: int64(s.height)))
    of EVENT_MOUSE_MOTION, EVENT_MOUSE_BUTTON_DOWN, EVENT_MOUSE_BUTTON_UP,
       EVENT_MOUSE_WHEEL, EVENT_KEY_DOWN, EVENT_KEY_UP:
      s.forwardEvent(ev)
    of EVENT_QUIT, EVENT_WINDOW_CLOSE_REQUESTED, EVENT_TERMINATING:
      if s.client != nil and not s.client.gone:
        # closing belongs to the game: ask the app to quit, keep the window
        discard s.client.sendMsg(WireMsg(kind: evQuit))
      else:
        s.quitAsked = true
    else:
      discard

proc serveDisplay*(title: string; width, height: int32) {.noreturn.} =
  ## Open the dev window and serve it forever: attach requests, mirrored
  ## frames, forwarded input. Called instead of the game loop when the app
  ## runs as `--display-serve`; the window then hosts any game that attaches.
  if getEnv("WAYLAND_DISPLAY").len > 0 and
      getEnv("SDL_VIDEODRIVER").len == 0 and
      getEnv("SDL_VIDEO_DRIVER").len == 0:
    discard setHint("SDL_VIDEO_DRIVER", "wayland")
  if not sdl3.init(INIT_VIDEO or INIT_GAMEPAD):
    raiseSdlError("display server: SDL init")
  var t = title
  if t.len == 0: t = "Ellipse"
  let win = createWindow((t & " display").cstring, width.cint, height.cint,
    WINDOW_RESIZABLE or WINDOW_HIGH_PIXEL_DENSITY)
  if win.isNil:
    raiseSdlError("display server: window")
  let ren = createRenderer(win, cstring("gpu"))
  if ren.isNil:
    raiseSdlError("display server: renderer")
  discard showWindow(win)
  var w, h: cint
  discard getWindowSizeInPixels(win, w, h)
  serverSlot = DisplaySlot(window: win, renderer: ren,
    width: int32(w), height: int32(h), title: t & " display")
  when not defined(windows):
    serverSlot.listenFd = listenUnix(displaySocketPath())
    if int(serverSlot.listenFd) < 0:
      raise EllipseError.newException(
        "display server: cannot listen on " & displaySocketPath())
  echo "ellipse display: serving on ", displaySocketPath()
  while not serverSlot.quitAsked:
    serverSlot.stepServerOnce(if serverSlot.client == nil: 60 else: 8)
    if serverSlot.client == nil:
      serverSlot.paintWaiting()
      sdl3.delay(16'u32)
  echo "ellipse display: closed"
  sdl3.quit()
  quit(0)
