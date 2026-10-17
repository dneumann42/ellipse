import std/oserrors

when defined(windows):
  proc rtlGenRandom(buf: pointer, length: culong): uint8
    {.importc: "SystemFunction036", header: "<windows.h>", dynlib: "advapi32".}
  proc fill(buf: pointer, length: int)  =
    if rtlGenRandom(buf, culong(length)) == 0:
      raiseOSError(osLastError())

elif defined(linux):
  proc getrandom(buf: pointer, count: csize_t, flags: cuint): clong
    {.importc: "getrandom", header: "<sys/random.h>".}

  proc fill(buf: pointer, length: int)  =
    var
      offset = 0
      p = cast[ptr UncheckedArray[byte]](buf)
    while offset < length:
      let read = getrandom(addr p[offset], csize_t(length - offset), 0'u32)
      if read < 0:
        raiseOSError(osLastError())
      inc offset, int(read)

elif defined(posix):
  proc getentropy(buf: pointer, length: csize_t): cint
    {.importc: "getentropy", header: "<unistd.h>".}

  proc fill(buf: pointer, length: int)  =
    var
      offset = 0
      p = cast[ptr UncheckedArray[byte]](buf)
    while offset < length:
      # getentropy is only guaranteed for requests of at most 256 bytes.
      let count = min(length - offset, 256)
      if getentropy(addr p[offset], csize_t(count)) != 0:
        raiseOSError(osLastError())
      inc offset, count

else:
  proc fill(buf: pointer, length: int) =
    {.error: "sysrand: unsupported platform".}

proc urandom*(len: int): seq[byte]  =
  result = newSeq[byte](len)
  if len > 0:
    fill(addr result[0], len)

proc rand32*(): uint32  =
  let buf = urandom(4)
  result = 0'u32
  for i in 0 ..< 4:
    result = result or (uint32(buf[i]) shl (i * 8))

when isMainModule:
  import std/[syncio]
  try:
    var sum = 0
    for b in urandom(8):
      sum += int(b)
    echo sum
    echo rand32()
  except CatchableError:
    echo "sysrand: failed to obtain random bytes"
