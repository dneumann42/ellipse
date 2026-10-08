## Wake the frame loop when a file descriptor turns readable: sockets,
## pipes, inotify. The loop keeps sleeping where it sleeps -- in SDL's
## event queue (a window) or in poll() (the terminal) -- so a watched
## descriptor costs nothing until it has data.
##
##   watchFd(fd, proc () {.closure.} =
##     let line = readWhatIsThere(fd)
##     ...)
##
## In a window a helper thread (`fdwatch.c`) polls the descriptors and
## wakes SDL's queue with one user event when any is readable (`useThread`,
## `sdl_wake.c`); `pumpEvents` hands that event here. In the terminal the
## loop polls the descriptors itself (`useDirectWait`, `waitFds`), with no
## thread and no SDL. Either way callbacks run on the main thread, between
## frames, where touching UI state is safe. A callback that changes what the UI shows asks for a frame itself
## (`requestFrame`). The descriptor is re-armed after its callback, so a
## callback that leaves data unread is called again.
##
## POSIX only; on Windows `watchFd` reports false and nothing is watched.

type
  FdCallback* = proc () {.closure.}

  Watcher = object
    fd: int32
    cb: FdCallback

var watchers: seq[Watcher] = @[]

when defined(windows):
  proc watchFd*(fd: int32; cb: FdCallback): bool = false
  proc unwatchFd*(fd: int32) = discard
  proc useDirectWait*() = discard
  proc waitFds*(ns: int64) = discard
  proc runReadyFds*() = discard
else:
  {.compile: "fdwatch.c".}

  proc ellipse_fdwatch_add(fd: int32): int32 {.importc: "ellipse_fdwatch_add".}
  proc ellipse_fdwatch_remove(fd: int32) {.importc: "ellipse_fdwatch_remove".}
  proc ellipse_fdwatch_take(buf: ptr int32; cap: int32): int32 {.
    importc: "ellipse_fdwatch_take".}
  proc ellipse_fdwatch_rearm(fd: int32) {.importc: "ellipse_fdwatch_rearm".}
  proc ellipse_fdwatch_wait(ns: int64): int32 {.importc: "ellipse_fdwatch_wait".}

  var direct = false

  proc watchFd*(fd: int32; cb: FdCallback): bool =
    ## Call `cb` on the main thread whenever `fd` is readable (or closed by
    ## the other end). False when it could not be watched.
    for w in watchers:
      if w.fd == fd:
        return false
    if ellipse_fdwatch_add(fd) == 0:
      return false
    watchers.add Watcher(fd: fd, cb: cb)
    true

  proc unwatchFd*(fd: int32) =
    ## Stop watching `fd`; call it before closing the descriptor.
    var kept: seq[Watcher] = @[]
    for w in watchers:
      if w.fd != fd:
        kept.add w
    watchers = kept
    ellipse_fdwatch_remove(fd)

  proc useDirectWait*() =
    ## The loop sleeps in `waitFds` itself (the terminal backend): no helper
    ## thread is started.
    direct = true

  proc waitFds*(ns: int64) =
    ## Direct mode: sleep until a watched descriptor is readable or `ns`
    ## nanoseconds pass (negative: no limit, 0: just look). `runReadyFds`
    ## then runs the callbacks.
    if direct:
      discard ellipse_fdwatch_wait(ns)

  proc runReadyFds*() =
    ## Run the callbacks of the descriptors that turned readable, then
    ## re-arm the ones still watched. The platform loop calls this.
    var buf = default(array[64, int32])
    let n = ellipse_fdwatch_take(addr buf[0], 64'i32)
    var i = 0
    while i < int(n):
      let fd = buf[i]
      var cb: nil FdCallback = nil
      for w in watchers:
        if w.fd == fd:
          cb = w.cb
      if cb != nil:
        cb()
        var still = false
        for w in watchers:
          if w.fd == fd:
            still = true
        if still:
          ellipse_fdwatch_rearm(fd)
      inc i
