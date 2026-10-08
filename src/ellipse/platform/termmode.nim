## Which surface the app draws on: a window (SDL) or the terminal it was
## started from. Any ellipse app runs in the terminal when started with
## `--tui` or with `ELLIPSE_TUI=1` in the environment; nothing in the app
## changes. `setTerminalMode` decides it in code (tests, an app's own
## setting) and must run before `bootup`.
##
## In the terminal clay still lays out in virtual pixels, on a grid of
## `cellWidth` x `cellHeight` cells (see clay's `setGrid`): a 120x40
## terminal is a 960x640 layout, close to the windows apps are written for.
##
## A program built with `-d:ellipseNoSdl` has no window backend at all:
## `withSdl` is false, nothing links SDL3 (or SDL3_ttf, or wayland), and
## every app runs in the terminal.

import std/[envvars, cmdline]

const
  withSdl* = not defined(ellipseNoSdl)
    ## The window backend (SDL3) is built in.

const
  cellWidth* = 8'f32    ## virtual pixels per terminal column
  cellHeight* = 16'f32  ## virtual pixels per terminal row

var decided = false
var terminal = false

proc terminalRequested(): bool =
  let env = getEnv("ELLIPSE_TUI")
  if env.len > 0 and env != "0" and env != "false" and env != "no":
    return true
  for i in 1 .. paramCount():
    if paramStr(i) == "--tui":
      return true
  false

proc terminalMode*(): bool =
  ## The app draws in the terminal instead of a window.
  when not withSdl:
    return true
  if not decided:
    terminal = terminalRequested()
    decided = true
  terminal

proc setTerminalMode*(on: bool) =
  ## Pick the backend in code, overriding `--tui` / `ELLIPSE_TUI`. Without
  ## SDL built in the terminal is the only backend, whatever `on` says.
  terminal = on
  decided = true
