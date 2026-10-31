## Attached snapshots read the software surface after flushing SDL.
import std/envvars
import ellipse_ui
import ellipse/platform/platform
import ellipse/platform/renderer
import ./testutils

type Surface {.importc: "SDL_Surface", header: "<SDL3/SDL.h>", bycopy.} = object
  w, h, pitch: cint
  pixels: pointer

proc pixel(x, y: int): uint32 =
  let s = cast[ptr Surface](offscreenSurface())
  cast[ptr uint32](cast[uint](s.pixels) + uint(y * s.pitch + x * 4))[]

proc paint(color: Color) =
  updateUI()
  layout:
    clay "root", col(width = grow(), height = grow()).bg(color):
      text("resize cached text")
  drawCommands()
  flushOffscreen()

putEnv("SDL_VIDEODRIVER", "offscreen")
bootupOffscreen(80, 40)
paint(rgb(255, 0, 0))
expect(pixel(79, 39) == 0xFFFF0000'u32, "first snapshot contains flushed red pixels")
paint(rgb(0, 0, 255))
expect(pixel(79, 39) == 0xFF0000FF'u32, "changed snapshot contains new blue pixels")
for (w, h) in [(160'i32, 90'i32), (55'i32, 30'i32), (120'i32, 60'i32)]:
  renderer.resizeOffscreen(w, h)
  expect(offscreenPixelSize() == (w, h), "surface matches resized bounds")
  paint(rgb(0, 255, 0))
  expect(pixel(int(w - 1), int(h - 1)) == 0xFF00FF00'u32,
    "resized image paints to its new bottom-right pixel")
finish("offscreen resize")
