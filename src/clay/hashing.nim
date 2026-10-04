## Clay id hashing, ported 1:1 from `Clay__HashNumber` / `Clay__HashString` /
## `Clay__HashStringWithOffset` so ids remain stable and collision-compatible.
## All arithmetic is uint32 wrap-around, exactly like the C original.
## This fragment is included by clay.nim; it must not import anything.

const
  nullId* = 0'u32 ## Reserved: "no id". Every hash adds 1 to avoid it.
  rootContainerLabel* = "clay_root_container" ## synthetic layout root's id label

func hashNumber*(offset, seed: uint32): uint32 =
  var hash = seed
  hash += offset + 48
  hash += hash shl 10
  hash = hash xor (hash shr 6)
  hash += hash shl 3
  hash = hash xor (hash shr 11)
  hash += hash shl 15
  hash + 1

func hashString*(label: string; seed: uint32 = 0): uint32 =
  var hash = seed
  for c in label:
    hash += uint32(ord(c))
    hash += hash shl 10
    hash = hash xor (hash shr 6)
  hash += hash shl 3
  hash = hash xor (hash shr 11)
  hash += hash shl 15
  hash + 1

func hashStringWithOffset*(label: string; offset, seed: uint32): uint32 =
  var base = seed
  for c in label:
    base += uint32(ord(c))
    base += base shl 10
    base = base xor (base shr 6)
  var hash = base
  hash += offset
  hash += hash shl 10
  hash = hash xor (hash shr 6)
  hash += hash shl 3
  base += base shl 3
  hash = hash xor (hash shr 11)
  base = base xor (base shr 11)
  hash += hash shl 15
  base += base shl 15
  hash + 1

func makeId*(id, baseId: uint32; label: string): ElementId =
  ## Build a fully resolved id, e.g. one computed at compile time by the
  ## `hashId` plugin (`id == baseId == hashString(label) + 1`).
  ElementId(id: id, offset: 0, baseId: baseId, label: label)

func makeId*(id, baseId: int; label: string): ElementId =
  ## Signed-int flavour used by the plugins: integer literals arrive as `int`,
  ## so no explicit cast is needed at the (semi-)generated call sites.
  ElementId(id: uint32(id), offset: 0, baseId: uint32(baseId), label: label)

func elementId*(label: string): ElementId =
  ## Runtime equivalent of Clay's `CLAY_ID` / `CLAY_SID`.
  let h = hashString(label, 0)
  ElementId(id: h, offset: 0, baseId: h, label: label)

func elementIdWithIndex*(label: string; index: uint32): ElementId =
  ## Runtime equivalent of Clay's `CLAY_IDI` / `CLAY_SIDI`: avoids building
  ## dynamic strings in loops by mixing `index` into the hash.
  ElementId(
    id: hashStringWithOffset(label, index, 0),
    offset: index,
    baseId: hashString(label, 0),
    label: label,
  )
