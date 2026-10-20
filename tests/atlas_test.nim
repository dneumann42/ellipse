import std/[options, os, strutils, tables, unittest]
import ellipse/[aseprite, atlas, inflate]

# Aseprite files read straight into RGBA, and atlases packed from a folder of
# them with an owl file beside the picture naming where each image landed.

const
  fixtures = currentSourcePath.parentDir / "fixtures"
  grassPath = fixtures / "grass.aseprite"
  gravePath = fixtures / "grave.aseprite"
  dir = "build/atlas-test"

removeDir(dir)
createDir(dir)

proc hexBytes(text: string): seq[uint8] =
  for i in countup(0, text.high, 2):
    result.add uint8(parseHexInt(text[i .. i + 1]))

proc text(bytes: openArray[uint8]): string =
  for b in bytes:
    result.add char(b)

proc expectAsepriteError(path: string) =
  var raised = false
  try:
    discard loadAseprite(path)
  except AsepriteError:
    raised = true
  check raised

proc solid(width, height: int, alpha = 255'u8): RgbaImage =
  result = RgbaImage(width: width, height: height,
                     pixels: newSeq[uint8](width * height * 4))
  for i in countup(3, result.pixels.high, 4):
    result.pixels[i] = alpha

suite "inflate":
  const sample = "hello hello hello owl owl owl"

  test "fixed Huffman block":
    check inflateZlib(hexBytes("78dacb48cdc9c957c84022f3cb73601800a2d70ad3")).text == sample

  test "stored block":
    check inflateZlib(hexBytes("7801011d00e2ff68656c6c6f2068656c6c6f2068656c6c6f206f776c206f776c206f776ca2d70ad3")).text == sample

  test "rejects a bad checksum":
    expect InflateError:
      discard inflateZlib(hexBytes("78dacb48cdc9c957c84022f3cb73601800a2d70ad4"))

suite "aseprite":
  test "loads and renders a tile":
    let sprite = loadAseprite(grassPath)
    check sprite.width == 64
    check sprite.height == 64
    check sprite.colorDepth == acRgba
    check sprite.frames.len == 1
    check sprite.layers.len > 0
    check sprite.frames[0].cels.len > 0
    let pixels = sprite.renderFrameRgba(0)
    check pixels.len == 64 * 64 * 4
    var visible = false
    for i in countup(0, pixels.high, 4):
      if pixels[i + 3] != 0 and (pixels[i] != 0 or pixels[i + 1] != 0 or pixels[i + 2] != 0):
        visible = true
        break
    check visible

  test "rejects a bad file magic":
    var data = readFile(grassPath)
    data[4] = char(0)
    data[5] = char(0)
    writeFile(dir / "bad-magic.aseprite", data)
    expectAsepriteError(dir / "bad-magic.aseprite")

  test "rejects a truncated header":
    writeFile(dir / "truncated.aseprite", "\0\1\2\3")
    expectAsepriteError(dir / "truncated.aseprite")

  test "rejects a bad frame magic":
    var data = readFile(grassPath)
    data[132] = char(0)
    data[133] = char(0)
    writeFile(dir / "bad-frame.aseprite", data)
    expectAsepriteError(dir / "bad-frame.aseprite")

  test "rejects a corrupt cel":
    var data = readFile(grassPath)
    data[^8] = char(uint8(data[^8]) xor 0xFF)
    writeFile(dir / "bad-cel.aseprite", data)
    expectAsepriteError(dir / "bad-cel.aseprite")

suite "atlas":
  test "sprite atlas packs largest first and writes owl metadata":
    let source = dir / "sprites"
    createDir(source)
    copyFile(grassPath, source / "grass.aseprite")
    copyFile(gravePath, source / "grave.aseprite")
    let outPath = dir / "out" / "sprites.png"
    generateSpriteAtlas(source, outPath, 128, 128)
    check fileExists(outPath)
    check fileExists(atlasMetaPath(outPath))
    check atlasMetaPath(outPath).endsWith(".png.owl")
    check readFile(atlasMetaPath(outPath)).startsWith("; SpriteAtlasMeta -- owl settings")

    let loaded = loadSpriteAtlas(outPath)
    check loaded.image.width == 128
    check loaded.image.height == 128
    check loaded.meta.sprites.len == 2
    check loaded.meta.sprites[0].name == "grass"
    check loaded.meta.sprites[0].x == 0
    check loaded.meta.sprites[0].w == 64
    let grave = loaded.meta.sprites[loaded.meta.spriteIndex("grave")]
    check grave.x == 64
    check grave.transparent
    check loaded.meta.spriteIndex("missing") == -1

    # the packed pixels are the sprite's own
    let sprite = loadImageRgba(gravePath)
    for y in 0 ..< sprite.height:
      for x in 0 ..< sprite.width:
        let
          src = (y * sprite.width + x) * 4
          dst = ((grave.y + y) * loaded.image.width + grave.x + x) * 4
        check loaded.image.pixels[dst ..< dst + 4] == sprite.pixels[src ..< src + 4]

    let uv = loaded.uvs(grave)
    check uv.u0 == 0.5f
    check uv.v0 == 0.0f

    let table = readSpriteInfoTable[string](atlasMetaPath(outPath))
    check table.len == 2
    check spriteMeta("grave", table).isSome

  test "tile atlas keeps the order its owl file holds":
    let outPath = dir / "tiles.png"
    var images = @[NamedImage(name: "a", image: solid(8, 8)),
                   NamedImage(name: "b", image: solid(8, 8, 10))]
    var packed = packTileAtlas(images, 16, 16)
    check packed.meta.tiles[0].name == "a"
    check not packed.meta.tiles[0].transparent
    check packed.meta.tiles[1].transparent
    packed.meta.tiles[0].order = 1
    writeTileAtlasMeta(atlasMetaPath(outPath), packed.meta)

    let tiles = tileInformation(atlasMetaPath(outPath))
    check tiles[0].name == "b"
    check meta(1, atlasMetaPath(outPath)).get.name == "a"
    check meta(2, atlasMetaPath(outPath)).isNone

  test "overflow is an error":
    expect AtlasError:
      discard packSpriteAtlas([NamedImage(name: "big", image: solid(32, 32))], 16, 16)

  test "a missing owl file is an empty atlas":
    check readSpriteAtlasMeta(dir / "nothing.png.owl").sprites.len == 0
