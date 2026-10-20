## Minimal zlib/deflate reader (RFC 1950 and 1951), the counterpart of the
## writer in drawing/snapshot: enough to unpack the compressed cels and
## tilesets of an Aseprite file without a third-party dependency. Codes are
## decoded a bit at a time, the canonical way -- slow beside zlib, but the
## images it reads are sprite sheets read once at load or bake time.

type
  InflateError* = object of CatchableError

  Bits = object
    data: seq[uint8]
    at: int # in bits, least significant first within each byte

  Huffman = object
    counts: array[16, int] # codes of each length
    symbols: seq[int] # ordered by code

const
  LengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35,
                43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
  LengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3,
                 4, 4, 4, 4, 5, 5, 5, 5, 0]
  DistanceBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
                  257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145,
                  8193, 12289, 16385, 24577]
  DistanceExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8,
                   9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
  CodeLengthOrder = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2,
                     14, 1, 15]

proc fail(msg: string) {.noreturn.} =
  raise newException(InflateError, msg)

proc bit(r: var Bits): int =
  let index = r.at shr 3
  if index >= r.data.len:
    fail("compressed data ends early")
  result = int((r.data[index] shr (r.at and 7)) and 1)
  inc r.at

proc bits(r: var Bits, count: int): int =
  for i in 0 ..< count:
    result = result or (r.bit() shl i)

proc byteAt(r: var Bits): uint8 =
  ## The next whole byte; only valid once the reader is byte aligned.
  let index = r.at shr 3
  if index >= r.data.len:
    fail("compressed data ends early")
  result = r.data[index]
  inc r.at, 8

proc initHuffman(lengths: openArray[int]): Huffman =
  for length in lengths:
    inc result.counts[length]
  result.counts[0] = 0
  var offsets: array[16, int]
  for length in 1 ..< 15:
    offsets[length + 1] = offsets[length] + result.counts[length]
  result.symbols = newSeq[int](lengths.len)
  for symbol, length in lengths:
    if length != 0:
      result.symbols[offsets[length]] = symbol
      inc offsets[length]

proc decode(r: var Bits, h: Huffman): int =
  var code, first, index = 0
  for length in 1 .. 15:
    code = code or r.bit()
    let count = h.counts[length]
    if code - count < first:
      return h.symbols[index + code - first]
    index += count
    first = (first + count) shl 1
    code = code shl 1
  fail("invalid Huffman code")

proc inflateCodes(r: var Bits, output: var seq[uint8], lit, dist: Huffman) =
  while true:
    let symbol = r.decode(lit)
    if symbol < 256:
      output.add uint8(symbol)
    elif symbol == 256:
      return
    else:
      let li = symbol - 257
      if li >= LengthBase.len:
        fail("invalid length code " & $symbol)
      let length = LengthBase[li] + r.bits(LengthExtra[li])
      let di = r.decode(dist)
      if di >= DistanceBase.len:
        fail("invalid distance code " & $di)
      let distance = DistanceBase[di] + r.bits(DistanceExtra[di])
      if distance > output.len:
        fail("distance reaches before the start of the data")
      let start = output.len - distance
      for i in 0 ..< length:
        output.add output[start + i]

proc fixedTables(): (Huffman, Huffman) =
  var lengths: array[288, int]
  for i in 0 .. 143: lengths[i] = 8
  for i in 144 .. 255: lengths[i] = 9
  for i in 256 .. 279: lengths[i] = 7
  for i in 280 .. 287: lengths[i] = 8
  var distances: array[30, int]
  for i in 0 ..< distances.len: distances[i] = 5
  (initHuffman(lengths), initHuffman(distances))

proc dynamicTables(r: var Bits): (Huffman, Huffman) =
  let
    literals = r.bits(5) + 257
    distances = r.bits(5) + 1
    codeLengths = r.bits(4) + 4
  if literals > 286 or distances > 30:
    fail("too many codes in a dynamic block")
  var lengthLengths: array[19, int]
  for i in 0 ..< codeLengths:
    lengthLengths[CodeLengthOrder[i]] = r.bits(3)
  let lengthCode = initHuffman(lengthLengths)
  var lengths = newSeq[int](literals + distances)
  var i = 0
  while i < lengths.len:
    let symbol = r.decode(lengthCode)
    if symbol < 16:
      lengths[i] = symbol
      inc i
      continue
    var
      value = 0
      repeat = 0
    case symbol
    of 16:
      if i == 0:
        fail("a repeat with no length before it")
      value = lengths[i - 1]
      repeat = 3 + r.bits(2)
    of 17:
      repeat = 3 + r.bits(3)
    else:
      repeat = 11 + r.bits(7)
    if i + repeat > lengths.len:
      fail("code lengths overrun the table")
    for _ in 0 ..< repeat:
      lengths[i] = value
      inc i
  if lengths[256] == 0:
    fail("a dynamic block with no end code")
  (initHuffman(lengths.toOpenArray(0, literals - 1)),
   initHuffman(lengths.toOpenArray(literals, lengths.high)))

proc inflateRaw(r: var Bits, sizeHint: int): seq[uint8] =
  result = newSeqOfCap[uint8](sizeHint)
  while true:
    let last = r.bit() == 1
    case r.bits(2)
    of 0:
      r.at = (r.at + 7) and not 7
      let
        length = int(r.byteAt()) or (int(r.byteAt()) shl 8)
        inverse = int(r.byteAt()) or (int(r.byteAt()) shl 8)
      if (length xor 0xFFFF) != inverse:
        fail("stored block length does not match its complement")
      for _ in 0 ..< length:
        result.add r.byteAt()
    of 1:
      let (lit, dist) = fixedTables()
      r.inflateCodes(result, lit, dist)
    of 2:
      let (lit, dist) = r.dynamicTables()
      r.inflateCodes(result, lit, dist)
    else:
      fail("invalid block type")
    if last:
      break

func adler32(data: openArray[uint8]): uint32 =
  var
    low = 1'u32
    high = 0'u32
  for value in data:
    low = (low + value.uint32) mod 65521
    high = (high + low) mod 65521
  (high shl 16) or low

proc inflateZlib*(data: openArray[uint8], sizeHint = 0): seq[uint8] =
  ## The bytes a zlib stream holds. `sizeHint` reserves room for them up
  ## front. Raises `InflateError` on a malformed stream or a bad checksum.
  if data.len < 6:
    fail("zlib stream is too short")
  let
    cmf = int(data[0])
    flg = int(data[1])
  if (cmf and 0x0F) != 8:
    fail("zlib stream is not deflate compressed")
  if (cmf * 256 + flg) mod 31 != 0:
    fail("zlib header check failed")
  if (flg and 0x20) != 0:
    fail("zlib preset dictionaries are not supported")
  var r = Bits(data: @data, at: 16)
  result = r.inflateRaw(sizeHint)
  let tail = (r.at + 7) shr 3
  if tail + 4 > data.len:
    fail("zlib stream is missing its checksum")
  let expected =
    (uint32(data[tail]) shl 24) or (uint32(data[tail + 1]) shl 16) or
    (uint32(data[tail + 2]) shl 8) or uint32(data[tail + 3])
  if adler32(result) != expected:
    fail("zlib checksum mismatch")
