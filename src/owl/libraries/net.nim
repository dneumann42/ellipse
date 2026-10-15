import std/[syncio, strutils, os, osproc]
import posix
import owl/[objects, evaluator, modules]


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
  proc c_getpid(): int32 {.importc: "getpid", header: "<unistd.h>".}
  proc owl_watch_open(): int32 {.importc: "owl_watch_open".}
  proc owl_watch_add(fd: int32; dir: cstring): int32 {.importc: "owl_watch_add".}
  proc owl_watch_read(fd: int32; buf: cstring; cap: int32): int32 {.importc: "owl_watch_read".}

  proc strArg(env: ref Environment, args: seq[Object], i: int, what: string): string  =
    if i >= args.len:
      err(what & " needs more arguments")
    let v = eval(args[i], env)
    if not isString(v):
      err(what & " needs a string, got " & stringify(v))
    toStr(v)

  proc intArg(env: ref Environment, args: seq[Object], i: int, what: string): int32  =
    if i >= args.len:
      err(what & " needs more arguments")
    let v = eval(args[i], env)
    if not isNumber(v):
      err(what & " needs a number, got " & stringify(v))
    int32(toNumber(v))

  proc fdResult(fd: int32): Object =
    if fd < 0: nothing() else: number(float64(fd))

  proc unixListenBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object  =
    var path = strArg(env, args, 0, "unix-listen")
    let fd = owl_unix_listen(path.cstring)
    if fd < 0:
      err("unix-listen: cannot listen on " & path)
    number(float64(fd))

  proc unixConnectBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object  =
    var path = strArg(env, args, 0, "unix-connect")
    fdResult(owl_unix_connect(path.cstring))

  proc sockAcceptBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object  =
    fdResult(owl_accept(intArg(env, args, 0, "sock-accept")))

  proc sockReadBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object  =
    let fd = intArg(env, args, 0, "sock-read")
    let timeout = if args.len > 1: intArg(env, args, 1, "sock-read") else: -1'i32
    var buf = newString(65536)
    let n = owl_read(fd, buf.cstring, int32(buf.len), timeout)
    if n == -2:
      result = str("")
    elif n <= 0:
      result = nothing()
    else:
      result = str(buf.substr(0, int(n) - 1))

  proc sockWriteBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object  =
    let fd = intArg(env, args, 0, "sock-write")
    var text = strArg(env, args, 1, "sock-write")
    if text.len > 0 and owl_write_all(fd, text.cstring, int32(text.len)) != 0:
      err("sock-write: the connection is closed")
    nothing()

  proc sockCloseBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object  =
    owl_close(intArg(env, args, 0, "sock-close"))
    nothing()

  proc processIdBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object  =
    number(float64(c_getpid()))

  proc processAliveBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object  =
    let pid = intArg(env, args, 0, "process-alive")
    boolean(pid > 0 and posix.kill(Pid(pid), 0'i32) == 0'i32)

  proc killProcessBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object  =
    discard posix.kill(Pid(intArg(env, args, 0, "kill-process")), SIGTERM)
    nothing()

  proc sleepMsBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object  =
    let ms = intArg(env, args, 0, "sleep-ms")
    var req = Timespec(tv_sec: Time(ms div 1000), tv_nsec: clong(ms mod 1000) * 1_000_000)
    var rem = Timespec()
    discard nanosleep(req, rem)
    nothing()

  proc spawnProcessBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object  =
    if args.len != 3:
      err("spawn-process needs an argument list, a directory and a log file")
    let argv = eval(args[0], env)
    if not isList(argv) or itemCount(argv) == 0:
      err("spawn-process needs a list of strings, got " & stringify(argv))
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

  proc exePathBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object  =
    str(getAppFilename())

  proc watchOpenBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object  =
    let fd = owl_watch_open()
    if fd < 0:
      err("watch-open: file watching is unavailable")
    number(float64(fd))

  proc watchAddBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object  =
    let fd = intArg(env, args, 0, "watch-add")
    var dir = strArg(env, args, 1, "watch-add")
    let wd = owl_watch_add(fd, dir.cstring)
    if wd < 0:
      err("watch-add: cannot watch " & dir)
    number(float64(wd))

  proc watchReadBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object  =
    let fd = intArg(env, args, 0, "watch-read")
    var buf = newString(65536)
    let n = owl_watch_read(fd, buf.cstring, int32(buf.len))
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
