## Socket pairs exercise the actual display protocol without binding a socket.
when defined(displayTestWrite):
  # Restricted runners block send(); write() on a socket pair exercises the
  # same framed stream. Ordinary runs use the production send() path.
  import std/posix
  proc send(fd: SocketHandle; data: pointer; size: int; flags: cint): int =
    posix.write(cint(fd), data, size)

include ../../src/ellipse/platform/display
import ./testutils

putEnv("SDL_VIDEODRIVER", "offscreen")
doAssert sdl3.init(INIT_VIDEO)
let win = createWindow("test", 16, 12, WINDOW_RESIZABLE)
let surface = createSurface(16, 12, PIXELFORMAT_ARGB8888)
let ren = createSoftwareRenderer(surface)
var fds: array[2, cint]
doAssert socketpair(AfUnix, SOCK_STREAM, 0, fds) == 0
let client = DisplayServer(fd: Fd(fds[0]))
let server = DisplayServer(fd: Fd(fds[1]))
let slot = DisplaySlot(window: win, renderer: ren, width: 16, height: 12,
                       listenFd: Fd(-1), client: server)

var pixels = newSeq[uint8](8 * 8 * 4)
for i in 0 ..< 64:
  pixels[i * 4 + 2] = 255 # ARGB8888 in little-endian memory: red
  pixels[i * 4 + 3] = 255
expect(client.sendSnapshot(pixels, 8, 8), "send first frame")
slot.pumpClientFrames()
let firstTexture = slot.texture
let raw = cast[ptr UncheckedArray[uint32]](surface.pixels)
expect(raw[0] == 0xFFFF0000'u32, "server displays first frame in correct format")
expect(raw[15] == 0xFF12141A'u32, "server does not stretch stale pixels")
for i in 0 ..< 64:
  pixels[i * 4 + 2] = 0
  pixels[i * 4] = 255
expect(client.sendSnapshot(pixels, 8, 8), "send changed frame")
slot.pumpClientFrames()
expect(raw[0] == 0xFF0000FF'u32, "server displays changed pixels")
expect(slot.texture == firstTexture, "same-size frames reuse the display texture")
var gone = false
let frameHeader = "F 1 1 " & $int64(PIXELFORMAT_ARGB8888) & " 4\n"
var fragment = frameHeader & "\x00\x01"
expect(takeMsgAt(Fd(-1), fragment, gone).isNone and not gone,
  "partial binary frame waits for remaining bytes")
fragment.add "\x02\xFF"
let complete = takeMsgAt(Fd(-1), fragment, gone)
expect(complete.isSome and complete.get().data == "\x00\x01\x02\xFF",
  "binary pixels survive framing")
fragment = "F 2 2 0 4\n1234"
discard takeMsgAt(Fd(-1), fragment, gone)
expect(gone, "reject inconsistent raw frame dimensions")
client.rawFrames = false
expect(client.sendSnapshot(pixels, 8, 8), "legacy fallback sends")
slot.pumpClientFrames()
expect(raw[0] == 0xFF0000FF'u32, "legacy frame path remains supported")
client.rawFrames = true
var padded = newSeq[uint8](8 * (8 * 4 + 4))
for y in 0 ..< 8:
  copyMem(addr padded[y * 36], addr pixels[y * 32], 32)
  padded[y * 36 + 32] = 123
expect(client.sendSurfaceSnapshot(addr padded[0], 36, 8, 8), "send padded surface rows")
slot.pumpClientFrames()
expect(raw[7 * 16 + 7] == 0xFF0000FF'u32, "row padding is excluded from frame pixels")
discard server.sendMsg(WireMsg(kind: evResize, num: 16, num2: 12, num3: 6_944_444))
discard client.pumpEvents()
expect(client.refreshNs == 6_944_444, "client receives a 144 Hz display period")
discard client.noteUiSize()

# Exercise server SDL event -> wire -> client size tracking.
var event = default(Event)
event.`type` = EVENT_WINDOW_PIXEL_SIZE_CHANGED
event.window.windowID = getWindowID(win)
event.window.data1 = 40
event.window.data2 = 25
discard pushEvent(event)
slot.stepServerOnce(0)
discard client.pumpEvents()
let size = client.noteUiSize()
expect(size.changed and size.w == 40 and size.h == 25,
  "server resize reaches client size tracking")
closeDisplay(client)
slot.pumpClientFrames()
expect(slot.client == nil, "client disconnect releases slot")
if slot.texture != nil: destroyTexture(slot.texture)
destroyRenderer(ren)
destroySurface(surface)
destroyWindow(win)
sdl3.quit()
finish("display transport")

when defined(displayBenchmark):
  # Wire CPU only; excludes rendering, upload and actual presentation.
  let payload = repeat('x', 1280 * 720 * 4)
  const rounds = 12
  var started = cpuTime()
  for i in 0 ..< rounds:
    let body = $toJson(WireMsg(kind: msgFrame, num: 1280, num2: 720,
      data: base64.encode(payload)))
    var wire = $body.len & "\n" & body
    var dead = false
    let decoded = takeMsgAt(Fd(-1), wire, dead)
    doAssert base64.decode(decoded.get().data).len == payload.len
  let legacyMs = (cpuTime() - started) * 1000 / rounds
  started = cpuTime()
  for i in 0 ..< rounds:
    var wire = "F 1280 720 0 " & $payload.len & "\n" & payload
    var dead = false
    let decoded = takeMsgAt(Fd(-1), wire, dead)
    doAssert decoded.get().data.len == payload.len
  let rawMs = (cpuTime() - started) * 1000 / rounds
  echo "1280x720 wire CPU/frame: JSON/base64=", legacyMs,
    " ms, raw=", rawMs, " ms"
