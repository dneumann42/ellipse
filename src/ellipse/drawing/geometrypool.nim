## Shared GPU buffers for recorded geometry. Thousands of small static meshes
## each with their own vertex and index buffers make every frame bind (and the
## driver track) thousands of buffers. Here they are ranges of a few large
## buffers instead: a draw binds a chunk once and selects a mesh with its
## first index and vertex offset.
{.push gcsafe.}

import std/locks
import ellipse/platform/gpu

type
  PoolChunk = object
    buffer: DynamicBuffer
    capacity: uint32 ## elements
    free: seq[tuple[first, count: uint32]] ## sorted, coalesced

  GeometryPool* = ref object
    device: Device
    usages: set[BufferUsage]
    stride: uint32 ## bytes per element
    chunkElements: uint32
    chunks: seq[PoolChunk]
    lock: Lock

  PoolRange* = object
    pool: GeometryPool
    chunk*: int ## -1: none
    first*, count*: uint32 ## elements

  GeometryLeaseObj* = object
    ## A mesh's vertex and index ranges; returned to their pools when the
    ## mesh that holds the lease is freed.
    vertices*, indices*: PoolRange
  GeometryLease* = ref GeometryLeaseObj

proc newGeometryPool*(device: Device, usages: set[BufferUsage], stride: uint32,
                      chunkBytes = 64'u32 shl 20): GeometryPool =
  result = GeometryPool(device: device, usages: usages, stride: stride,
    chunkElements: max(1'u32, chunkBytes div stride))
  initLock(result.lock)

proc allocate*(pool: GeometryPool, count: uint32): PoolRange =
  ## First fit over the chunks; a new chunk when none has room.
  result = PoolRange(pool: pool, chunk: -1)
  if count == 0: return
  withLock pool.lock:
    for c in 0 ..< pool.chunks.len:
      template free: untyped = pool.chunks[c].free
      for i in 0 ..< free.len:
        if free[i].count >= count:
          result.chunk = c
          result.first = free[i].first
          result.count = count
          free[i].first += count
          free[i].count -= count
          if free[i].count == 0: free.delete(i)
          return
    let capacity = max(pool.chunkElements, count)
    pool.chunks.add PoolChunk(
      buffer: newFixedBuffer(pool.device, pool.usages, capacity * pool.stride),
      capacity: capacity)
    result.chunk = pool.chunks.high
    result.first = 0
    result.count = count
    if capacity > count:
      pool.chunks[^1].free.add (count, capacity - count)

proc release*(range: var PoolRange) =
  if range.pool.isNil or range.chunk < 0 or range.count == 0: return
  let pool = range.pool
  withLock pool.lock:
    template free: untyped = pool.chunks[range.chunk].free
    var i = 0
    while i < free.len and free[i].first < range.first: inc i
    free.insert((range.first, range.count), i)
    # Coalesce with the following and the preceding free span.
    if i + 1 < free.len and free[i].first + free[i].count == free[i+1].first:
      free[i].count += free[i+1].count
      free.delete(i+1)
    if i > 0 and free[i-1].first + free[i-1].count == free[i].first:
      free[i-1].count += free[i].count
      free.delete(i)
  range.chunk = -1
  range.count = 0

proc `=destroy`*(lease: var GeometryLeaseObj) =
  lease.vertices.release()
  lease.indices.release()

proc buffer*(pool: GeometryPool, chunk: int): DynamicBuffer =
  withLock pool.lock:
    result = pool.chunks[chunk].buffer

proc write*[T](cmd: CommandBuffer, range: PoolRange, data: openArray[T]) =
  ## Upload `data` into the range it was allocated for.
  if data.len == 0 or range.chunk < 0: return
  assert sizeof(T).uint32 == range.pool.stride and data.len.uint32 <= range.count
  cmd.uploadInto(range.pool.buffer(range.chunk), unsafeAddr data[0],
    (data.len * sizeof(T)).uint32, range.first * range.pool.stride)

proc chunkCount*(pool: GeometryPool): int =
  withLock pool.lock:
    result = pool.chunks.len
