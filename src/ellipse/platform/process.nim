## Child processes, polled from the frame loop -- SDL's process API, which
## covers POSIX and Windows alike.
##
##   var p = spawnProcess(@[getAppFilename(), "--flag"])
##   ...every frame:
##   if p.poll():            # drained stdout, and the child has exited
##     echo p.output, p.exitCode
##     p.close()
##
## The child's stdout is piped back and read without blocking: `poll`
## takes whatever is ready, so a chatty child never stalls on a full pipe.
## stdin is /dev/null (NUL:), stderr goes where ours goes.

import ./termmode

when withSdl:
  type
    SDL_Process {.importc: "SDL_Process", header: "<SDL3/SDL.h>".} = object

    ChildProcess* = object
      raw: ptr SDL_Process
      output*: string      ## stdout so far
      exited*: bool
      exitCode*: int32

  proc ellipse_spawn(joined: cstring; count: int32): ptr SDL_Process {.
    importc: "ellipse_spawn".}
  proc ellipse_read_ready(p: ptr SDL_Process; buf: cstring; cap: int32): int32 {.
    importc: "ellipse_read_ready".}
  proc SDL_WaitProcess(p: ptr SDL_Process; blk: bool; code: ptr int32): bool {.
    importc: "SDL_WaitProcess", header: "<SDL3/SDL.h>".}
  proc SDL_KillProcess(p: ptr SDL_Process; force: bool): bool {.
    importc: "SDL_KillProcess", header: "<SDL3/SDL.h>".}
  proc SDL_DestroyProcess(p: ptr SDL_Process) {.
    importc: "SDL_DestroyProcess", header: "<SDL3/SDL.h>".}

  proc spawnProcess*(args: seq[string]): ChildProcess =
    ## Start `args[0]` with the rest as its arguments. `running` reports
    ## whether it started.
    result = ChildProcess()
    if args.len == 0:
      return
    var joined = ""
    for a in args:
      joined.add a
      joined.add '\0'
    let p = ellipse_spawn(joined.cstring, int32(args.len))
    if p != nil:
      result.raw = p

  proc running*(p: ChildProcess): bool =
    ## Started and not yet closed.
    p.raw != nil

  proc drain(p: var ChildProcess) =
    let raw = p.raw
    if raw == nil:
      return
    var buf = newString(4096)
    while true:
      let n = ellipse_read_ready(raw, buf.cstring, int32(buf.len))
      if n <= 0:
        break
      var i = 0
      while i < int(n):
        p.output.add buf[i]
        inc i

  proc poll*(p: var ChildProcess): bool =
    ## Read the stdout that is ready, then check on the child: true once it
    ## has exited (and its output is complete). Never blocks.
    let raw = p.raw
    if raw == nil:
      return p.exited
    drain(p)
    var code = 0'i32
    if SDL_WaitProcess(raw, false, addr code):
      drain(p)
      p.exited = true
      p.exitCode = code
    p.exited

  proc kill*(p: var ChildProcess) =
    ## Ask the child to stop (SIGTERM / TerminateProcess).
    let raw = p.raw
    if raw != nil and not p.exited:
      discard SDL_KillProcess(raw, false)

  proc close*(p: var ChildProcess) =
    ## Release the handle. A child still running keeps running.
    let raw = p.raw
    if raw != nil:
      SDL_DestroyProcess(raw)
      p.raw = nil
else:
  # No SDL, no process API: a build without SDL runs only in the terminal,
  # where dialogs open inline and nothing spawns a dialog process. A spawn
  # reports that nothing started.
  type
    ChildProcess* = object
      output*: string
      exited*: bool
      exitCode*: int32

  proc spawnProcess*(args: seq[string]): ChildProcess = ChildProcess()
  proc running*(p: ChildProcess): bool = false
  proc poll*(p: var ChildProcess): bool = p.exited
  proc kill*(p: var ChildProcess) = discard
  proc close*(p: var ChildProcess) = discard
