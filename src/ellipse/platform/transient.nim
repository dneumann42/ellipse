## Windows that belong to another process's window -- what a dialog
## running as its own process needs to sit over the app that opened it.
##
## The opener names its window with `parentToken()` and hands the token
## to the dialog process, which calls `attachToParent` once its window
## exists. The C glue (`transient.c`) speaks each platform's protocol:
##
##   Wayland   xdg-foreign v2 (the parent's export handle, which SDL
##             publishes) + xdg-dialog v1 for modality: the compositor
##             places the dialog over its parent and may dim the parent
##   X11       WM_TRANSIENT_FOR, with libX11 loaded at runtime through SDL
##   Windows   the owner window (GWLP_HWNDPARENT); the opener disables
##             its own window meanwhile (`setWindowEnabled`), Windows'
##             native modality
##
## X11 and Windows let a window place itself, so the opener also passes
## its bounds (`windowBounds`) and the dialog centres over them
## (`centerOver`). Wayland keeps placement to the compositor.

import ./platform

import std/strutils

when defined(linux):
  {.compile: "wayland/dialog_parent.c".}
  {.compile: "wayland/xdg-foreign-unstable-v2-protocol.c".}
  {.compile: "wayland/xdg-dialog-v1-protocol.c".}
  # (xdg-shell-protocol.c, which xdg-dialog references, comes with
  # `layershell`; wayland-client is linked there too)
  proc ellipse_wayland_attach(win: pointer; handle: cstring; modal: int32): int32 {.
    importc: "ellipse_wayland_attach".}
when defined(windows):
  {.compile: "transient_win.c".}
else:
  {.compile: "transient.c".}
# (Windows: user32, for the owner/enable calls, is in mingw's default libs.
# A passL here would also reach nimony's host-side plugin links.)

proc ellipse_parent_token(win: pointer; buf: cstring; cap: int32): int32 {.
  importc: "ellipse_parent_token".}
proc ellipse_attach_parent(win: pointer; token: cstring; modal: int32): int32 {.
  importc: "ellipse_attach_parent".}
proc ellipse_window_enable(win: pointer; enabled: int32) {.
  importc: "ellipse_window_enable".}

proc parentToken*(): string =
  ## This process's window as a token another process can parent to:
  ## `wayland:<handle>`, `x11:<xid>`, `win32:<hwnd>`, or "" when there is
  ## none (yet) -- an offscreen driver, or a Wayland export handle that has
  ## not arrived.
  let win = sdlWindow()
  if win == nil:
    return ""
  var buf = newString(256)
  let n = ellipse_parent_token(win, buf.toCString, int32(buf.len))
  buf.setLen(max(0, int(n)))
  buf

proc attachToParent*(token: string; modal = true): bool =
  ## Make this process's window a child (`modal`: a modal dialog) of the
  ## window `token` names. False when no link could be made: no token, a
  ## token from another windowing system, or a protocol the compositor
  ## lacks -- the window then simply stands alone.
  let win = sdlWindow()
  if win == nil or token.len == 0:
    return false
  let m = if modal: 1'i32 else: 0'i32
  when defined(linux):
    if token.startsWith("wayland:"):
      if videoDriver() != "wayland":
        return false
      var handle = token.substr(8)
      return ellipse_wayland_attach(win, handle.toCString, m) != 0
  var t = token
  ellipse_attach_parent(win, t.toCString, m) != 0

proc setWindowEnabled*(enabled: bool) =
  ## Windows only: take input away from this window while one of its
  ## dialog processes is up (and give it back after). No-op elsewhere.
  let win = sdlWindow()
  if win != nil:
    ellipse_window_enable(win, if enabled: 1'i32 else: 0'i32)

proc centerOver*(x, y, width, height: int32) =
  ## Place this window centred over the rect (screen coordinates) -- the
  ## parent's `windowBounds()`. Ignored on Wayland, and for an empty rect.
  if width <= 0 or height <= 0:
    return
  let me = windowBounds()
  setWindowPosition(x + (width - me.width) div 2,
                    y + (height - me.height) div 2)
