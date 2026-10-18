## File watching: which files changed, and the descriptor to sleep on.
##
## One watcher holds many directories, because both backends can only report
## *that* a directory changed rather than what did: inotify watches directories,
## and `FindFirstChangeNotification` signals for a whole one. So a file is
## watched through the directory that holds it, and an event names the file.
##
## `poll` drains what happened without blocking, and `descriptor` hands out the
## descriptor an event loop can wait on -- `ellipse/platform/fdwatch`'s `watchFd`
## takes it, and its callback calls `poll` -- so a watched file costs nothing
## until it changes. Windows has no such descriptor: poll there is the whole
## interface, and it is cheap to call.
##
## Events are hints, not truth: a rename, an editor's save and a dropped event
## all look different in the queue, directories get replaced under a watch, and
## Windows says nothing at all about which file moved. Callers that must be
## right compare what they hold against the file itself -- which is what
## `owl/settings` does, and why hot-loading survives a full queue.

import std/strutils

const
  eventBytes = 8192
    ## inotify events are read in one gulp; a busier directory just takes two
    ## calls, since `poll` reads until the descriptor goes empty.

type
  WatchKind* = enum
    Created   ## the name appeared
    Modified  ## its contents, or its place in the tree, changed
    Removed   ## the name went away

  WatchEvent* = object
    path*: string   ## the file, spelled the way the directory was given
    kind*: WatchKind

  EventBuffer = object
    ## A buffer whose first member forces the alignment inotify requires.
    align: int64
    bytes: array[eventBytes, char]

  FileWatch* = ref object
    dirs: seq[string]   ## watched directories, parallel to the keys below
    when defined(windows):
      handles: seq[pointer]  ## one change notification per directory
    else:
      fd: int32         ## the inotify descriptor, -1 once closed
      keys: seq[int32]  ## inotify watch descriptors

when defined(windows):
  const
    changeFileName = 0x00000001'u32
    changeDirName = 0x00000002'u32
    changeAttributes = 0x00000004'u32
    changeSize = 0x00000008'u32
    changeLastWrite = 0x00000010'u32
    changeCreation = 0x00000040'u32
    changeFilter = changeFileName or changeDirName or changeAttributes or
      changeSize or changeLastWrite or changeCreation
    waitObject0 = 0x00000000'u32

  type Utf16 = distinct uint16
  type Utf16Text = ptr UncheckedArray[Utf16]

  proc toUtf16(text: string): Utf16Text =
    ## UTF-8 to UTF-16 with a trailing NUL. The buffer is left allocated: a
    ## change notification outlives the call that asked for it, and the path it
    ## was built from lives as long as the watch.
    var out16 = cast[Utf16Text](alloc((text.len + 1) * 2))
    var at = 0
    var i = 0
    while i < text.len:
      var cp = uint32(byte(text[i]))
      var width = 1
      if cp >= 0xF0:
        cp = cp and 0x07
        width = 4
      elif cp >= 0xE0:
        cp = cp and 0x0F
        width = 3
      elif cp >= 0xC0:
        cp = cp and 0x1F
        width = 2
      if width > 1:
        for k in 1 ..< width:
          cp = cp shl 6 or (uint32(byte(text[i + k])) and 0x3F)
        i += width
      else:
        inc i
      if cp >= 0x10000:
        let v = cp - 0x10000
        out16[at] = Utf16(0xD800'u16 + uint16(v shr 10))
        out16[at + 1] = Utf16(0xDC00'u16 + (uint16(v) and 0x03FF))
        inc at, 2
      else:
        out16[at] = Utf16(uint16(cp))
        inc at
    out16[at] = Utf16(0)
    result = out16

  proc findFirstChangeNotification(path: Utf16Text; watchSubtree,
    filter: uint32): pointer {.
    stdcall, importc: "FindFirstChangeNotificationW", dynlib: "kernel32".}
  proc findNextChangeNotification(handle: pointer): int32 {.
    stdcall, importc: "FindNextChangeNotification", dynlib: "kernel32".}
  proc findCloseChangeNotification(handle: pointer): int32 {.
    stdcall, importc: "FindCloseChangeNotification", dynlib: "kernel32".}
  proc waitForSingleObject(handle: pointer; ms: uint32): uint32 {.
    stdcall, importc: "WaitForSingleObject", dynlib: "kernel32".}
else:
  const
    inAccess = 0x00000001'u32
    inModify = 0x00000002'u32
    inAttrib = 0x00000004'u32
    inCloseWrite = 0x00000008'u32
    inCloseNowrite = 0x00000010'u32
    inMoveSelf = 0x00000020'u32
    inMoveFrom = 0x00000040'u32
    inMoveTo = 0x00000080'u32
    inCreate = 0x00000100'u32
    inDelete = 0x00000200'u32
    inIgnored = 0x00008000'u32
    deleteSelf = 0x00000400'u32
    watchMask = inCloseWrite or inCloseNowrite or inModify or inAttrib or
      inCreate or inDelete or inMoveTo or inMoveFrom

    inNonblock = 0x00000800'i32
    inCloexec = 0x00080000'i32

  type
    InotifyEvent = object
      ## The fixed part of the C `struct inotify_event`: the name's bytes, and
      ## then padding, follow it. Declared plain so `sizeof` is Nim's own.
      wd: int32
      mask: uint32
      cookie: uint32
      len: uint32

  proc inotifyInit1(flags: cint): int32 {.importc: "inotify_init1",
    header: "<sys/inotify.h>".}
  proc inotifyAddWatch(fd: int32; path: cstring; mask: uint32): int32 {.
    importc: "inotify_add_watch", header: "<sys/inotify.h>".}
  proc inotifyRmWatch(fd, wd: cint): cint {.importc: "inotify_rm_watch",
    header: "<sys/inotify.h>".}
  proc cRead(fd: int32; buf: pointer; count: int): int {.
    importc: "read", header: "<unistd.h>".}
  proc cClose(fd: cint): cint {.importc: "close", header: "<unistd.h>".}

func dirOf*(path: string): string =
  ## The directory holding `path`: `.` for a bare name, `/` for a top-level
  ## one. A watcher can only watch this, not the file.
  let at = max(path.rfind('/'), path.rfind('\\'))
  if at < 0:
    result = "."
  elif at == 0:
    result = "/"
  else:
    result = path[0 ..< at]

func nameOf*(path: string): string =
  ## The last part of `path`.
  let at = max(path.rfind('/'), path.rfind('\\'))
  result = path.substr(at + 1)

func joins*(dir, name: string): string =
  ## How an event from `dir` spells the file `name`.
  if dir == ".":
    result = name
  elif dir.endsWith("/"):
    result = dir & name
  else:
    result = dir & "/" & name

proc newFileWatch*(): FileWatch =
  ## A watcher with nothing watched yet. `ok` says whether it can watch.
  when defined(windows):
    result = FileWatch(dirs: @[], handles: @[])
  else:
    result = FileWatch(fd: inotifyInit1(cint(inNonblock or inCloexec)),
      dirs: @[], keys: @[])

func ok*(w: FileWatch): bool =
  ## Whether the platform gave this watcher something to watch with.
  when defined(windows):
    result = w != nil
  else:
    result = w != nil and w.fd >= 0

func descriptor*(w: FileWatch): int32 =
  ## The descriptor to wait on, or -1 when there is none to wait on (Windows,
  ## or a watcher that could not open): `poll` is then the only interface.
  when defined(windows):
    result = -1
  else:
    result = if w == nil: -1'i32 else: w.fd

func watched*(w: FileWatch): int =
  ## How many directories are being watched.
  if w == nil: 0 else: w.dirs.len

proc watchDir*(w: FileWatch; dir: string): bool =
  ## Watch `dir`, reporting the files that change in it. Watching a directory
  ## twice is free. False when the backend refuses it (gone, or no permission).
  if w == nil or not ok(w) or dir.len == 0:
    return false
  for held in w.dirs:
    if held == dir:
      return true
  when defined(windows):
    let handle = findFirstChangeNotification(toUtf16(dir), 0'u32, changeFilter)
    if handle == nil or handle == cast[pointer](-1):
      result = false
    else:
      w.dirs.add dir
      w.handles.add handle
      result = true
  else:
    var path = dir
    let key = inotifyAddWatch(w.fd, path.cstring, watchMask)
    if key < 0:
      result = false
    else:
      w.dirs.add dir
      w.keys.add key
      result = true

proc watchFile*(w: FileWatch; path: string): bool =
  ## Watch a file, by watching the directory it lives in.
  watchDir(w, dirOf(path))

proc dirFor(w: FileWatch; key: int32): string =
  result = ""
  when defined(windows):
    discard key
  else:
    for i, held in w.keys:
      if held == key:
        return w.dirs[i]

proc poll*(w: FileWatch): seq[WatchEvent] =
  ## Everything that happened since the last call, drained without blocking.
  ## Empty when nothing did, and when the watcher is closed or unsupported.
  result = @[]
  if w == nil or not ok(w):
    return
  when defined(windows):
    for i, dir in w.dirs:
      if waitForSingleObject(w.handles[i], 0'u32) == waitObject0:
        # the notification holds only "this directory moved"; re-arm it and
        # pass the directory on for the caller to sort out
        discard findNextChangeNotification(w.handles[i])
        result.add WatchEvent(path: dir, kind: Modified)
  else:
    var buf = default(EventBuffer)
    while true:
      let n = cRead(w.fd, addr buf.bytes[0], eventBytes)
      if n <= 0:
        break
      const hdr = int(sizeof(InotifyEvent))
      var pos = 0
      while pos + hdr <= n:
        let e = cast[ptr InotifyEvent](addr buf.bytes[pos])[]
        let stop = pos + hdr + int(e.len)
        if stop > n:
          break
        if (e.mask and inIgnored) == 0:
          var name = ""
          var k = 0
          while k < int(e.len) and buf.bytes[pos + hdr + k] != '\0':
            name.add buf.bytes[pos + hdr + k]
            inc k
          if name.len > 0:
            let dir = dirFor(w, e.wd)
            if dir.len > 0:
              var kind = Modified
              if (e.mask and inCreate) != 0:
                kind = Created
              elif (e.mask and (inDelete or inMoveFrom)) != 0:
                kind = Removed
              result.add WatchEvent(path: joins(dir, name), kind: kind)
        pos = stop

proc close*(w: FileWatch) =
  ## Stop watching everything and give up the descriptor. Polling a closed
  ## watcher is simply empty.
  if w == nil:
    return
  when defined(windows):
    for handle in w.handles:
      discard findCloseChangeNotification(handle)
    w.handles = @[]
  else:
    for key in w.keys:
      discard inotifyRmWatch(w.fd, key.cint)
    w.keys = @[]
    if w.fd >= 0:
      discard cClose(w.fd.cint)
      w.fd = -1
  w.dirs = @[]
