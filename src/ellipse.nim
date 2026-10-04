import std/[syncio]

import ellipse/logger
import ellipse/platform/platform
import ellipse_ui/ui

addHandler initStandardLogger()

proc update() {.raises.} =
  beginLayout()
  endLayout()

proc render() {.raises.} =
  discard

when isMainModule:
  try:
    initialize()
    start(update, render)
  except ErrorCode:
    discard
