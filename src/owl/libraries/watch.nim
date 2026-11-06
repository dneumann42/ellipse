## The `watch` module: file watching for owl scripts, on the inotify backend
## of `owl/watch`.
##
## Where `net`'s watch builtins hand out a raw descriptor that scripts must
## drain themselves (and, with no fd wait outside the frame loop, poll), this
## module keeps the `FileWatch` itself and offers three calls:
##
##   watch-dir dir          start watching a directory, recursively; new
##                          directories it finds get watched too
##   watch-wait ms          sleep until something changes -- the inotify
##                          descriptor is waited on, not polled; timeout -1
##                          waits forever, 0 just looks
##   watch-changes          drain what changed since the last call, as records
##                          of (path = "abs/way/file.ext" kind = "created" |
##                          "modified" | "removed")
##
## Events are hints, not truth (see `owl/watch`): callers that must be right
## compare against the files themselves.

import std/os
import std/strutils as su
when not defined(windows):
  import posix

proc cPoll(fds: pointer, nfds: cint, timeoutMs: cint): cint {.
  importc: "poll", header: "<poll.h>".}

type PollFd = object
  fd: cint
  events: cshort
  revents: cshort

proc waitForReadable(fd: int32, ms: int): bool =
  ## Sleep until `fd` is readable or `ms` passes (negative: no limit).
  when defined(windows):
    discard fd
    discard ms
    result = true
  else:
    var p = PollFd(fd: cint(fd), events: cshort(POLLIN), revents: 0'i16)
    var r: cint
    while true:
      r = cPoll(addr p, 1.cint, cint(ms))
      if r >= 0:
        break
      if errno != EINTR:
        return false
    result = (int(p.revents) and int(POLLIN)) != 0

import owl/[objects, evaluator, modules]
import owl/watch

var watcher {.threadvar.}: FileWatch
var pending {.threadvar.}: seq[WatchEvent]
var roots {.threadvar.}: seq[string]
  ## the directories `watch-dir` was given, re-walked on every call so new
  ## subdirectories get watched

proc ensureWatcher(): FileWatch =
  if watcher == nil:
    watcher = newFileWatch()
    if not ok(watcher):
      err("watch: this platform gives no way to watch files")
  result = watcher

proc stringArg(env: ref Environment, args: seq[Object], i: int, what: string): string =
  if i >= args.len:
    err(what & " needs more arguments")
  let v = eval(args[i], env)
  if not isString(v):
    err(what & " needs a string, got " & stringify(v))
  toStr(v)

proc numberArg(env: ref Environment, args: seq[Object], i: int, what: string): float64 =
  if i >= args.len:
    err(what & " needs more arguments")
  let v = eval(args[i], env)
  if not isNumber(v):
    err(what & " needs a number, got " & stringify(v))
  toNumber(v)

func kindName(k: WatchKind): string =
  case k
  of Created: "created"
  of Modified: "modified"
  of Removed: "removed"

proc addTree(w: FileWatch, dir: string) =
  ## Watch `dir` and everything under it. A directory added later shows up at
  ## the next change in its parent, when the walk runs again. Hidden entries
  ## (a name starting with a dot) are skipped along with their subtrees, so
  ## `.git`, build droppings and editor state never wake the caller; events
  ## for them stay unread in the kernel queue, and every drain clears them.
  if not watchDir(w, dir):
    return
  var entries: seq[string] = @[]
  for kind, path in walkDir(dir):
    let name = $path
    when defined(windows):
      let at = max(name.rfind('/'), name.rfind('\\'))
    else:
      let at = name.rfind('/')
    let leaf = substr(name, at + 1)
    if kind in {PathComponent.pcDir, PathComponent.pcLinkToDir} and
        not su.startsWith(leaf, "."):
      entries.add name
  for path in entries:
    addTree(w, path)

proc watchDirBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object =
  # watch-dir dir: watch a directory and everything below it. Hidden names
  # (starting with a dot) are skipped with their subtrees. The path is kept:
  # a repeated call walks the tree again, so directories created since the
  # last one get watched too.
  let dir = stringArg(env, args, 0, "watch-dir")
  if not dirExists(dir):
    err("watch-dir: no such directory: " & dir)
  let w = ensureWatcher()
  addTree(w, dir)
  if dir notin roots:
    roots.add dir
  boolean(true)

proc drain(w: FileWatch) =
  ## Fold fresh events into `pending`: one entry per path, remembering the
  ## strongest news (a created then modified file is still worth a build).
  for e in poll(w):
    var found = -1
    for i, held in pending:
      if held.path == e.path:
        found = i
        break
    if found < 0:
      pending.add e
    elif e.kind == Modified or pending[found].kind != Modified:
      pending[found] = e

proc watchWaitBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object =
  # watch-wait ms: sleep until a watched directory changes, or ms passes
  # (-1 waits forever, 0 just looks). True when there is news to read.
  var ms: float64 = -1
  if args.len > 0:
    ms = numberArg(env, args, 0, "watch-wait")
  let w = ensureWatcher()
  drain(w)
  while true:
    if pending.len > 0 or w.descriptor < 0 or ms == 0:
      break
    # block in the kernel until inotify says something; no polling here
    if not waitForReadable(w.descriptor, int(ms)):
      break
    drain(w)
  boolean(pending.len > 0)

proc watchChangesBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object =
  # watch-changes: what changed since the last call, drained without blocking;
  # a list of (path = ... kind = ...) records.
  if watcher != nil:
    drain(watcher)
  var items: seq[Object] = @[]
  for e in pending:
    items.add record(@[pair(symbol("path"), str(e.path)),
      pair(symbol("kind"), str(kindName(e.kind)))])
  pending = @[]
  list(items)

proc installWatch*(env: ref Environment) =
  define(env, symbol("watch-dir"), newBuiltin("watch-dir", watchDirBuiltin, true))
  define(env, symbol("watch-wait"), newBuiltin("watch-wait", watchWaitBuiltin, true))
  define(env, symbol("watch-changes"), newBuiltin("watch-changes", watchChangesBuiltin, true))

proc watchModule*(): Module =
  result = newModule("watch")
  installWatch(result.env)
  exportAllBindings(result)
