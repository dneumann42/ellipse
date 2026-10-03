## Sorted identity-keyed association map.
##
## Nimony binds generic bodies eagerly, so key operations are declared via
## the `Ordered` concept (Nimony's own `std/tables` uses the same style with
## `Keyable`). The upstream `withValue` templates and `mpairs` iterator are
## replaced by the public `entries` sequence plus `findIndex`, which the
## solver walks by index.

type
  Ordered* = concept
    func `<`(a, b: Self): bool
    func `==`(a, b: Self): bool

  AssocEntry*[K, V] = object
    key*: K
    val*: V

  AssocMap*[K, V] = object
    entries*: seq[AssocEntry[K, V]]

func lowerIndex[K: Ordered, V](map: AssocMap[K, V], key: K): int {.inline.} =
  var low = 0
  var high = map.entries.len
  while low < high:
    let mid = (low + high) shr 1
    if map.entries[mid].key < key:
      low = mid + 1
    else:
      high = mid
  low

func findIndex*[K: Ordered, V](map: AssocMap[K, V], key: K): int {.inline.} =
  result = map.lowerIndex(key)
  if result >= map.entries.len or not (map.entries[result].key == key):
    result = -1

func initAssocMap*[K, V](): AssocMap[K, V] {.inline.} =
  AssocMap[K, V](entries: @[])

func len*[K, V](map: AssocMap[K, V]): int {.inline.} =
  map.entries.len

func hasKey*[K: Ordered, V](map: AssocMap[K, V], key: K): bool {.inline.} =
  map.findIndex(key) >= 0

func `[]`*[K: Ordered, V](map: AssocMap[K, V], key: K): V {.inline, raises.} =
  let index = map.findIndex(key)
  if index < 0:
    raise KeyError
  map.entries[index].val

func `[]=`*[K: Ordered, V](map: var AssocMap[K, V], key: K, value: V) {.inline.} =
  let index = map.lowerIndex(key)
  if index < map.entries.len and map.entries[index].key == key:
    map.entries[index].val = value
  else:
    # Nimony has no 3-argument `insert`; append then shift into place.
    map.entries.add(AssocEntry[K, V](key: key, val: value))
    var position = map.entries.high
    while position > index:
      # temp copy: Nimony rejects `s[i] = s[i-1]` as aliasing
      let prev = map.entries[position - 1]
      map.entries[position] = prev
      dec position
    map.entries[index] = AssocEntry[K, V](key: key, val: value)

func del*[K: Ordered, V](map: var AssocMap[K, V], key: K) {.inline.} =
  let index = map.findIndex(key)
  if index >= 0:
    map.entries.delete(index)

func pop*[K: Ordered, V](map: var AssocMap[K, V], key: K, value: var V): bool {.inline.} =
  result = false
  let index = map.findIndex(key)
  if index >= 0:
    value = map.entries[index].val
    map.entries.delete(index)
    result = true

func getOrDefault*[K: Ordered, V](
    map: AssocMap[K, V], key: K, default: V
): V {.inline.} =
  let index = map.findIndex(key)
  if index >= 0:
    map.entries[index].val
  else:
    default

iterator keys*[K, V](map: AssocMap[K, V]): K =
  for entry in map.entries:
    yield entry.key

iterator pairs*[K, V](map: AssocMap[K, V]): (K, V) =
  for entry in map.entries:
    yield (entry.key, entry.val)
