## Water: open surfaces drawn over whatever lies under them, blended rather
## than painted. Every vertex says how fast the water moves there, how deep it
## is, and how broken: still lakes ripple in the wind, rivers carry their
## ripples downstream, and rapids and falls churn white. Depth sets the colour
## and how much of the bottom shows through, and fades the surface out where
## it runs onto the shore, so a mesh may spill past the waterline and leave
## the ground to hide the rest. Water marked as surf heaves in waves that
## run in toward its shore, break into foam, and wash up the beach and back:
## each vertex says how far it lies from that shore, and the crests ride
## those distances, so they come in parallel to the beach.

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
    surf*: float32 ## 0 sheltered .. 1 open sea, where waves break on the shore
    shore*: float32 ## metres out from the shore the surf runs onto

  WaterGround* = object
    ## The ground under the water: a square of `size` by `size` heights,
    ## `step` metres apart, the first at (`x`, `z`), running along x first,
    ## then z. The water measures its depth against it pixel by pixel, so it
    ## thins out where the bank really rises through the surface, not where
    ## the depths at a triangle's corners would put it. Water outside the
    ## square takes the depth its vertices carry.
    x*, z*, step*: float32
    size*: int
    heights*: seq[float32]

  WaterOptions* = object
    shallow*: Vec4 ## the colour water takes over a bottom close below
    deep*: Vec4 ## and over one too deep to see
    sky*: Vec4 ## what the surface reflects, looked at end on
    clarity*: float32 ## metres of water the bottom fades out over
    rippleMeters*: float32 ## world distance across one ripple
    rippleStrength*: float32 ## how far ripples tilt the surface
    surfHeight*: float32 ## metres a wave lifts the water at the shore
    surfPeriod*: float32 ## seconds between waves
    surfReach*: float32 ## metres out from the shore where waves start to rise
    surfSpacing*: float32 ## metres from one crest to the next
    time*: float32 ## seconds: what the ripples and foam move by

const
  WaterAttributes*: seq[Attribute] = @[
    Attribute(location: 0, offset: 0, format: Float3),
    Attribute(location: 1, offset: 12, format: Float3),
    Attribute(location: 2, offset: 24, format: Float4),
    Attribute(location: 3, offset: 40, format: Float32),
    Attribute(location: 4, offset: 44, format: Float32),
  ]
  WaterStride* = uint32 sizeof(WaterVertex)

func newWaterOptions*(shallow = vec4(0.16, 0.42, 0.45), deep = vec4(0.02, 0.09, 0.16),
                      sky = vec4(0.62, 0.74, 0.86), clarity = 3.0f,
                      rippleMeters = 2.5f, rippleStrength = 0.35f,
                      surfHeight = 0.3f, surfPeriod = 7.0f,
                      surfReach = 24.0f, surfSpacing = 9.0f): WaterOptions =
  WaterOptions(shallow: shallow, deep: deep, sky: sky, clarity: clarity,
               rippleMeters: rippleMeters, rippleStrength: rippleStrength,
               surfHeight: surfHeight, surfPeriod: surfPeriod, surfReach: surfReach,
               surfSpacing: surfSpacing)
