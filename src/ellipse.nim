import ellipse/clock
import ellipse_ui/app

export clock, app

when isMainModule:
  import std/[cmdline, syncio]
  import ellipse/cli
  let code = runCli(commandLineParams())
  if code != 0:
    quit code
