## Desktop appearance controls. SDL reads the preference and delivers
## changes through the normal platform event loop.

import ellipse/platform/platform
export platform.systemDarkMode

when defined(linux):
  import std/[osproc, strutils]

proc setDesktopDarkMode*(dark: bool) =
  ## Write the shared GNOME color scheme. The desktop session handles any
  ## legacy toolkit settings derived from it.
  when defined(linux):
    let value = if dark: "prefer-dark" else: "prefer-light"
    let (output, code) = execCmdEx(
      "gsettings set org.gnome.desktop.interface color-scheme " & value)
    if code != 0:
      raise newException(IOError, "Could not set the desktop color scheme: " & output.strip())
  else:
    raise newException(IOError, "Setting desktop appearance is unavailable on this platform")
