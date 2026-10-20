## Water: open surfaces drawn over whatever lies under them, blended rather
## than painted. Every vertex says how fast the water moves there, how deep it
## is, and how broken: still lakes ripple in the wind, rivers carry their
## ripples downstream, and rapids and falls churn white. Depth sets the colour
## and how much of the bottom shows through, and fades the surface out where
## it runs onto the shore, so a mesh may spill past the waterline and leave
## the ground to hide the rest.

import ../platform/gpu
import geometry

type
  WaterVertex* = object
    position*: Vec3
    normal*: Vec3 ## the surface before any ripple: up on still water,
    ## tilted down a fall
    flow*: Vec2 ## metres a second the surface moves, across x and z
    depth*: float32 ## metres down to the bottom; zero or less on the shore
    foam*: float32 ## 0 smooth .. 1 white water

  WaterOptions* = object
    shallow*: Vec4 ## the colour water takes over a bottom close below
    deep*: Vec4 ## and over one too deep to see
    sky*: Vec4 ## what the surface reflects, looked at end on
    clarity*: float32 ## metres of water the bottom fades out over
    rippleMeters*: float32 ## world distance across one ripple
    rippleStrength*: float32 ## how far ripples tilt the surface
    time*: float32 ## seconds: what the ripples and foam move by

const
  WaterAttributes*: seq[Attribute] = @[
    Attribute(location: 0, offset: 0, format: Float3),
    Attribute(location: 1, offset: 12, format: Float3),
    Attribute(location: 2, offset: 24, format: Float4),
  ]
  WaterStride* = uint32 sizeof(WaterVertex)

func newWaterOptions*(shallow = vec4(0.16, 0.42, 0.45), deep = vec4(0.02, 0.09, 0.16),
                      sky = vec4(0.62, 0.74, 0.86), clarity = 3.0f,
                      rippleMeters = 2.5f, rippleStrength = 0.35f): WaterOptions =
  WaterOptions(shallow: shallow, deep: deep, sky: sky, clarity: clarity,
               rippleMeters: rippleMeters, rippleStrength: rippleStrength)
