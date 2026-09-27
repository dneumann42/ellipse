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
  logHandlers: seq[LogHandler]
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

proc callHandlers*(level: LogLevel; data: openArray[string]): LogResult =
  acquire logLock
  defer: release logLock
  for handler in logHandlers:
    let res = handler.onLog(level, data)
    if res != Ok:
      return res
  Ok

proc initStandardLogger*(): LogHandler =
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

proc info*(data: openArray[string]): LogResult {.discardable.} =
  callHandlers Info, data

proc debug*(data: openArray[string]): LogResult {.discardable.} =
  callHandlers Debug, data

proc warn*(data: openArray[string]): LogResult {.discardable.} =
  callHandlers Warn, data

proc error*(data: openArray[string]): LogResult {.discardable.} =
  callHandlers Error, data
