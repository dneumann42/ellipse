## The frame loop wakes for a readable descriptor and runs its callback on
## the main thread, between frames, without running a frame for it.

import std/[syncio, envvars]
import ellipse_ui/app
import ./testutils

proc c_pipe(fds: ptr int32): int32 {.importc: "pipe", header: "<unistd.h>".}
proc c_write(fd: int32; buf: cstring; n: int): int {.importc: "write", header: "<unistd.h>".}
proc c_read(fd: int32; buf: cstring; n: int): int {.importc: "read", header: "<unistd.h>".}

var fds: array[2, int32]
var got = ""
var framesAtRead = -1'i64
var framesAfter = -1'i64

proc view()  =
  text("fdwatch")

proc script()  =
  discard c_pipe(addr fds[0])
  let ok = watchFd(fds[0], proc () {.closure.} =
    var buf = newString(16)
    let n = c_read(fds[0], buf.cstring, 16)
    if n > 0:
      got.add buf.substr(0, n - 1)
    framesAtRead = frameIndex()
    platform.quit())
  expect ok, "watchFd accepts a pipe"
  var msg = "ping"
  discard c_write(fds[1], msg.cstring, 4)
  start(frame, proc () {.closure.} = drawCommands())
  framesAfter = frameIndex()

try:
  putEnv("SDL_VIDEODRIVER", "offscreen")
  run(App(window: WindowConfig(title: "fdwatch", width: 200, height: 100),
          view: view, debugMode: false, log: false), script)
except:
  expect false, "app ran" 
expect got == "ping", "callback read the pipe: " & got
expect framesAfter == framesAtRead, "no frame ran for the wakeup itself"
finish("fdwatch")
