## Bounded 20 fps capture transport and background GIF encoder.
## The GPU backend feeds already scaled RGBA pixels; no SDL calls run here.
{.push gcsafe.}
import std/[os, osproc, times, monotimes, atomics, tempfiles]

const GifFps* = 20
const GifFrames* = GifFps * 20

type
  MessageKind = enum pixels, finish, shutdown
  Message = object
    kind: MessageKind
    data: seq[uint8]
    tick, width, height: int
  Recorder = object
    inbox: Channel[Message]
    busy: Atomic[bool]
    worker: Thread[ptr Recorder]
  FrameRing* = object
    frames*: array[GifFrames, string]
    first*, count*: int

proc append*(ring: var FrameRing; frame: string) =
  let slot = (ring.first + ring.count) mod GifFrames
  ring.frames[slot] = frame
  if ring.count < GifFrames: inc ring.count
  else: ring.first = (ring.first + 1) mod GifFrames

proc encode(ring: FrameRing; width, height: int) =
  if ring.count == 0: return
  let directory = createTempDir("ellipse-gif-", "")
  defer: removeDir(directory)
  let raw = directory / "frames.rgba"
  var file = open(raw, fmWrite)
  try:
    for i in 0 ..< ring.count:
      file.write(ring.frames[(ring.first + i) mod GifFrames])
  finally: file.close()
  createDir("recordings")
  let output = absolutePath("recordings" / ("clip-" & now().format("yyyyMMdd-HHmmss-fff") & ".gif"))
  let log = directory / "ffmpeg.log"
  let palette = directory / "palette.png"
  let input = @["-hide_banner", "-loglevel", "error", "-y", "-threads", "1",
    "-filter_threads", "1", "-f", "rawvideo", "-pixel_format", "rgba", "-video_size", $width & "x" & $height,
    "-framerate", $GifFps, "-i", raw]
  proc run(args: seq[string]) =
    # File-backed stderr avoids a full pipe deadlocking the worker.
    let command = quoteShellCommand(@[findExe("ffmpeg")] & args) & " >" & quoteShell(log) & " 2>&1"
    if execCmd(command) != 0:
      raise newException(IOError, readFile(log))
  # Two passes avoid palettegen buffering the entire clip inside FFmpeg.
  run(input & @["-vf", "palettegen=stats_mode=diff:reserve_transparent=0", "-frames:v", "1", palette])
  var size = 1.0
  for attempt in 0 ..< 7:
    let w = max(1, int(width.float * size))
    let h = max(1, int(height.float * size))
    run(input & @["-i", palette, "-filter_complex_threads", "1", "-lavfi",
      "[0:v]scale=" & $w & ":" & $h & ":flags=lanczos[v];[v][1:v]" &
      "paletteuse=dither=bayer:bayer_scale=3:diff_mode=rectangle", "-loop", "0", output])
    if getFileSize(output) <= 14 * 1024 * 1024: break
    size *= 0.8
  echo "GIF saved: ", output, " (", getFileSize(output), " bytes)"

proc work(rec: ptr Recorder) {.thread.} =
  var ring: FrameRing
  var last = ""
  var nextTick, width, height: int
  while true:
    let msg = rec.inbox.recv()
    case msg.kind
    of pixels:
      width = msg.width
      height = msg.height
      # Preserve wall time when the render loop or bounded queue drops frames.
      if last.len > 0:
        for tick in max(nextTick, msg.tick - GifFrames) ..< msg.tick:
          ring.append(last)
      last = newString(msg.data.len)
      if last.len > 0: copyMem(addr last[0], unsafeAddr msg.data[0], last.len)
      ring.append(last)
      nextTick = msg.tick + 1
    of finish, shutdown:
      if last.len > 0:
        for tick in max(nextTick, msg.tick - GifFrames) ..< msg.tick:
          ring.append(last)
      try: encode(ring, width, height)
      except CatchableError as e: echo "GIF recording failed: ", e.msg
      ring = default(FrameRing)
      last = ""
      nextTick = 0
      rec.busy.store(false)
      if msg.kind == shutdown: break

var recorder: ptr Recorder
var active*: bool
var started: MonoTime
var nextCapture: int
var stopTick = -1

proc elapsedTick(): int =
  max(0, int((getMonoTime() - started).inMilliseconds div 50))

proc toggleRecording*() =
  if active:
    active = false
    stopTick = max(1, elapsedTick() + 1)
    echo "GIF recording stopped; encoding in background"
  elif stopTick >= 0 or (recorder != nil and recorder.busy.load()):
    echo "GIF encoder is busy; wait for the saved path before recording again"
  else:
    if findExe("ffmpeg").len == 0:
      echo "GIF recording needs ffmpeg on PATH"
      return
    if recorder == nil:
      recorder = cast[ptr Recorder](allocShared0(sizeof(Recorder)))
      recorder.inbox.open(3)
      createThread(recorder.worker, work, recorder)
    recorder.busy.store(true)
    started = getMonoTime()
    nextCapture = 0
    active = true
    echo "GIF recording started (F5 to save, latest 20 seconds retained)"

proc recordingTick*(): int = elapsedTick()

proc captureDue*(): bool =
  if not active: return false
  let tick = elapsedTick()
  if tick < nextCapture: return false
  nextCapture = tick + 1 # never capture bursts to catch up
  true

proc offerPixels*(data: sink seq[uint8]; width, height, tick: int) =
  if recorder != nil:
    discard recorder.inbox.trySend(Message(kind: pixels, data: data,
      width: width, height: height, tick: tick))

proc pumpRecorder*() =
  # Called only after the previous GPU download has been offered, keeping
  # stop ordered after its final frame. Never block the render thread.
  if stopTick >= 0 and recorder.inbox.trySend(Message(kind: finish, tick: stopTick)):
    stopTick = -1

proc closeRecorder*() =
  if recorder == nil: return
  let tick = if active: elapsedTick() + 1 else: max(0, stopTick)
  recorder.inbox.send(Message(kind: shutdown, tick: tick))
  joinThread(recorder.worker)
  recorder.inbox.close()
  deallocShared(recorder)
  recorder = nil
  active = false
  stopTick = -1
