## The sky behind everything: a box of six painted faces -- a skybox -- or,
## where there is no picture to show, a gradient from a warm horizon up to
## the zenith and down to the ground. The sky is one fullscreen triangle
## drawn before the scene: every fragment un-projects its screen position
## through the camera's rotation into a world direction, so the dome turns
## with the eye, sits at infinite distance, and never touches the depth
## buffer the scene fights over.

import sdl3, sdl3_image

import ../platform/gpu
import geometry

type
  SkyboxImage* = ref object
    ## A sky painted as a 4x3 cross: six square faces of `faceSize` pixels,
    ## the middle row wrapping around the eye, the top and bottom faces
    ## tipped up and down from the centre -- the layout the skyboxes were
    ## drawn in, row 0 at the picture's top.
    width*, height*, faceSize*: int
    pixels*: seq[uint8]

  CloudOptions* = object
    ## Optional procedural cloud deck in the existing fullscreen sky pass.
    ## Disabled by default; no extra meshes, textures, or depth writes.
    enabled*: bool
    seconds*, coverage*, daylight*: float32
    sunDirection*: Vec3

  SkyOptions* = object
    ## What a frame's sky is made of. The colours are the gradient the sky
    ## falls back to when no skybox shows; `exposure` brightens whichever
    ## the frame draws.
    clouds*: CloudOptions
    enabled*: bool ## whether a frame draws any sky at all
    horizonColor*, zenithColor*, groundColor*: Vec3
    exposure*: float32
    skybox*: SkyboxImage
    useSkybox*: bool ## the picture is wanted and there is one
    skyboxStrength*: float32 ## 0..1: picture shown vs gradient beneath

  SkyboxState* = object
    ## The artist's GPU side of a skybox: the cube texture built from the
    ## source picture, kept until a different picture is asked for.
    source*: SkyboxImage
    texture*: gpu.Texture
    size*: uint32

  SkyUniforms* = object
    ## The block both sky stages push: packed here, opaque out.
    cameraRotation: Mat4
    viewportScale, horizonExposure, zenithUseSkybox, groundColor: Vec4
    cloudWeather, cloudSun: Vec4

const
  CrossColumns = 4
  CrossRows = 3
  FaceCells = [ # which cross cell holds each cube face, in GL order
    (2, 1), # +X: the right hand's horizon
    (0, 1), # -X: the left hand's
    (1, 0), # +Y: the top face, straight up
    (1, 2), # -Y: and the bottom, straight down
    (3, 1), # +Z: behind the eye -- the cross's far end
    (1, 1), # -Z: what the camera looks at -- the cross's centre
  ]

func newSkyOptions*(horizonColor = vec3(1.0f, 0.44f, 0.62f),
                    zenithColor = vec3(0.42f, 0.56f, 0.66f),
                    groundColor = vec3(0.45f, 0.5f, 0.48f),
                    exposure = 1.0f, skybox: SkyboxImage = nil): SkyOptions =
  ## An enabled sky: `skybox` where there is one, the gradient where there
  ## is not. The defaults are the old engine's dusk: a pink horizon under a
  ## grey-blue zenith.
  result = SkyOptions(
    enabled: true,
    horizonColor: horizonColor,
    zenithColor: zenithColor,
    groundColor: groundColor,
    exposure: max(exposure, 0.0f),
    skybox: skybox,
    useSkybox: not skybox.isNil,
    skyboxStrength: 1.0f,
  )

proc readSkybox*(path: string): SkyboxImage =
  ## The cross image on disk (PNG or anything else SDL_image reads), its
  ## faces square and the grid exact. Returns nil when the file cannot be
  ## read or is not a 4x3 cross of square faces.
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
    face = min(width div CrossColumns, height div CrossRows)
  if face <= 0 or face * CrossColumns != width or face * CrossRows != height:
    destroySurface(rgba)
    return
  result = SkyboxImage(
    width: width, height: height, faceSize: face,
    pixels: newSeq[uint8](width * height * 4),
  )
  for y in 0 ..< height:
    copyMem(addr result.pixels[y * width * 4],
            addr rgba.pixels[y * rgba.pitch.int], width * 4)
  destroySurface(rgba)

func faces*(image: SkyboxImage): seq[uint8] =
  ## The cube's six faces one after another -- +X, -X, +Y, -Y, +Z, -Z --
  ## each a `faceSize` square of RGBA8: the layout a cube texture is
  ## uploaded from.
  ##
  ## The cross was painted for the old engine, whose sky rays ran forward
  ## along +z; this renderer runs them back along -z, the right-handed way
  ## the cube sampler expects. The same picture read through the flipped
  ## axis lands mirrored -- sideways on the four faces ringing the horizon,
  ## and tipped over on the lid and the floor -- so the extraction mirrors
  ## each face back: rows reversed on the sides, row order reversed on top
  ## and bottom. Every seam then meets the edge it was painted against, and
  ## the sun stays on the hand it rose on.
  let side = image.faceSize
  result = newSeq[uint8](side * side * 4 * 6)
  for face, cell in FaceCells:
    let
      (column, row) = cell
      topLeft = ((row * side) * image.width + column * side) * 4
      tipped = face in 2 .. 3 # +Y and -Y: the lid and the floor
    for y in 0 ..< side:
      let
        srcRow = if tipped: side - 1 - y else: y
        at = (face * side + y) * side * 4
      for x in 0 ..< side:
        let srcCol = if tipped: x else: side - 1 - x
        copyMem(addr result[at + x * 4],
                unsafeAddr image.pixels[topLeft +
                  (srcRow * image.width + srcCol) * 4], 4)

func cameraRotation*(view: Mat4): Mat4 =
  ## The rotation a view matrix undoes, turned back around: camera space
  ## into world. A look-at view's rotation is orthonormal, so its inverse
  ## is its transpose -- all the sky needs to aim its rays.
  for col in 0 ..< 3:
    for row in 0 ..< 3:
      result.c[col * 4 + row] = view.c[row * 4 + col]
  result.c[15] = 1.0f

func skyUniforms*(options: SkyOptions, view: Mat4, viewportScale: Vec4,
                  hasTexture: bool): SkyUniforms =
  ## `viewportScale` is the tangent of the projection's half-angles, x
  ## widened by the aspect: it turns a fullscreen triangle's clip position
  ## into a camera-space ray.
  result = SkyUniforms(
    cameraRotation: cameraRotation(view),
    viewportScale: viewportScale,
    horizonExposure: vec4(options.horizonColor, max(options.exposure, 0.0f)),
    zenithUseSkybox: vec4(options.zenithColor,
      if options.useSkybox and hasTexture:
        clamp(options.skyboxStrength, 0.0f, 1.0f) else: 0.0f),
    groundColor: vec4(options.groundColor, 0.0f),
    cloudWeather: vec4(options.clouds.seconds, clamp(options.clouds.coverage, 0f, 1f),
      clamp(options.clouds.daylight, 0f, 1f), if options.clouds.enabled: 1f else: 0f),
    cloudSun: vec4(options.clouds.sunDirection, 0f),
  )
