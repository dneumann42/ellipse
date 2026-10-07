## The controlling terminal: raw mode in and out, its size, reads and
## writes. `ttyOpen` switches to the alternate screen with the cursor
## hidden and turns on everything the UI reads -- SGR mouse with motion
## (hover), bracketed paste, focus reports and the kitty keyboard
## protocol's disambiguation -- and arranges for all of it to be undone on
## any exit, crashes included (`ellipse_tty.c`).
##
## POSIX only; on Windows `ttyIsTty` is false and the terminal backend runs
## headless.

when defined(windows):
  proc ttyIsTty*(): bool = false
  proc ttyOpen*(): int32 = -1
  proc ttyClose*() = discard
  proc ttySize*(): tuple[cols, rows: int] = (80, 24)
  proc ttyWrite*(s: string) = discard
  proc ttyRead*(fd: int32): tuple[data: string, eof: bool] = ("", true)
else:
  {.compile: "ellipse_tty.c".}

  proc ellipse_tty_is_tty(): int32 {.importc: "ellipse_tty_is_tty".}
  proc ellipse_tty_open(): int32 {.importc: "ellipse_tty_open".}
  proc ellipse_tty_close() {.importc: "ellipse_tty_close".}
  proc ellipse_tty_set_leave(s: cstring; len: int32) {.
    importc: "ellipse_tty_set_leave".}
  proc ellipse_tty_size(cols, rows: ptr int32) {.importc: "ellipse_tty_size".}
  proc ellipse_tty_write(s: cstring; len: int32) {.importc: "ellipse_tty_write".}
  proc ellipse_tty_read(fd: int32; buf: cstring; cap: int32): int32 {.
    importc: "ellipse_tty_read".}

  const
    enterSeq = "\e[?1049h" & # alternate screen
      "\e[?25l" &            # hide the cursor
      "\e[?1000h\e[?1002h\e[?1003h\e[?1006h" & # mouse: press, drag, motion, SGR
      "\e[?2004h" &          # bracketed paste
      "\e[?1004h" &          # focus in/out
      "\e[>1u" &             # kitty keyboard: disambiguate
      "\e[2J"
    leaveSeq = "\e[<u\e[?1004l\e[?2004l" &
      "\e[?1006l\e[?1003l\e[?1002l\e[?1000l" &
      "\e[0m\e[?25h\e[?1049l"

  proc ttyIsTty*(): bool =
    ## Both stdin and stdout are a terminal.
    ellipse_tty_is_tty() != 0

  proc ttyWrite*(s: string) =
    if s.len > 0:
      var t = s
      ellipse_tty_write(t.toCString, int32(t.len))

  proc ttyOpen*(): int32 =
    ## Take over the terminal (see the module doc). Returns the read end of
    ## the signal pipe -- a byte 'w' per resize, 'q' per termination
    ## request -- or -1 when the terminal could not be set up.
    result = ellipse_tty_open()
    if result < 0:
      return
    var leave = leaveSeq
    ellipse_tty_set_leave(leave.toCString, int32(leave.len))
    ttyWrite(enterSeq)

  proc ttyClose*() =
    ## Give the terminal back as it was.
    ellipse_tty_close()

  proc ttySize*(): tuple[cols, rows: int] =
    var c = 0'i32
    var r = 0'i32
    ellipse_tty_size(addr c, addr r)
    (int(c), int(r))

  proc ttyRead*(fd: int32): tuple[data: string, eof: bool] =
    ## Everything `fd` has ready, without blocking.
    result = ("", false)
    var buf = newString(4096)
    while true:
      let n = ellipse_tty_read(fd, buf.toCString, int32(buf.len))
      if n < 0:
        result.eof = true
        return
      if n == 0:
        return
      result.data.add buf.substr(0, int(n) - 1)
