{.push gcsafe.}

import std/[rlocks, syncio]

type
  LogResult* = enum
    Ok
    Disabled
    Truncated
    Error

  LogLevel* = enum
    Info
    Debug
    Warn
    Error

  LogHandler* = object
    onLog: proc(level: LogLevel; data: openArray[string]): LogResult {.closure.}

var
  logHandlers {.threadvar.}: seq[LogHandler]
  logLock: RLock

initRLock logLock

proc tag(level: LogLevel): string =
  case level
  of Info: "[INFO]: "
  of Debug: "[DEBUG]: "
  of Warn: "[WARN]: "
  of Error: "[ERROR]: "

proc addHandler*(handler: LogHandler) =
  acquire logLock
  defer: release logLock
  logHandlers.add handler

proc callHandlers*(level: LogLevel; data: openArray[string]): LogResult {.discardable.} =
  acquire logLock
  defer: release logLock
  result = Ok
  for handler in logHandlers:
    let res = handler.onLog(level, data)
    if res != Ok:
      return res

proc info*(data: varargs[string]): LogResult {.discardable.} =
  ## Log to every handler (`unpack()`-style varargs in the nimony kit;
  ## standard nim typed varargs here).
  callHandlers(Info, data)

proc debug*(data: varargs[string]): LogResult {.discardable.} =
  callHandlers(Debug, data)

proc warn*(data: varargs[string]): LogResult {.discardable.} =
  callHandlers(Warn, data)

proc error*(data: varargs[string]): LogResult {.discardable.} =
  callHandlers(Error, data)

proc initStandardLogger*(toStderr = false): LogHandler =
  ## Log lines to stdout -- or stderr, for a process whose stdout is a
  ## channel (a dialog process answers on it).
  if toStderr:
    proc emitErr(level: LogLevel; data: openArray[string]): LogResult {.closure.} =
      stderr.write tag(level)
      for line in data:
        stderr.write line
      stderr.write '\n'
      Ok
    return LogHandler(onLog: emitErr)
  proc emit(level: LogLevel; data: openArray[string]): LogResult {.closure.} =
    stdout.write tag(level)
    for line in data:
      stdout.write line
    stdout.write '\n'
    Ok
  LogHandler(onLog: emit)

proc initFileLogger*(path: string): LogHandler =
  proc emit(level: LogLevel; data: openArray[string]): LogResult {.closure.} =
    var stream: File
    if not stream.open(path, fmAppend):
      return LogResult.Error
    defer: stream.close()
    stream.write tag(level)
    for line in data:
      stream.write line
    stream.write '\n'
    Ok
  LogHandler(onLog: emit)
