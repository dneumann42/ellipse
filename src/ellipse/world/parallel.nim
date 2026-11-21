{.push gcsafe.}

# Generation modules open with these two pragmas: -O3 keeps debug builds fast.
{.localPassC: "-O3 -fno-math-errno".}
{.push stackTrace: off, lineTrace: off.}

import std/[cpuinfo, math]

{.emit: """/*INCLUDESECTION*/
#ifdef _OPENMP
#include <omp.h>
#endif
""".}

type
  Buffer*[T] = object
    ## Unchecked view of an existing sequence's samples.
    data: ptr UncheckedArray[T]

  Grid*[T] = object
    ## Unchecked row-major view of a size-by-size grid in an existing sequence.
    data: ptr UncheckedArray[T]
    size*: int

{.push boundChecks: off, overflowChecks: off, rangeChecks: off.}

func buffer*[T](samples: openArray[T]): Buffer[T] =
  ## The sequence must outlive the view and keep its length.
  if samples.len == 0:
    Buffer[T]()
  else:
    Buffer[T](data: cast[ptr UncheckedArray[T]](unsafeAddr samples[0]))

func grid*[T](samples: openArray[T], size: int): Grid[T] =
  if samples.len == 0:
    Grid[T](size: size)
  else:
    Grid[T](data: cast[ptr UncheckedArray[T]](unsafeAddr samples[0]), size: size)

func `[]`*[T](view: Buffer[T], index: int): var T =
  view.data[index]

func `[]`*[T](view: Grid[T], index: int): var T =
  view.data[index]

func `[]`*[T](view: Grid[T], x, z: int): var T =
  view.data[x * view.size + z]

func clamped*[T](view: Grid[T], x, z: int): T =
  ## Sample nearest to (x, z), clamped to the border.
  view[x.clamp(0, view.size - 1), z.clamp(0, view.size - 1)]

const balanced* = "parallel for schedule(guided)"
  ## Use as `for x in `||`(a, b, balanced)`; wrapping `||` in an iterator
  ## shares the loop variable across threads.

proc chunkCount*(total: int, perCore: int = 8): int =
  clamp(countProcessors() * perCore, 1, max(total, 1))

{.pop.}

proc threads*(): int =
  var count: cint = 1
  {.emit: """
#ifdef _OPENMP
`count` = omp_get_max_threads();
#endif
""".}
  count.int

proc useThreads*(count: int) =
  ## Per-thread setting: affects only loops started from this thread.
  let wanted = max(1, count).cint
  {.emit: """
#ifdef _OPENMP
omp_set_num_threads(`wanted`);
#endif
""".}

template alone*(body: untyped) =
  ## Run `body` with its parallel loops on this thread alone.
  let before = threads()
  useThreads(1)
  try:
    body
  finally:
    useThreads(before)
