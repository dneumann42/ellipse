import std/[syncio]

import ellipse/logger
import ellipse/platform/platform

addHandler initStandardLogger()

when isMainModule:
  try:
    initialize()
  except ErrorCode:
    discard
