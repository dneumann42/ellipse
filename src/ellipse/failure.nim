## The ellipse kit's own error, replacing nimony's built-in `Failure` bare
## raise type. Standard Nim raises heap-allocated (`ref object`) errors, so
## aborts carry this type; a bare `raise Failure` in the nimony sources
## becomes `raise (ref Failure)()`, and `fail(msg)` raises it with `msg`.
## Nothing inspects the object beyond its message -- the kit still routes
## CLI aborts through `failMsg` and error reporting through the log.

type
  Failure* = ref object of CatchableError
