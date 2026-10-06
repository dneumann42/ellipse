## The wall clock, read from the C runtime.
##
## `std/times` is not nimony-reachable here and SDL has no clock-of-day,
## so the base library owns the small `time.h` binding -- apps should not
## hand-`importc` libc the way Duck used to. `stamp`-style formatting is
## the app's business; `now()` hands back the broken-down local time.

type
  CTm {.importc: "struct tm", header: "<time.h>".} = object
    tm_sec, tm_min, tm_hour, tm_mday, tm_mon, tm_year, tm_wday, tm_yday, tm_isdst: int

  ClockTime* = object
    ## Local calendar time as of the `now()` call. `month` is 1-based.
    year*, month*, day*, hour*, minute*, second*: int

proc c_time(t: nil pointer): int64 {.importc: "time", header: "<time.h>".}
proc c_localtime(t: ptr int64): nil ptr CTm {.
  importc: "localtime", header: "<time.h>".}

proc now*(): ClockTime =
  ## The local wall clock; all zeroes when the C runtime cannot break it
  ## down (no timezone data).
  var t = c_time(nil)
  let tm = c_localtime(addr t)
  if tm == nil:
    return ClockTime()
  ClockTime(year: tm[].tm_year + 1900, month: tm[].tm_mon + 1,
            day: tm[].tm_mday, hour: tm[].tm_hour,
            minute: tm[].tm_min, second: tm[].tm_sec)
