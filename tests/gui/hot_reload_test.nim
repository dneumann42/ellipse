## Whole-app hot reload, end to end and headless: a real inotify event for
## a saved source settles into a rebuild (a trivial shell command here), the
## loop ends itself on success, and `run` re-execs over the process. The new
## image carries a different marker string: that is the proof of the reload,
## asserted by this test's own bash wrapper (`hot_reload_test.sh`).

import std/[syncio, os, envvars, strutils, osproc]
import ellipse_ui/app
import ./testutils

const marker = getEnv("ELLIPSE_HOT_MARKER", "boot")
  ## baked into this binary at compile time; the wrapper greps it out of the
  ## running process's /proc/pid/exe to see which image answers

var failures = 0
var passed = 0

proc expect(cond: bool, msg: string) =
  if cond:
    passed += 1
  else:
    failures += 1
    echo "FAILED: ", msg

var root = ""
var watched = ""

proc view()  =
  text("hot reload")

proc script()  =
  root = getCurrentDir()
  watched = root / "src/watchme.nim"
  # editor-save simulation. Save only while nothing is pending and no build
  # has begun; once the watcher takes a save (or a build starts), go quiet and
  # pump frames. The settle deadline then fires with the flag set and success
  # ends the loop for the re-exec. Re-save if we stay idle past the deadline,
  # which means an earlier save raced the arming.
  var n = 0
  while not askedToQuit() and n < 6000:
    pumpEvents()                       # SDL queue -> fdwatch callbacks fire
    if fdsReady():
      runReadyFds()                    # inotify CLOSE_WRITE, between frames
    frame()                            # the settle check lives here
    if lastSeen() == 0 and not restartPending() and (buildStarted() or n >= 2):
      discard execCmd("touch " & quoteShell(watched))   # save, then go quiet
      var m = 0
      while m < 600 and lastSeen() == 0 and not restartPending() and
          not quitAsked():
        pumpEvents()
        if fdsReady():
          runReadyFds()                # take this very save's event
        frame()
        inc m
        sleep 1
      inc n, m
    inc n
    sleep 1
  expect quitAsked(), "the loop ended itself after a successful rebuild"

try:
  putEnv("SDL_VIDEODRIVER", "offscreen")
  run(App(window: WindowConfig(title: "hot_reload_test", width: 200, height: 100),
          view: view, debugMode: false, log: false,
          hotApp: true, buildCommand: "true"), script)
except:
  expect false, "app ran"

expect restartSeen(), "a rebuild landed and the restart was claimed"
expect marker == "BOOT" or marker == "LIVE", "this image was built with a marker (wrapper sets it)"
finish("hot_reload")
echo "marker: ", marker
quit(if failures > 0 or not restartSeen(): 1 else: 0)
