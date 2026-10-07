## Runs the owl gallery (apps/owl-gallery) through script.nim; screenshots
## go to the directory in $GALLERY_SHOTS.

import std/[syncio, envvars, paths, dirs, os]
import owl/[objects, evaluator, library]
from owl/modules import Library, evaluate, require, addPath
import owl/libraries/gui
import ellipse_ui/app

include ./script

proc windowSequence*() {.raises.} =
  ## Dialogs in their own window: the child process starts and its dialog
  ## comes up; closing it (SIGTERM) answers the opener as cancelled.
  settle(6)
  clickId("sw-ownwin")
  clickId("pop-alert")
  for i in 0 ..< 40:
    settle(1)
    discard execShellCmd("sleep 0.05")
  shot("20-window-dialog-open")

try:
  shotDir = getEnv("GALLERY_SHOTS")
  setCurrentDir(path(getEnv("GALLERY_PROJECT")))
  let lib = owlLibrary()
  evaluate(lib)
  addPath(lib, "src")
  if getEnv("GALLERY_SEQ") == "window":
    guiScript = windowSequence
  else:
    guiScript = sequence
  discard require(lib, "main")
except:
  echo "owl gallery failed: ", lastErrorMessage
  quit 1
