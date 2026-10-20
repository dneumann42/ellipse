## Distance fog: the world sinks into a haze that thickens with reach and
## ends at a limit, past which nothing draws and the sky shows through.
## Every scene shader carries the same four vectors, packed here from
## `FogOptions`; fog off is density 0 and a limit nothing ever reaches.

import geometry

type
  FogOptions* = object
    nearColor*: Vec3 ## the haze at the edge of sight
    farColor*: Vec3 ## and far in, where the world gives out: match it to
    ## the sky's horizon and the haze line vanishes into the sky
    density*: float32 ## how fast the haze thickens, per metre
    falloff*: float32 ## how the thickness curves up with distance
    limit*: float32 ## metres past which the world stops

  FogUniforms* = object
    ## The block every scene fragment stage pushes: packed here, opaque
    ## out. Four vectors, so it rides at the tail of any pass's own block.
    eye, near, far, limit: Vec4

const
  FarLimit* = 1.0e18f ## a limit past any frustum: fog that never ends

func newFogOptions*(nearColor = vec3(0.72f, 0.8f, 0.86f),
                    farColor = vec3(0.42f, 0.56f, 0.66f),
                    density = 0.0f, falloff = 1.2f,
                    limit = FarLimit): FogOptions =
  ## Fog off unless asked for: `density` 0 keeps the world clear and the
  ## default `limit` lies past anything the eye can reach.
  result = FogOptions(
    nearColor: nearColor,
    farColor: farColor,
    density: max(density, 0.0f),
    falloff: max(falloff, 0.001f),
    limit: max(limit, 0.001f),
  )

func fogEnabled*(fog: FogOptions): bool =
  fog.density > 0.0f

func fogUniforms*(fog: FogOptions, eye: Vec3): FogUniforms =
  result = FogUniforms(
    eye: vec4(eye, 0.0f),
    near: vec4(fog.nearColor, fog.density),
    far: vec4(fog.farColor, fog.falloff),
    limit: vec4(fog.limit, 0.0f, 0.0f, 0.0f),
  )

func depthFogFade*(fog: FogOptions): float32 =
  ## Metres past which the depth pass drops geometry: where the scene
  ## shaders start fading their alpha out, so nothing fully hazed keeps
  ## occluding ambient light it can no longer be seen through.
  fog.limit * 0.82f
