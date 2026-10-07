## Wake the frame loop when a file descriptor turns readable: sockets,
## pipes, inotify. The loop keeps sleeping in SDL's event queue, so a
## watched descriptor costs nothing until it has data.
##
##   watchFd(fd, proc () {.closure.} =
##     let line = readWhatIsThere(fd)
##     ...)
##
## A helper thread (`fdwatch.c`) polls the descriptors and pushes one SDL
## user event when any is readable. `pumpEvents` hands that event here, on
## the main thread, between frames: callbacks run where touching UI state is
## safe. A callback that changes what the UI shows asks for a frame itself
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
  proc fdWakeEventType*(): uint32 = 0'u32
  proc runReadyFds*() = discard
else:
  {.compile: "fdwatch.c".}

  proc ellipse_fdwatch_add(fd: int32): int32 {.importc: "ellipse_fdwatch_add".}
  proc ellipse_fdwatch_remove(fd: int32) {.importc: "ellipse_fdwatch_remove".}
  proc ellipse_fdwatch_take(buf: ptr int32; cap: int32): int32 {.
    importc: "ellipse_fdwatch_take".}
  proc ellipse_fdwatch_rearm(fd: int32) {.importc: "ellipse_fdwatch_rearm".}
  proc ellipse_fdwatch_event_type(): uint32 {.importc: "ellipse_fdwatch_event_type".}

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

  proc fdWakeEventType*(): uint32 =
    ## The SDL event type the helper thread pushes; 0 before the first watch.
    ellipse_fdwatch_event_type()

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
