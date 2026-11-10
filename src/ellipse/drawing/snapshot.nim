## Minimal PNG writer for snapshots: emits RGBA rows through uncompressed
## deflate blocks, so the format needs no third-party dependencies.

const
  PngSignature = [byte 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
  ZlibHeader = [byte 0x78, 0x01]

proc appendByte(data: var seq[byte], value: byte) =
  data.add value

proc appendU16(data: var seq[byte], value: uint16) =
  data.add (value and 0x00FF).byte
  data.add (value shr 8).byte

proc appendU32(data: var seq[byte], value: uint32) =
  data.add (value and 0x000000FF).byte
  data.add ((value shr 8) and 0x000000FF).byte
  data.add ((value shr 16) and 0x000000FF).byte
  data.add (value shr 24).byte

proc appendU32be(data: var seq[byte], value: uint32) =
  data.add (value shr 24).byte
  data.add ((value shr 16) and 0x000000FF).byte
  data.add ((value shr 8) and 0x000000FF).byte
  data.add (value and 0x000000FF).byte

func crc32(data: openArray[byte]): uint32 =
  var crc = 0xFFFF_FFFF'u32
  for value in data:
    crc = crc xor value.uint32
    for bit in 0 ..< 8:
      crc = (if (crc and 1) != 0: (crc shr 1) xor 0xEDB8_8320'u32 else: crc shr 1)
  not crc

func adler32(data: openArray[byte]): uint32 =
  var
    low = 1'u32
    high = 0'u32
  for value in data:
    low = (low + value.uint32) mod 65521
    high = (high + low) mod 65521
  (high shl 16) or low

proc appendChunk(data: var seq[byte], kind: string, body: openArray[byte]) =
  appendU32be data, body.len.uint32
  var marker = newSeq[byte]()
  for ch in kind:
    marker.add ch.byte
  data.add marker
  data.add body
  var joined = marker
  joined.add body
  appendU32be data, crc32(joined)

proc encodePng*(
  width, height: int,
  pixels: openArray[byte],
  bgra: bool = false,
): seq[byte] =
  ## Encode `width` x `height` 8-bit RGBA pixels (row 0 = top) as PNG bytes.
  ## Pass `bgra: true` when the source rows are ordered blue-first, as the
  ## common swapchain formats are. Returns an empty seq on invalid dimensions
  ## so callers writing files or streams can check one return value.
  if width <= 0 or height <= 0 or pixels.len < width * height * 4:
    return @[]
  var png = @PngSignature

  var header = newSeq[byte]()
  appendU32be header, width.uint32
  appendU32be header, height.uint32
  appendByte header, 8 # bit depth
  appendByte header, 6 # RGBA
  appendByte header, 0 # deflate
  appendByte header, 0 # adaptive filtering
  appendByte header, 0 # no interlace
  png.appendChunk("IHDR", header)

  var raw = newSeq[byte](height * (width * 4 + 1))
  var at = 0
  for row in 0 ..< height:
    raw[at] = 0 # filter: none
    inc at
    for column in 0 ..< width:
      let i = row * width * 4 + column * 4
      if bgra:
        raw[at] = pixels[i + 2]
        raw[at + 1] = pixels[i + 1]
        raw[at + 2] = pixels[i]
        raw[at + 3] = pixels[i + 3]
      else:
        raw[at] = pixels[i]
        raw[at + 1] = pixels[i + 1]
        raw[at + 2] = pixels[i + 2]
        raw[at + 3] = pixels[i + 3]
      inc at, 4

  var body = @ZlibHeader
  var start = 0
  while true:
    let
      run = min(raw.len - start, 0xFFFF)
      last = raw.len - start <= 0xFFFF
    appendByte body, (if last: 1.byte else: 0.byte) # stored, BFINAL
    appendU16 body, run.uint16
    appendU16 body, (not run.uint16)
    body.add raw.toOpenArray(start, start + run - 1)
    if last:
      break
    inc start, run
  var checksum = newSeq[byte]()
  appendU32be checksum, adler32(raw)
  body.add checksum
  png.appendChunk("IDAT", body)

  png.appendChunk("IEND", [])
  return png

proc writePng*(
  path: string,
  width, height: int,
  pixels: openArray[byte],
  bgra: bool = false,
): bool =
  ## Save `width` x `height` 8-bit RGBA pixels (row 0 = top) as a PNG file.
  ## Pass `bgra: true` when the source rows are ordered blue-first, as the
  ## common swapchain formats are. Returns false on invalid dimensions.
  let png = encodePng(width, height, pixels, bgra)
  if png.len == 0:
    return false
  writeFile(path, png)
  return true
