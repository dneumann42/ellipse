## Separable, truncated-window box mean in linear time. Each OpenMP worker
## owns a row/column; double accumulators avoid drift in long rolling sums.
{.push gcsafe.}


{.localPassC: "-O3 -fno-math-errno".}
import ./parallel

proc boxMean*(samples: seq[float32], width, height, radius: int): seq[float32] =
  doAssert width >= 0 and height >= 0 and samples.len == width * height
  doAssert radius >= 0
  result = newSeq[float32](samples.len)
  if samples.len == 0: return
  var rows = newSeq[float32](samples.len)
  let source = buffer(samples)
  let horizontal = buffer(rows)
  let output = buffer(result)
  {.push checks: off.}
  for x in `||`(0, width - 1, balanced):
    let base = x * height
    var sum = 0.0
    for z in 0 .. min(height - 1, radius):
      sum += source[base + z].float
    for z in 0 ..< height:
      horizontal[base + z] = (sum / (min(height - 1, z + radius) - max(0, z - radius) + 1).float).float32
      if z >= radius: sum -= source[base + z - radius].float
      if z + radius + 1 < height: sum += source[base + z + radius + 1].float
  for z in `||`(0, height - 1, balanced):
    var sum = 0.0
    for x in 0 .. min(width - 1, radius):
      sum += horizontal[x * height + z].float
    for x in 0 ..< width:
      output[x * height + z] = (sum / (min(width - 1, x + radius) - max(0, x - radius) + 1).float).float32
      if x >= radius: sum -= horizontal[(x - radius) * height + z].float
      if x + radius + 1 < width: sum += horizontal[(x + radius + 1) * height + z].float
  {.pop.}
