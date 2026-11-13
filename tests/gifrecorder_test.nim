## nim c -r --threads:on --mm:atomicArc tests/gifrecorder_test.nim
## Integration portion requires ffmpeg and ffprobe on PATH.
import std/[os, osproc, strutils, tempfiles]
import ellipse/platform/gifrecorder

var ring: FrameRing
for i in 0 ..< 405: ring.append($i)
doAssert ring.count == 400
doAssert ring.frames[ring.first] == "5"
doAssert ring.frames[(ring.first + 399) mod GifFrames] == "404"

doAssert findExe("ffmpeg").len > 0 and findExe("ffprobe").len > 0
let originalDir = getCurrentDir()
let directory = createTempDir("ellipse-gif-test-", "")
setCurrentDir(directory)
toggleRecording()
# Synthetic timestamps exercise long-clip wrap without waiting 20 seconds.
# Missing ticks exercise repeated frames under queue/render pressure.
for tick in 0 ..< 405:
  if tick mod 7 == 3: continue
  var rgba = newSeq[uint8](64 * 36 * 4)
  for i in 0 ..< 64 * 36:
    rgba[i * 4] = uint8((i + tick * 23) mod 256)
    rgba[i * 4 + 1] = uint8((i div 64 * 7) mod 256)
    rgba[i * 4 + 2] = uint8(tick mod 256)
    rgba[i * 4 + 3] = 255
  offerPixels(rgba, 64, 36, tick)
  sleep(3)
closeRecorder()
var found = false
for path in walkFiles("recordings/*.gif"):
  doAssert readFile(path).startsWith("GIF89a")
  let probe = execProcess(findExe("ffprobe"), args = @["-v", "error",
    "-select_streams", "v:0", "-show_entries", "stream=width,height,nb_frames,duration,r_frame_rate",
    "-of", "default=nw=1", path], options = {poUsePath, poStdErrToStdOut})
  doAssert "nb_frames=400" in probe, probe
  doAssert "duration=20.000000" in probe, probe
  doAssert "r_frame_rate=20/1" in probe, probe
  doAssert "width=64" in probe and "height=36" in probe, probe
  found = true
doAssert found
setCurrentDir(originalDir)
removeDir(directory)
echo "GIF ring wrap, dropped-frame timing, and 20 fps encoding passed"
