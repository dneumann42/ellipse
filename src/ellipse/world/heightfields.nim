## Square height samples in X-major order, with Z contiguous.

type
  Field* = ref object
    size*: int
    step*: float32
    data*: seq[float32]

func newField*(size: int, step: float32 = 1): Field =
  Field(size: size, step: step, data: newSeq[float32](size * size))

func newFieldUninit*(size: int, step: float32 = 1): Field =
  ## For passes that write every sample.
  Field(size: size, step: step, data: newSeqUninit[float32](size * size))

func `[]`*(field: Field, x, z: int): float32 {.inline.} =
  field.data[x.clamp(0, field.size - 1) * field.size + z.clamp(0, field.size - 1)]

func `[]=`*(field: Field, x, z: int, value: float32) {.inline.} =
  field.data[x.clamp(0, field.size - 1) * field.size + z.clamp(0, field.size - 1)] = value

{.push boundChecks: off, overflowChecks: off, rangeChecks: off.}

func metersAt*(field: Field, x, z: int): tuple[x, z: float32] {.inline, raises: [].} =
  let half = (field.size - 1).float32 / 2.0f * field.step
  (x.float32 * field.step - half, z.float32 * field.step - half)

{.pop.}

func bilinearHeight*(field: Field, x, z: float32): float32 =
  ## Coordinates are in sample units. Heights extend flat beyond each edge.
  let
    fx = clamp(x, 0f, (field.size - 1).float32)
    fz = clamp(z, 0f, (field.size - 1).float32)
    i = fx.int
    j = fz.int
    u = fx - i.float32
    v = fz - j.float32
    near = field[i, j]
    far = field[i, j + 1]
    a = near + (field[i + 1, j] - near) * u
    b = far + (field[i + 1, j + 1] - far) * u
  a + (b - a) * v
