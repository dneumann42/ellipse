## Texture splatting: ground drawn from a set of tiling textures, each vertex
## carrying how much of every texture shows at that spot. The textures come
## from a `TextureAtlas`, a CPU image of square cells side by side, which the
## artist turns into one GPU array layer per cell: every cell repeats and
## filters on its own, so no cell bleeds into its neighbour and tiling leaves
## no seam. Where layers meet, each texture's alpha is a height -- rock stands
## proud of grass, grass of sand -- and the blend lets the higher one win
## within a soft band, so borders read as ground, not as a crossfade.

import sdl3, sdl3_image

import ../platform/gpu
import geometry

const
  SplatLayers* = 8 ## textures a splatted surface can blend between

type
  SplatVertex* = object
    position*: Vec3
    normal*: Vec3
    low*: Vec4 ## weights of layers 0 to 3
    high*: Vec4 ## and of layers 4 to 7; all eight sum to 1

  TextureAtlas* = object
    ## Square cells of `cell` pixels, `columns` across and `rows` down, in
    ## one RGBA8 image read row by row from the top. Alpha is each texel's
    ## height for the blend between layers, not its opacity.
    cell*: int
    columns*, rows*: int
    pixels*: seq[uint8]

  SplatOptions* = object
    metersPerRepeat*: float32 ## world distance one cell's texture spans
    blendDepth*: float32 ## how soft a border between layers is: 0 a hard
    ## edge along the height, larger a wider band where both show
    heightContrast*: float32 ## how much the texel heights decide a border
    ## against the painted weights

const
  SplatAttributes*: seq[Attribute] = @[
    Attribute(location: 0, offset: 0, format: Float3),
    Attribute(location: 1, offset: 12, format: Float3),
    Attribute(location: 2, offset: 24, format: Float4),
    Attribute(location: 3, offset: 40, format: Float4),
  ]
  SplatStride* = uint32 sizeof(SplatVertex)

func newSplatOptions*(metersPerRepeat = 6.0f, blendDepth = 0.25f,
                      heightContrast = 0.6f): SplatOptions =
  SplatOptions(metersPerRepeat: metersPerRepeat, blendDepth: blendDepth,
               heightContrast: heightContrast)

func newTextureAtlas*(cell, columns, rows: int): TextureAtlas =
  TextureAtlas(cell: cell, columns: columns, rows: rows,
               pixels: newSeq[uint8](cell * columns * cell * rows * 4))

func cells*(atlas: TextureAtlas): int =
  atlas.columns * atlas.rows

func width*(atlas: TextureAtlas): int =
  atlas.cell * atlas.columns

func height*(atlas: TextureAtlas): int =
  atlas.cell * atlas.rows

func texelIndex*(atlas: TextureAtlas, cell, x, y: int): int =
  ## Where pixel (`x`, `y`) of cell `cell` starts in `pixels`: cells run
  ## left to right, then top to bottom.
  let
    left = (cell mod atlas.columns) * atlas.cell
    top = (cell div atlas.columns) * atlas.cell
  ((top + y) * atlas.width + left + x) * 4

func layered*(atlas: TextureAtlas): seq[uint8] =
  ## The cells one after another, each a whole picture of its own: the
  ## layout an array texture is uploaded from.
  let
    side = atlas.cell
    row = side * 4
  result = newSeq[uint8](atlas.cells * side * row)
  for cell in 0 ..< atlas.cells:
    for y in 0 ..< side:
      copyMem(addr result[(cell * side + y) * row],
              unsafeAddr atlas.pixels[atlas.texelIndex(cell, 0, y)], row)

proc readTextureAtlas*(path: string, cell: int): TextureAtlas =
  ## An atlas of square cells of `cell` pixels from an image on disk (PNG or
  ## anything else SDL_image reads), its alpha taken as the texel heights: a
  ## fully opaque image blends its layers by weight alone. The image may be
  ## any whole number of cells across and down; that many cells it holds.
  ## Returns an atlas with a `cell` of 0 when the file cannot be read or is
  ## not a whole number of cells either way.
  let loaded = sdl3_image.load(path.cstring)
  if loaded.isNil:
    return
  let rgba = convertSurface(loaded, PIXELFORMAT_RGBA32)
  destroySurface(loaded)
  if rgba.isNil:
    return
  let
    width = rgba.w.int
    height = rgba.h.int
  if cell > 0 and width > 0 and height > 0 and width mod cell == 0 and
      height mod cell == 0:
    result = newTextureAtlas(cell, width div cell, height div cell)
    for y in 0 ..< height:
      copyMem(addr result.pixels[y * width * 4],
              addr rgba.pixels[y * rgba.pitch.int], width * 4)
  destroySurface(rgba)

func meanColor*(atlas: TextureAtlas, cell: int): Vec4 =
  ## The cell's average colour: what it reads as from far enough away.
  var r, g, b: float
  for y in 0 ..< atlas.cell:
    for x in 0 ..< atlas.cell:
      let at = atlas.texelIndex(cell, x, y)
      r += atlas.pixels[at].float
      g += atlas.pixels[at + 1].float
      b += atlas.pixels[at + 2].float
  let n = float(atlas.cell * atlas.cell) * 255.0
  vec4(float32(r / n), float32(g / n), float32(b / n), 1)
