import std/[syncio]

import ellipse/logger
import ellipse/platform/platform

addHandler initStandardLogger()

proc update() {.raises.} =
  discard

proc render() {.raises.} =
  discard

when isMainModule:
  try:
    initialize()
    start(update, render)
  except ErrorCode:
    discard
