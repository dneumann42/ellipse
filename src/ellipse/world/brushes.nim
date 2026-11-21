## Shared radial strokes for heightfields and splat weights.

import std/math
import ../drawing/[geometry, splatting]

type SplatWeights* = array[SplatLayers, uint8]

iterator brushSamples*(size: int, step: float32, origin, center: Vec3,
                       radius: float32): tuple[x, z: int, weight: float32] =
  ## A flat core with a smooth falloff over the outer half of the brush.
  let
    reach = max(radius.float64 / step.float64, 0.5)
    cx = (center.x.float64 - origin.x.float64) / step.float64
    cz = (center.z.float64 - origin.z.float64) / step.float64
    last = (size - 1).float64
  if radius > 0 and radius < Inf and abs(cx) < Inf and abs(cz) < Inf and
      cx + reach >= 0 and cz + reach >= 0 and cx - reach <= last and cz - reach <= last:
    for x in floor(max(0.0, cx - reach)).int .. ceil(min(last, cx + reach)).int:
      for z in floor(max(0.0, cz - reach)).int .. ceil(min(last, cz + reach)).int:
        let distance = sqrt(((x.float64 - cx) / reach)^2 + ((z.float64 - cz) / reach)^2)
        if distance < 1:
          let t = clamp(distance * 2 - 1, 0.0, 1.0)
          yield (x, z, (1 - t * t * (3 - 2 * t)).float32)

func blendSplat*(weights: var SplatWeights, layer: range[0 .. SplatLayers - 1],
                 share: float32) =
  ## Blend toward a layer. Assign rounding residual to the selected layer.
  if share > 0:
    var others = 0
    for i in 0 ..< SplatLayers:
      if i != layer:
        weights[i] = uint8(weights[i].float32 * (1 - min(share, 1f)))
        others += weights[i].int
    weights[layer] = uint8(max(0, 255 - others))
