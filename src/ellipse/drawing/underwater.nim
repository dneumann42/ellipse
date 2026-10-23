## Under the water: the scene drawn into an offscreen target, then laid
## onto the frame through one fullscreen pass that sways it, tints it the
## water's colour, and blurs and darkens it with the eye's depth. Distance
## haze stays with the fog: set it thick and water-coloured alongside.

import std/math

import ../platform/gpu
import geometry

type
  UnderwaterOptions* = object
    enabled*: bool ## whether the frame is seen from under the water
    depth*: float32 ## metres from the surface down to the eye
    shallow*: Vec3 ## the water just under the surface
    deep*: Vec3 ## and far down, where the light gives out
    clarity*: float32 ## metres of depth over which the light halves
    wobble*: float32 ## how far the picture sways: a fraction of the screen
    waves*: float32 ## sway waves across the screen
    speed*: float32 ## how fast they run
    blur*: float32 ## pixels the picture smears at full murk
    time*: float32 ## seconds: what the sway moves by

  UnderwaterUniforms = object
    shallow, deep, wobble, screen: Vec4

  UnderwaterPass* = ref object
    device: Device
    format: TextureFormat
    sampler: Sampler
    pipeline: Pipeline
    scene*: Texture ## the scene draws here while the eye is under
    width, height: uint32

const
  fullscreenVertSpv = staticRead("shaders/spv/fullscreen.vert.spv")
  underwaterFragSpv = staticRead("shaders/spv/underwater.frag.spv")

func newUnderwaterOptions*(depth = 0.0f, shallow = vec3(0.16, 0.42, 0.45),
                           deep = vec3(0.02, 0.09, 0.16), clarity = 8.0f,
                           wobble = 0.006f, waves = 1.5f, speed = 1.4f,
                           blur = 3.0f, time = 0.0f): UnderwaterOptions =
  UnderwaterOptions(enabled: true, depth: max(depth, 0.0f), shallow: shallow,
                    deep: deep, clarity: max(clarity, 0.01f), wobble: wobble,
                    waves: waves, speed: speed, blur: max(blur, 0.0f), time: time)

func clearness*(o: UnderwaterOptions): float32 =
  ## 1 just under the surface, halving every `clarity` metres down: what
  ## a game scales its underwater fog's reach by.
  pow(2.0f, -max(o.depth, 0.0f) / max(o.clarity, 0.01f))

proc newUnderwaterPass*(device: Device, format: TextureFormat): UnderwaterPass =
  let
    vertex = newShader(device, fullscreenVertSpv.toOpenArrayByte(0, fullscreenVertSpv.high), VertexShader)
    fragment = newShader(device, underwaterFragSpv.toOpenArrayByte(0, underwaterFragSpv.high), FragmentShader, numUniformBuffers = 1, numSamplers = 1)
  UnderwaterPass(
    device: device,
    format: format,
    sampler: newSampler(device),
    pipeline: newPipeline(device, PipelineDesc(
      vertex: vertex,
      fragment: fragment,
      colorFormat: format,
      hasDepth: false,
    )),
  )

proc ensureSize*(p: UnderwaterPass, width, height: uint32) =
  if width == 0 or height == 0 or (width == p.width and height == p.height):
    return
  if not p.scene.isNil:
    p.device.retire(p.scene)
  p.width = width
  p.height = height
  p.scene = newColorTexture(p.device, width, height, p.format)

proc run*(p: UnderwaterPass, cmd: CommandBuffer, target: Texture,
          options: UnderwaterOptions) =
  ## `scene` onto `target`, seen through the water.
  let o = options
  let pass = cmd.beginRender(target, (0.0f, 0.0f, 0.0f, 1.0f))
  pass.bindPipeline(p.pipeline)
  pass.bindFragmentSamplers([(texture: p.scene, sampler: p.sampler)])
  cmd.pushFragmentUniforms(0, UnderwaterUniforms(
    shallow: vec4(o.shallow, o.depth),
    deep: vec4(o.deep, o.clarity),
    wobble: vec4(o.wobble, o.waves, o.speed, o.time),
    screen: vec4(p.width.float32, p.height.float32, o.blur, 0.0f),
  ))
  pass.drawPrimitive(3)
  pass.endRender()
