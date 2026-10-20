## Texture atlases: many small images packed into one picture, with an owl
## file beside it -- `decorations.png` comes with `decorations.png.owl` --
## naming where each image landed. The images are read from a folder of
## Aseprite files (composited straight from the source, see aseprite.nim)
## or PNGs, and each is named by its file name without the extension.
##
## Two packings: a *tile* atlas keeps a fixed order -- the order a tile
## already has in the atlas's owl file survives a rebuild, so tile indices
## saved elsewhere keep pointing at the same tile -- and a *sprite* atlas
## packs the largest images first. Both fill rows left to right, top to
## bottom, a row as tall as its tallest image.
##
## The owl file is an ordinary owl settings value, so it can be read, and
## hand-edited, like any other:
##
##   ; SpriteAtlasMeta -- owl settings
##   {}:
##       sprites = []:
##           {}:
##               name = "oak-tree"
##               transparent = true
##               x = 128
##               ...

import std/[algorithm, options, os, strutils, tables, typetraits]

import sdl3, sdl3_image

import owl/settings

import aseprite

type
  AtlasError* = object of CatchableError

  TileInfo* = object
    name*: string
    transparent*: bool
    order*: int
    x*, y*: int
    w*, h*: int

  SpriteInfo* = object
    name*: string
    transparent*: bool
    x*, y*: int
    w*, h*: int

  TileAtlasMeta* = object
    tiles*: seq[TileInfo]

  SpriteAtlasMeta* = object
    sprites*: seq[SpriteInfo]

  RgbaImage* = object
    ## Tightly packed RGBA8 rows, top row first.
    width*, height*: int
    pixels*: seq[uint8]

  NamedImage* = object
    name*: string
    image*: RgbaImage

  AtlasUvs* = object
    ## A region of an atlas in texture coordinates, (u0, v0) its top left.
    u0*, v0*, u1*, v1*: float32

  SpriteAtlas* = object
    ## An atlas as read back: the packed picture and where each sprite is.
    image*: RgbaImage
    meta*: SpriteAtlasMeta

  TileAtlas* = object
    image*: RgbaImage
    meta*: TileAtlasMeta

const
  AtlasSourceExtensions* = [".aseprite", ".ase", ".png"]

# Metadata ---------------------------------------------------------------------

proc atlasMetaPath*(atlasPath: string): string =
  ## The owl file that describes the atlas image at `atlasPath`.
  atlasPath & ".owl"

proc readMeta[T](path: string, t: typedesc[T]): T =
  if not fileExists(path):
    return
  try:
    let value = evaluate(settingsLibrary(), settingsRoot(), path, readFile(path))
    result = decode(value, T)
  except ValueError as e:
    raise newException(AtlasError, "cannot read atlas metadata " & path & ": " & e.msg)
  except IOError as e:
    raise newException(AtlasError, "cannot read atlas metadata " & path & ": " & e.msg)

proc readTileAtlasMeta*(path: string): TileAtlasMeta =
  ## The tiles an atlas's owl file lists; none when there is no file.
  readMeta(path, TileAtlasMeta)

proc readSpriteAtlasMeta*(path: string): SpriteAtlasMeta =
  ## The sprites an atlas's owl file lists; none when there is no file.
  readMeta(path, SpriteAtlasMeta)

proc writeTileAtlasMeta*(path: string; meta: TileAtlasMeta) =
  writeFile(path, writeText(meta))

proc writeSpriteAtlasMeta*(path: string; meta: SpriteAtlasMeta) =
  writeFile(path, writeText(meta))

# Images -----------------------------------------------------------------------

proc isTransparent*(image: RgbaImage): bool =
  ## Whether any pixel is less than fully opaque.
  if image.width <= 0 or image.height <= 0:
    return false
  for i in countup(3, image.pixels.high, 4):
    if image.pixels[i] < 255:
      return true
  false

proc toRgbaImage*(sprite: AsepriteFile; frame = 0): RgbaImage =
  ## One frame of an Aseprite file, its visible layers composited.
  result = RgbaImage(
    width: int(sprite.width),
    height: int(sprite.height),
    pixels: sprite.renderFrameRgba(frame)
  )
  if result.pixels.len != result.width * result.height * 4:
    raise newException(AtlasError, "invalid rendered Aseprite dimensions for '" & sprite.path & "'")

proc loadImageRgba*(path: string): RgbaImage =
  ## An image on disk as RGBA8: the first frame of an Aseprite file, or a
  ## PNG -- or anything else SDL_image reads.
  if path.splitFile.ext.toLowerAscii in [".aseprite", ".ase"]:
    return loadAseprite(path).toRgbaImage()
  let loaded = sdl3_image.load(path.cstring)
  if loaded.isNil:
    raise newException(AtlasError, "cannot read image '" & path & "': " & $sdl3.getError())
  let rgba = convertSurface(loaded, PIXELFORMAT_RGBA32)
  destroySurface(loaded)
  if rgba.isNil:
    raise newException(AtlasError, "cannot convert image '" & path & "': " & $sdl3.getError())
  defer: destroySurface(rgba)
  result = RgbaImage(width: rgba.w.int, height: rgba.h.int)
  if result.width <= 0 or result.height <= 0:
    raise newException(AtlasError, "image '" & path & "' is empty")
  result.pixels = newSeq[uint8](result.width * result.height * 4)
  for y in 0 ..< result.height:
    copyMem(addr result.pixels[y * result.width * 4],
            addr rgba.pixels[y * rgba.pitch.int], result.width * 4)

proc savePngRgba*(path: string; image: RgbaImage) =
  if image.width <= 0 or image.height <= 0:
    raise newException(AtlasError, "PNG dimensions must be positive for '" & path & "'")
  if image.pixels.len != image.width * image.height * 4:
    raise newException(AtlasError, "PNG pixels must be tightly packed RGBA8 for '" & path & "'")
  # SDL_image compresses; the snapshot writer, which needs no library, does not
  let surface = createSurfaceFrom(image.width.cint, image.height.cint,
    PIXELFORMAT_RGBA32, unsafeAddr image.pixels[0], (image.width * 4).cint)
  if surface.isNil:
    raise newException(AtlasError, "cannot write PNG '" & path & "': " & $sdl3.getError())
  defer: destroySurface(surface)
  if not sdl3_image.savePNG(surface, path.cstring):
    raise newException(AtlasError, "cannot write PNG '" & path & "': " & $sdl3.getError())

proc atlasSourcePaths*(dir: string): seq[string] =
  ## The images in `dir` an atlas is built from, in name order.
  for kind, filePath in walkDir(dir):
    if kind == pcFile and filePath.splitFile.ext.toLowerAscii in AtlasSourceExtensions:
      result.add(filePath)
  result.sort(system.cmp[string])

proc loadAtlasSources*(dir: string): seq[NamedImage] =
  ## Every source image in `dir`, named by its file name without the
  ## extension. Two files that would share a name are an error.
  if not dirExists(dir):
    raise newException(AtlasError, "atlas source directory does not exist: " & dir)
  var seen: Table[string, string]
  for path in atlasSourcePaths(dir):
    let name = path.splitFile.name
    if name in seen:
      raise newException(AtlasError, "atlas sources '" & seen[name] & "' and '" &
        path & "' share the name '" & name & "'")
    seen[name] = path
    result.add NamedImage(name: name, image: loadImageRgba(path))
  if result.len == 0:
    raise newException(AtlasError, "no atlas source images found in " & dir)

# Regions ----------------------------------------------------------------------

proc uvs*(info: SpriteInfo; atlasWidth, atlasHeight: int): AtlasUvs =
  ## Where the sprite sits in its atlas, in texture coordinates.
  if atlasWidth <= 0 or atlasHeight <= 0:
    raise newException(AtlasError, "atlas dimensions must be positive")
  AtlasUvs(
    u0: float32(info.x) / float32(atlasWidth),
    v0: float32(info.y) / float32(atlasHeight),
    u1: float32(info.x + info.w) / float32(atlasWidth),
    v1: float32(info.y + info.h) / float32(atlasHeight)
  )

proc uvs*(info: TileInfo; atlasWidth, atlasHeight: int): AtlasUvs =
  SpriteInfo(x: info.x, y: info.y, w: info.w, h: info.h).uvs(atlasWidth, atlasHeight)

proc uvs*(atlas: SpriteAtlas; info: SpriteInfo): AtlasUvs =
  info.uvs(atlas.image.width, atlas.image.height)

proc uvs*(atlas: TileAtlas; info: TileInfo): AtlasUvs =
  info.uvs(atlas.image.width, atlas.image.height)

# Packing ----------------------------------------------------------------------

proc tileCmp(a, b: TileInfo): int =
  if a.order == b.order:
    cmp(a.name, b.name)
  else:
    cmp(a.order, b.order)

proc blit(dst: var RgbaImage; src: RgbaImage; dstX, dstY: int) =
  if dstX < 0 or dstY < 0 or dstX + src.width > dst.width or dstY + src.height > dst.height:
    raise newException(AtlasError, "source image does not fit in atlas")
  let rowBytes = src.width * 4
  for y in 0 ..< src.height:
    let
      srcOffset = y * rowBytes
      dstOffset = ((dstY + y) * dst.width + dstX) * 4
    copyMem(addr dst.pixels[dstOffset], unsafeAddr src.pixels[srcOffset], rowBytes)

proc initAtlas(width, height: int): RgbaImage =
  if width <= 0 or height <= 0:
    raise newException(AtlasError, "atlas dimensions must be positive")
  RgbaImage(width: width, height: height, pixels: newSeq[uint8](width * height * 4))

proc nextPlacement(
  cursorX, cursorY, rowHeight: var int;
  atlasWidth, atlasHeight: int;
  width, height: int;
  name: string
): tuple[x, y: int] =
  if width <= 0 or height <= 0:
    raise newException(AtlasError, "invalid image dimensions for '" & name & "'")
  if width > atlasWidth or height > atlasHeight:
    raise newException(AtlasError, "image '" & name & "' is larger than the atlas")
  if cursorX > 0 and cursorX + width > atlasWidth:
    cursorX = 0
    cursorY += rowHeight
    rowHeight = 0
  if cursorY + height > atlasHeight:
    raise newException(AtlasError, "atlas overflow while placing '" & name & "'")

  result = (x: cursorX, y: cursorY)
  cursorX += width
  rowHeight = max(rowHeight, height)

proc priorTileOrders(metaPath: string): Table[string, int] =
  for tile in readTileAtlasMeta(metaPath).tiles:
    result[tile.name] = tile.order

proc packTileAtlas*(
  images: openArray[NamedImage];
  atlasWidth = 512;
  atlasHeight = 512;
  prior = initTable[string, int]()
): TileAtlas =
  ## Tiles in `prior`'s order (name order among equals and new tiles).
  result.image = initAtlas(atlasWidth, atlasHeight)
  var order = newSeq[int](images.len)
  for i, source in images:
    result.meta.tiles.add TileInfo(
      name: source.name,
      transparent: source.image.isTransparent(),
      order: prior.getOrDefault(source.name, 0),
      w: source.image.width,
      h: source.image.height
    )
    order[i] = i
  let tiles = result.meta.tiles
  order.sort(proc(a, b: int): int = tileCmp(tiles[a], tiles[b]))

  var cursorX, cursorY, rowHeight: int
  var placed: seq[TileInfo]
  for i in order:
    var tile = tiles[i]
    let placement = nextPlacement(cursorX, cursorY, rowHeight, atlasWidth, atlasHeight,
                                  tile.w, tile.h, tile.name)
    tile.x = placement.x
    tile.y = placement.y
    result.image.blit(images[i].image, tile.x, tile.y)
    placed.add tile
  result.meta.tiles = placed

proc packSpriteAtlas*(
  images: openArray[NamedImage];
  atlasWidth = 1280;
  atlasHeight = 1280
): SpriteAtlas =
  ## Sprites largest first (name order among equals).
  result.image = initAtlas(atlasWidth, atlasHeight)
  var order: seq[tuple[area: int, name: string, index: int]]
  for i, source in images:
    order.add (source.image.width * source.image.height, source.name, i)
  order.sort(proc(a, b: tuple[area: int, name: string, index: int]): int =
    if a.area == b.area: cmp(a.name, b.name) else: cmp(b.area, a.area)
  )

  var cursorX, cursorY, rowHeight: int
  for (_, _, i) in order:
    let source = images[i]
    let placement = nextPlacement(cursorX, cursorY, rowHeight, atlasWidth, atlasHeight,
                                  source.image.width, source.image.height, source.name)
    result.image.blit(source.image, placement.x, placement.y)
    result.meta.sprites.add SpriteInfo(
      name: source.name,
      transparent: source.image.isTransparent(),
      x: placement.x,
      y: placement.y,
      w: source.image.width,
      h: source.image.height
    )

proc generateTileAtlas*(
  sourceDir, outPath: string;
  atlasWidth = 512;
  atlasHeight = 512
) =
  ## Pack the images in `sourceDir` into `outPath` and its owl file, keeping
  ## the tile order that owl file already holds.
  let atlas = packTileAtlas(loadAtlasSources(sourceDir), atlasWidth, atlasHeight,
                            priorTileOrders(atlasMetaPath(outPath)))
  createDir(outPath.parentDir)
  savePngRgba(outPath, atlas.image)
  writeTileAtlasMeta(atlasMetaPath(outPath), atlas.meta)

proc generateSpriteAtlas*(
  sourceDir, outPath: string;
  atlasWidth = 1280;
  atlasHeight = 1280
) =
  ## Pack the images in `sourceDir` into `outPath` and its owl file.
  let atlas = packSpriteAtlas(loadAtlasSources(sourceDir), atlasWidth, atlasHeight)
  createDir(outPath.parentDir)
  savePngRgba(outPath, atlas.image)
  writeSpriteAtlasMeta(atlasMetaPath(outPath), atlas.meta)

# Reading atlases back ---------------------------------------------------------

proc loadSpriteAtlas*(path: string): SpriteAtlas =
  ## The atlas image at `path` and the sprites its owl file lists.
  SpriteAtlas(image: loadImageRgba(path), meta: readSpriteAtlasMeta(atlasMetaPath(path)))

proc loadTileAtlas*(path: string): TileAtlas =
  ## The atlas image at `path` and its tiles, in tile order.
  result = TileAtlas(image: loadImageRgba(path), meta: readTileAtlasMeta(atlasMetaPath(path)))
  result.meta.tiles.sort(tileCmp)

proc tileInformation*(metaPath: string): seq[TileInfo] =
  ## The tiles an owl file lists, in tile order.
  result = readTileAtlasMeta(metaPath).tiles
  result.sort(tileCmp)

proc meta*(id: int; metaPath: string): Option[TileInfo] =
  ## Tile `id` of an atlas, counted in tile order.
  let tiles = tileInformation(metaPath)
  if id < 0 or id >= tiles.len:
    return
  some(tiles[id])

proc spriteIndex*(meta: SpriteAtlasMeta; name: string): int =
  ## Where the sprite `name` is in `meta.sprites`; -1 when it is not there.
  for index, sprite in meta.sprites:
    if sprite.name == name:
      return index
  -1

proc readSpriteInfoTable*[T](metaPath: string): Table[T, SpriteInfo] =
  ## The sprites an owl file lists, keyed by name as `T`: a string, or a
  ## distinct string the game names its sprites with.
  for it in readSpriteAtlasMeta(metaPath).sprites:
    result[T(it.name)] = it

proc spriteMeta*[T](id: T; table: Table[T, SpriteInfo]): Option[SpriteInfo] =
  if not table.hasKey(id):
    return
  some(table[id])
