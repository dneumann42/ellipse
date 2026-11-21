{.push gcsafe.}

{.localPassC: "-O3 -fno-math-errno".} # see parallel.nim
{.push stackTrace: off, lineTrace: off.}
import std/math

{.push inline, boundChecks: off, overflowChecks: off, rangeChecks: off, raises: [].}

func mix*(a, b, t: float32): float32 =
  a + (b - a) * t

func smoothstep*(edge0, edge1, x: float32): float32 =
  let t = ((x - edge0) / (edge1 - edge0)).clamp(0, 1)
  t * t * (3.0f - 2.0f * t)

func fade(t: float32): float32 =
  t * t * t * (t * (t * 6.0f - 15.0f) + 10.0f)

func hash2(x, y, salt: int): float32 =
  # 32-bit wrapping matches 64-bit here: only the low 31 bits are kept.
  var h = (cast[uint32](x.int32) * 374761393'u32 + cast[uint32](y.int32) * 668265263'u32 +
           cast[uint32](salt.int32) * 1013904223'u32) and 0x7FFF_FFFF'u32
  h = ((h xor (h shr 6)) * 1274126177'u32) and 0x7FFF_FFFF'u32
  h = (h xor (h shr 13)) and 0x7FFF_FFFF'u32
  (h and 0x3FFF).float32 / 16383.0

func lattice(x: float32): int =
  ## `floor(x).int` without the libm call.
  result = x.int
  if x < result.float32:
    dec result

type
  Lattice* = object
    ## Cached corners of the cell one octave last read.
    ix, iy: int
    corners: array[4, float32]

  Octaves* = array[8, Lattice]
    ## One per read site, reset from `freshOctaves` each run; 8 octaves max.

const freshOctaves* = block:
  var cells: Octaves
  for cell in cells.mitems:
    cell.ix = low(int)
  cells

func corners(ix, iy, seed: int): array[4, float32] =
  [hash2(ix, iy, seed), hash2(ix + 1, iy, seed),
   hash2(ix, iy + 1, seed), hash2(ix + 1, iy + 1, seed)]

func blend(corners: array[4, float32], x, y: float32, ix, iy: int): float32 =
  let
    fx = fade(x - ix.float32)
    fy = fade(y - iy.float32)
  mix(mix(corners[0], corners[1], fx), mix(corners[2], corners[3], fx), fy)

func valueNoise*(x, y: float32, seed: int): float32 =
  let
    ix = lattice(x)
    iy = lattice(y)
  blend(corners(ix, iy, seed), x, y, ix, iy)

func valueNoise3*(x, y, z: float32, seed: int): float32 =
  ## Quintic interpolation of eight independently hashed 3D lattice corners.
  let ix = lattice(x)
  let iy = lattice(y)
  let iz = lattice(z)
  template corner(dx, dy, dz: int): float32 =
    block:
      # Mix Z into the salt with wrapping arithmetic, independent of X and Y.
      let salt = cast[int32](cast[uint32](seed.int32) xor
        (cast[uint32]((iz+dz).int32) * 2246822519'u32))
      hash2(ix+dx, iy+dy, salt.int)
  let u = fade(x-ix.float32)
  let v = fade(y-iy.float32)
  let w = fade(z-iz.float32)
  mix(mix(mix(corner(0,0,0),corner(1,0,0),u),
          mix(corner(0,1,0),corner(1,1,0),u),v),
      mix(mix(corner(0,0,1),corner(1,0,1),u),
          mix(corner(0,1,1),corner(1,1,1),u),v),w)

func valueNoise*(cell: var Lattice, x, y: float32, seed: int): float32 =
  let
    ix = lattice(x)
    iy = lattice(y)
  if ix != cell.ix or iy != cell.iy:
    cell = Lattice(ix: ix, iy: iy, corners: corners(ix, iy, seed))
  blend(cell.corners, x, y, ix, iy)

template octaveSum(x, y: float32, octaves: int, gain, lacunarity: float32,
                   noise: untyped): float32 =
  var
    total = 0.0f
    weight = 0.0f
    amplitude = 1.0f
    frequency = 1.0f
  for octave in 0 ..< octaves:
    total += amplitude * noise(octave, x * frequency, y * frequency)
    weight += amplitude
    amplitude *= gain
    frequency *= lacunarity
  total / weight

template ridgedSum(x, y: float32, octaves: int, gain, lacunarity: float32,
                   noise: untyped): float32 =
  var
    total = 0.0f
    weight = 0.0f
    amplitude = 1.0f
    frequency = 1.0f
    signal = 1.0f
  for octave in 0 ..< octaves:
    var ridge = 1.0f - abs(noise(octave, x * frequency, y * frequency) * 2.0f - 1.0f)
    ridge *= ridge
    total += amplitude * ridge * ridge * signal
    weight += amplitude
    signal = ridge
    amplitude *= gain
    frequency *= lacunarity
  total / weight

func fbm*(x, y: float32, seed: int, octaves: int = 4, gain: float32 = 0.5f,
          lacunarity: float32 = 2.0f): float32 =
  template plain(octave: int, u, v: float32): float32 = valueNoise(u, v, seed + octave)
  octaveSum(x, y, octaves, gain, lacunarity, plain)

func fbm*(cells: var Octaves, x, y: float32, seed: int, octaves: int = 4,
          gain: float32 = 0.5f, lacunarity: float32 = 2.0f): float32 =
  ## `fbm`, keeping each octave's lattice in `cells`.
  template kept(octave: int, u, v: float32): float32 =
    valueNoise(cells[octave], u, v, seed + octave)
  octaveSum(x, y, octaves, gain, lacunarity, kept)

func ridgedFbm*(x, y: float32, seed: int, octaves: int = 5, gain: float32 = 0.5f,
                lacunarity: float32 = 2.0f): float32 =
  template plain(octave: int, u, v: float32): float32 = valueNoise(u, v, seed + octave)
  ridgedSum(x, y, octaves, gain, lacunarity, plain)

func ridgedFbm*(cells: var Octaves, x, y: float32, seed: int, octaves: int = 5,
                gain: float32 = 0.5f, lacunarity: float32 = 2.0f): float32 =
  ## `ridgedFbm`, keeping each octave's lattice in `cells`.
  template kept(octave: int, u, v: float32): float32 =
    valueNoise(cells[octave], u, v, seed + octave)
  ridgedSum(x, y, octaves, gain, lacunarity, kept)

# Tiling noise: the lattice wraps every `periodX` by `periodY` cells.

func wrapped(i, period: int): int =
  let m = i mod period
  if m < 0: m + period else: m

func tiledNoise*(x, y: float32, periodX, periodY, seed: int): float32 =
  let
    ix = lattice(x)
    iy = lattice(y)
    x0 = wrapped(ix, periodX)
    x1 = wrapped(ix + 1, periodX)
    y0 = wrapped(iy, periodY)
    y1 = wrapped(iy + 1, periodY)
  blend([hash2(x0, y0, seed), hash2(x1, y0, seed),
         hash2(x0, y1, seed), hash2(x1, y1, seed)], x, y, ix, iy)

func tiledFbm*(x, y: float32, periodX, periodY, seed: int, octaves: int = 5,
               gain: float32 = 0.5f): float32 =
  template tiled(octave: int, u, v: float32): float32 =
    tiledNoise(u, v, periodX shl octave, periodY shl octave, seed + octave)
  octaveSum(x, y, octaves, gain, 2.0f, tiled)

func tiledRidged*(x, y: float32, periodX, periodY, seed: int, octaves: int = 5,
                  gain: float32 = 0.5f): float32 =
  var
    total = 0.0f
    weight = 0.0f
    amplitude = 1.0f
    signal = 1.0f
    scale = 1
  for octave in 0 ..< octaves:
    var ridge = 1.0f - abs(tiledNoise(x * scale.float32, y * scale.float32,
                                      periodX * scale, periodY * scale, seed + octave) * 2.0f - 1.0f)
    ridge *= ridge
    total += amplitude * ridge * signal
    weight += amplitude
    signal = ridge
    amplitude *= gain
    scale = scale * 2
  total / weight
