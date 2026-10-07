import std/[syncio, strutils, os, osproc]
import std/posix/posix
import owl/[objects, evaluator, modules]

# Unix sockets, child processes and file-change notification: the system
# boundary for attaching a repl to a running owl program and for reloading
# a project's modules when their files change. The protocols and servers
# themselves are owl (see attach.owl and gui.owl). File descriptors are
# plain numbers.

when defined(windows):
  proc netModule*(): Module =
    result = newModule("net")
    exportAllBindings(result)
else:
  {.compile: "owl_net.c".}

  proc owl_unix_listen(path: cstring): int32 {.importc: "owl_unix_listen".}
  proc owl_unix_connect(path: cstring): int32 {.importc: "owl_unix_connect".}
  proc owl_accept(fd: int32): int32 {.importc: "owl_accept".}
  proc owl_read(fd: int32; buf: cstring; cap, timeoutMs: int32): int32 {.importc: "owl_read".}
  proc owl_write_all(fd: int32; buf: cstring; len: int32): int32 {.importc: "owl_write_all".}
  proc owl_close(fd: int32) {.importc: "owl_close".}
  # std/posix has kill and nanosleep but not getpid.
  proc c_getpid(): int32 {.importc: "getpid", header: "<unistd.h>".}
  proc owl_watch_open(): int32 {.importc: "owl_watch_open".}
  proc owl_watch_add(fd: int32; dir: cstring): int32 {.importc: "owl_watch_add".}
  proc owl_watch_read(fd: int32; buf: cstring; cap: int32): int32 {.importc: "owl_watch_read".}

  proc strArg(env: ref Environment, args: seq[Object], i: int, what: string): string {.raises.} =
    if i >= args.len:
      err(what & " needs more arguments")
    let v = eval(args[i], env)
    if not isString(v):
      err(what & " needs a string, got " & stringify(v))
    toStr(v)

  proc intArg(env: ref Environment, args: seq[Object], i: int, what: string): int32 {.raises.} =
    if i >= args.len:
      err(what & " needs more arguments")
    let v = eval(args[i], env)
    if not isNumber(v):
      err(what & " needs a number, got " & stringify(v))
    int32(toNumber(v))

  proc fdResult(fd: int32): Object =
    if fd < 0: nothing() else: number(float64(fd))

  proc unixListenBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
    # unix-listen path: a listening socket (owner-only) at path.
    var path = strArg(env, args, 0, "unix-listen")
    let fd = owl_unix_listen(path.toCString)
    if fd < 0:
      err("unix-listen: cannot listen on " & path)
    number(float64(fd))

  proc unixConnectBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
    # unix-connect path: a connected socket, or nothing when nobody listens.
    var path = strArg(env, args, 0, "unix-connect")
    fdResult(owl_unix_connect(path.toCString))

  proc sockAcceptBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
    # sock-accept fd: the next waiting connection, or nothing.
    fdResult(owl_accept(intArg(env, args, 0, "sock-accept")))

  proc sockReadBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
    # sock-read fd (timeout): what has arrived, "" when nothing did within
    # timeout ms (default: wait), nothing once the other end closed.
    let fd = intArg(env, args, 0, "sock-read")
    let timeout = if args.len > 1: intArg(env, args, 1, "sock-read") else: -1'i32
    var buf = newString(65536)
    let n = owl_read(fd, buf.toCString, int32(buf.len), timeout)
    if n == -2:
      result = str("")
    elif n <= 0:
      result = nothing()
    else:
      result = str(buf.substr(0, int(n) - 1))

  proc sockWriteBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
    let fd = intArg(env, args, 0, "sock-write")
    var text = strArg(env, args, 1, "sock-write")
    if text.len > 0 and owl_write_all(fd, text.toCString, int32(text.len)) != 0:
      err("sock-write: the connection is closed")
    nothing()

  proc sockCloseBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
    owl_close(intArg(env, args, 0, "sock-close"))
    nothing()

  proc processIdBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
    number(float64(c_getpid()))

  proc processAliveBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
    # process-alive pid: whether a process of that id exists (kill 0).
    let pid = intArg(env, args, 0, "process-alive")
    boolean(pid > 0 and posix.kill(Pid(pid), 0'i32) == 0'i32)

  proc killProcessBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
    # kill-process pid: ask it to stop (SIGTERM).
    discard posix.kill(Pid(intArg(env, args, 0, "kill-process")), SIGTERM)
    nothing()

  proc sleepMsBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
    let ms = intArg(env, args, 0, "sleep-ms")
    var req = Timespec(tv_sec: Time(ms div 1000), tv_nsec: clong(ms mod 1000) * 1_000_000)
    var rem = Timespec()
    discard nanosleep(req, rem)
    nothing()

  proc spawnProcessBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
    # spawn-process argv dir log: start argv (a list of strings, the program
    # first) detached in its own session in dir, stdin from /dev/null and its
    # output appended to log, so it outlives us. Gives the pid.
    if args.len != 3:
      err("spawn-process needs an argument list, a directory and a log file")
    let argv = eval(args[0], env)
    if not isList(argv) or itemCount(argv) == 0:
      err("spawn-process needs a list of strings, got " & stringify(argv))
    # The subshell execs setsid, which execs the program (it is no group
    # leader, so setsid does not fork): $! is the program's pid, and no
    # process keeps the pipe execCmdEx reads open.
    var cmd = "(cd " & quoteShell(strArg(env, args, 1, "spawn-process")) & " && exec setsid"
    for a in toSeq(argv):
      if not isString(a):
        err("spawn-process needs a list of strings, got " & stringify(argv))
      cmd.add " " & quoteShell(toStr(a))
    cmd.add " >> " & quoteShell(strArg(env, args, 2, "spawn-process")) &
      " 2>&1 < /dev/null) > /dev/null 2>&1 & echo $!"
    var output = ""
    var code = 1
    try:
      (output, code) = execCmdEx(cmd)
    except:
      code = 1
    let pid = output.strip()
    if code != 0 or pid.len == 0:
      err("spawn-process: cannot start " & stringify(itemAt(argv, 0)) & ": " & output)
    var n = 0
    for c in pid:
      if c in {'0'..'9'}:
        n = n * 10 + (ord(c) - ord('0'))
    number(float64(n))

  proc exePathBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
    # exe-path: the running program's file.
    str(getAppFilename())

  proc watchOpenBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
    # watch-open: a descriptor that turns readable when watched directories
    # change (inotify).
    let fd = owl_watch_open()
    if fd < 0:
      err("watch-open: file watching is unavailable")
    number(float64(fd))

  proc watchAddBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
    # watch-add fd dir: watch dir (not its subdirectories); gives its watch
    # number, which watch-read reports changes under.
    let fd = intArg(env, args, 0, "watch-add")
    var dir = strArg(env, args, 1, "watch-add")
    let wd = owl_watch_add(fd, dir.toCString)
    if wd < 0:
      err("watch-add: cannot watch " & dir)
    number(float64(wd))

  proc watchReadBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object {.raises.} =
    # watch-read fd: the changes since the last read, as records of the
    # watch number and the file name, oldest first.
    let fd = intArg(env, args, 0, "watch-read")
    var buf = newString(65536)
    let n = owl_watch_read(fd, buf.toCString, int32(buf.len))
    var items: seq[Object] = @[]
    for line in buf.substr(0, int(n) - 1).split('\n'):
      let tab = line.find('\t')
      if tab > 0:
        var wd = 0
        for c in line.substr(0, tab - 1):
          wd = wd * 10 + (ord(c) - ord('0'))
        items.add record(@[pair(symbol("watch"), number(float64(wd))),
          pair(symbol("name"), str(line.substr(tab + 1)))])
    list(items)

  proc installNet*(env: ref Environment) =
    define(env, symbol("unix-listen"), newBuiltin("unix-listen", unixListenBuiltin, true))
    define(env, symbol("unix-connect"), newBuiltin("unix-connect", unixConnectBuiltin, true))
    define(env, symbol("sock-accept"), newBuiltin("sock-accept", sockAcceptBuiltin, true))
    define(env, symbol("sock-read"), newBuiltin("sock-read", sockReadBuiltin, true))
    define(env, symbol("sock-write"), newBuiltin("sock-write", sockWriteBuiltin, true))
    define(env, symbol("sock-close"), newBuiltin("sock-close", sockCloseBuiltin, true))
    define(env, symbol("process-id"), newBuiltin("process-id", processIdBuiltin, true))
    define(env, symbol("process-alive"), newBuiltin("process-alive", processAliveBuiltin, true))
    define(env, symbol("kill-process"), newBuiltin("kill-process", killProcessBuiltin, true))
    define(env, symbol("sleep-ms"), newBuiltin("sleep-ms", sleepMsBuiltin, true))
    define(env, symbol("spawn-process"), newBuiltin("spawn-process", spawnProcessBuiltin, true))
    define(env, symbol("exe-path"), newBuiltin("exe-path", exePathBuiltin, true))
    define(env, symbol("watch-open"), newBuiltin("watch-open", watchOpenBuiltin, true))
    define(env, symbol("watch-add"), newBuiltin("watch-add", watchAddBuiltin, true))
    define(env, symbol("watch-read"), newBuiltin("watch-read", watchReadBuiltin, true))

  proc netModule*(): Module =
    result = newModule("net")
    installNet(result.env)
    exportAllBindings(result)
