import sdl3, errors

{.push cdecl, dynlib: LibName.}
proc acquireSwapchainTextureRaw(
  commandBuffer: GPUCommandBuffer,
  window: Window,
  swapchainTexture: var GPUTexture,
  width: var uint32,
  height: var uint32
): bool {.importc: "SDL_AcquireGPUSwapchainTexture".}
# The sdl3 binding declares GPUSampler as a value object; the handles are
# actually pointers, so they are handled as raw pointers here.
proc createGPUSamplerRaw(device: GPUDevice, createinfo: ptr GPUSamplerCreateInfo): pointer
  {.importc: "SDL_CreateGPUSampler".}
proc releaseGPUSamplerRaw(device: GPUDevice, sampler: pointer)
  {.importc: "SDL_ReleaseGPUSampler".}
{.pop.}

type
  Device* = ref DeviceObj
  Texture* = ref TextureObj
  Shader* = ref ShaderObj
  Sampler* = ref SamplerObj
  Pipeline* = ref PipelineObj
  CommandBuffer* = ref CommandBufferObj
  RenderPass* = ref RenderPassObj
  DynamicBuffer* = ref DynamicBufferObj

  BufferUsage* = enum
    VertexData, IndexData

  TextureObj* = object
    device: Device
    raw: GPUTexture
    owned*: bool

  DeviceObj* = object
    raw: GPUDevice
    fence: GPUFence
    depth: Texture
    depthWidth, depthHeight: uint32
    freeTextures: seq[Texture]
    freeBuffers: seq[GPUBuffer]
    pictureTransfer: GPUTransferBuffer ## one upload transfer, grown as
    pictureTransferSize: uint32        ## the UI pictures need it

  ShaderObj* = object
    device: Device
    raw: GPUShader

  SamplerObj* = object
    device: Device
    raw: pointer

  PipelineObj* = object
    device: Device
    raw: GPUGraphicsPipeline

  CommandBufferObj* = object
    device: Device
    raw: GPUCommandBuffer

  RenderPassObj* = object
    cmd: CommandBuffer
    raw: GPURenderPass

  DynamicBufferObj* = object
    device: Device
    raw: GPUBuffer
    transfer: GPUTransferBuffer
    capacity*: uint32
    usages: set[BufferUsage]

  TextureDownload* = ref object
    transfer: GPUTransferBuffer
    mapped: pointer
    width*, height*: uint32

  BufferBinding* = object
    buffer*: DynamicBuffer
    offset*: uint32

  ShaderStage* = enum
    VertexShader, FragmentShader

  TextureFormat* = distinct int32

  VertexFormat* = enum
    Float32, Float2, Float3, Float4

  Attribute* = object
    location*: uint32
    offset*: uint32
    format*: VertexFormat

  PrimitiveKind* = enum
    Triangles, TriangleStrip, LineList, LineStrip, Points

  CullMode* = enum
    NoCulling, CullFront, CullBack

  PipelineDesc* = object
    vertex*: Shader
    fragment*: Shader
    attributes*: seq[Attribute]
    stride*: uint32
    kind*: PrimitiveKind = Triangles
    colorFormat*: TextureFormat
    depthFormat*: TextureFormat
    hasDepth*: bool = true
    blend*: bool = false
    premultiplied*: bool = false ## blended sources carry their alpha already:
    ## `ONE` on the source side instead of `SRC_ALPHA` (see `newPipeline`)
    cull*: CullMode = NoCulling
    depthWrite*: bool = true
    instanced*: bool = false ## the attributes step once per instance, not
    ## per vertex: the vertex stage builds its corners from `gl_VertexIndex`

  ClearColor* = tuple[r, g, b, a: float32]

  GpuFrame* = ref object
    cmd*: CommandBuffer
    pass*: RenderPass
    target*: Texture
    depth*: Texture
    width*, height*: uint32
    valid*: bool

proc `=destroy`*(texture: var TextureObj) =
  if texture.owned and not texture.raw.isNil and not texture.device.isNil and not texture.device.raw.isNil:
    releaseGPUTexture(texture.device.raw, texture.raw)
    texture.raw = nil

proc `=destroy`*(shader: var ShaderObj) =
  if not shader.raw.isNil and not shader.device.isNil and not shader.device.raw.isNil:
    releaseGPUShader(shader.device.raw, shader.raw)
    shader.raw = nil

proc `=destroy`*(sampler: var SamplerObj) =
  if not sampler.raw.isNil and not sampler.device.isNil and not sampler.device.raw.isNil:
    releaseGPUSamplerRaw(sampler.device.raw, sampler.raw)
    sampler.raw = nil

proc `=destroy`*(pipeline: var PipelineObj) =
  if not pipeline.raw.isNil and not pipeline.device.isNil and not pipeline.device.raw.isNil:
    releaseGPUGraphicsPipeline(pipeline.device.raw, pipeline.raw)
    pipeline.raw = nil

proc `=destroy`*(buffer: var DynamicBufferObj) =
  if not buffer.device.isNil and not buffer.device.raw.isNil:
    if not buffer.transfer.isNil:
      releaseGPUTransferBuffer(buffer.device.raw, buffer.transfer)
      buffer.transfer = nil
    if not buffer.raw.isNil:
      releaseGPUBuffer(buffer.device.raw, buffer.raw)
      buffer.raw = nil

func `==`*(a, b: TextureFormat): bool =
  a.int32 == b.int32

const
  Depth32* = TextureFormat(ord(GPU_TEXTUREFORMAT_D32_FLOAT_S8_UINT).int32)
  Rgba8* = TextureFormat(ord(GPU_TEXTUREFORMAT_B8G8R8A8_UNORM).int32)
  R8G8B8A8* = TextureFormat(ord(GPU_TEXTUREFORMAT_R8G8B8A8_UNORM).int32)
    ## Bytes in red, green, blue, alpha order, as CPU-made images hold them.

proc swapchainFormat*(device: Device, window: Window): TextureFormat =
  TextureFormat(ord(getGPUSwapchainTextureFormat(device.raw, window)).int32)

func toSdl(f: VertexFormat): GPUVertexElementFormat =
  case f
  of Float32: GPU_VERTEXELEMENTFORMAT_FLOAT
  of Float2: GPU_VERTEXELEMENTFORMAT_FLOAT2
  of Float3: GPU_VERTEXELEMENTFORMAT_FLOAT3
  of Float4: GPU_VERTEXELEMENTFORMAT_FLOAT4

func toSdl(k: PrimitiveKind): GPUPrimitiveType =
  case k
  of Triangles: GPU_PRIMITIVETYPE_TRIANGLELIST
  of TriangleStrip: GPU_PRIMITIVETYPE_TRIANGLESTRIP
  of LineList: GPU_PRIMITIVETYPE_LINELIST
  of LineStrip: GPU_PRIMITIVETYPE_LINESTRIP
  of Points: GPU_PRIMITIVETYPE_POINTLIST

func toSdl(c: CullMode): GPUCullMode =
  case c
  of NoCulling: GPU_CULLMODE_NONE
  of CullFront: GPU_CULLMODE_FRONT
  of CullBack: GPU_CULLMODE_BACK

func bufferUsageFlags(u: set[BufferUsage]): uint32 =
  if VertexData in u:
    result = result or uint32(GPU_BUFFERUSAGE_VERTEX)
  if IndexData in u:
    result = result or uint32(GPU_BUFFERUSAGE_INDEX)

proc createRawBuffer(device: Device, capacity: uint32, usages: set[BufferUsage]): GPUBuffer =
  var info = GPUBufferCreateInfo(
    usage: bufferUsageFlags(usages),
    size: capacity,
  )
  result = createGPUBuffer(device.raw, addr info)
  if result.isNil:
    raiseSdlError("Failed to create buffer")

proc createTransferBuffer(device: Device, capacity: uint32): GPUTransferBuffer =
  var info = GPUTransferBufferCreateInfo(
    usage: GPU_TRANSFERBUFFERUSAGE_UPLOAD,
    size: capacity,
  )
  result = createGPUTransferBuffer(device.raw, addr info)
  if result.isNil:
    raiseSdlError("Failed to create transfer buffer")

proc collectGarbage(device: Device) =
  for texture in device.freeTextures:
    if texture.owned and not texture.raw.isNil:
      releaseGPUTexture(device.raw, texture.raw)
      texture.raw = nil
  device.freeTextures.setLen(0)
  for buffer in device.freeBuffers:
    if not buffer.isNil:
      releaseGPUBuffer(device.raw, buffer)
  device.freeBuffers.setLen(0)

proc initDevice*(renderer: Renderer): Device =
  let raw = getGPURendererDevice(renderer)
  if raw.isNil:
    raiseSdlError("Failed to acquire GPU device")
  Device(raw: raw)

proc acquireCommandBuffer*(device: Device): CommandBuffer =
  if not device.fence.isNil:
    checkSdl waitForGPUFences(device.raw, true, [device.fence]), "Failed to wait for GPU fence"
    releaseGPUFence(device.raw, device.fence)
    device.fence = nil
    collectGarbage(device)
  let raw = acquireGPUCommandBuffer(device.raw)
  if raw.isNil:
    raiseSdlError("Failed to acquire command buffer")
  CommandBuffer(device: device, raw: raw)

proc acquireSwapchain*(cmd: CommandBuffer, window: Window): tuple[texture: Texture, width, height: uint32] =
  var raw: GPUTexture
  var width, height: uint32
  checkSdl acquireSwapchainTextureRaw(cmd.raw, window, raw, width, height), "Failed to acquire swapchain texture"
  if raw.isNil:
    return (nil, 0'u32, 0'u32)
  (Texture(device: cmd.device, raw: raw, owned: false), width, height)

proc newDepthTexture*(device: Device, width, height: uint32): Texture =
  ## A depth target of its own, for a pass drawn at another size than the
  ## window's: `depthTarget` keeps only the one, sized to the frame.
  var info = GPUTextureCreateInfo(
    `type`: GPU_TEXTURETYPE_2D,
    format: GPU_TEXTUREFORMAT_D32_FLOAT_S8_UINT,
    usage: uint32(GPU_TEXTUREUSAGE_DEPTH_STENCIL_TARGET),
    width: width,
    height: height,
    layer_count_or_depth: 1,
    num_levels: 1,
    sample_count: GPU_SAMPLECOUNT_1,
  )
  let raw = createGPUTexture(device.raw, addr info)
  if raw.isNil:
    raiseSdlError("Failed to create depth texture")
  Texture(device: device, raw: raw, owned: true)

proc depthTarget*(device: Device, width, height: uint32): Texture =
  if width == 0 or height == 0:
    return nil
  if device.depth.isNil or device.depthWidth != width or device.depthHeight != height:
    if not device.depth.isNil:
      device.freeTextures.add device.depth
    device.depth = newDepthTexture(device, width, height)
    device.depthWidth = width
    device.depthHeight = height
  device.depth

proc retire*(device: Device, texture: Texture) =
  # Deferred release: the raw texture may still be referenced by in-flight
  # command buffers; collectGarbage frees it once the next fence has passed.
  device.freeTextures.add texture

proc newColorTexture*(device: Device, width, height: uint32, format: TextureFormat): Texture =
  var info = GPUTextureCreateInfo(
    `type`: GPU_TEXTURETYPE_2D,
    format: GPUTextureFormat(format.int32),
    usage: uint32(GPU_TEXTUREUSAGE_COLOR_TARGET) or uint32(GPU_TEXTUREUSAGE_SAMPLER),
    width: width,
    height: height,
    layer_count_or_depth: 1,
    num_levels: 1,
    sample_count: GPU_SAMPLECOUNT_1,
  )
  let raw = createGPUTexture(device.raw, addr info)
  if raw.isNil:
    raiseSdlError("Failed to create color texture")
  Texture(device: device, raw: raw, owned: true)

proc newPictureTexture*(device: Device, width, height: uint32, format: TextureFormat): Texture =
  ## A texture a CPU picture is uploaded into and sampled from: no color
  ## target usage, so the format only has to be sampleable (see
  ## `uploadPicture`).
  var info = GPUTextureCreateInfo(
    `type`: GPU_TEXTURETYPE_2D,
    format: GPUTextureFormat(format.int32),
    usage: uint32(GPU_TEXTUREUSAGE_SAMPLER),
    width: width,
    height: height,
    layer_count_or_depth: 1,
    num_levels: 1,
    sample_count: GPU_SAMPLECOUNT_1,
  )
  let raw = createGPUTexture(device.raw, addr info)
  if raw.isNil:
    raiseSdlError("Failed to create picture texture")
  Texture(device: device, raw: raw, owned: true)

proc pictureTransfer(device: Device, capacity: uint32): GPUTransferBuffer =
  if device.pictureTransfer.isNil or device.pictureTransferSize < capacity:
    if not device.pictureTransfer.isNil:
      releaseGPUTransferBuffer(device.raw, device.pictureTransfer)
    var info = GPUTransferBufferCreateInfo(
      usage: GPU_TRANSFERBUFFERUSAGE_UPLOAD,
      size: capacity,
    )
    device.pictureTransfer = createGPUTransferBuffer(device.raw, addr info)
    device.pictureTransferSize = capacity
    if device.pictureTransfer.isNil:
      raiseSdlError("Failed to create picture transfer buffer")
  device.pictureTransfer

proc uploadPicture*(cmd: CommandBuffer, texture: Texture, data: pointer,
                    width, height: uint32) =
  ## Copy `width` x `height` RGBA8 pixels from CPU memory into a picture
  ## texture: map, memcpy, `SDL_UploadToGPUTexture`, all recorded on `cmd`.
  let size = width * height * 4
  let transfer = pictureTransfer(cmd.device, size)
  let mapped = mapGPUTransferBuffer(cmd.device.raw, transfer, true)
  if mapped.isNil:
    raiseSdlError("Failed to map picture transfer buffer")
  copyMem(mapped, data, size.int)
  unmapGPUTransferBuffer(cmd.device.raw, transfer)
  var source = GPUTextureTransferInfo(
    transfer_buffer: cast[ptr GPUTransferBuffer](transfer),
    pixels_per_row: width,
    rows_per_layer: height,
  )
  var destination = GPUTextureRegion(
    texture: cast[ptr GPUTexture](texture.raw),
    w: width,
    h: height,
    d: 1,
  )
  let copyPass = beginGPUCopyPass(cmd.raw)
  uploadToGPUTexture(copyPass, addr source, addr destination, false)
  endGPUCopyPass(copyPass)

proc uploadPictureArea*(cmd: CommandBuffer, texture: Texture, data: pointer,
                        width: uint32, x0, y0, x1, y1: uint32) =
  ## `uploadPicture` for the columns `x0 ..< x1` and rows `y0 ..< y1` of a
  ## picture `width` pixels across: only those rows' spans are copied out
  ## and sent, the rest of the texture keeps what it held.
  if x1 <= x0 or y1 <= y0:
    return
  let
    w = x1 - x0
    h = y1 - y0
    span = w * 4
  let transfer = pictureTransfer(cmd.device, span * h)
  let mapped = mapGPUTransferBuffer(cmd.device.raw, transfer, true)
  if mapped.isNil:
    raiseSdlError("Failed to map picture transfer buffer")
  let
    src = cast[uint](data)
    dst = cast[uint](mapped)
  for row in 0'u32 ..< h:
    copyMem(cast[pointer](dst + uint(row * span)),
            cast[pointer](src + uint(((y0 + row) * width + x0) * 4)), span.int)
  unmapGPUTransferBuffer(cmd.device.raw, transfer)
  var source = GPUTextureTransferInfo(
    transfer_buffer: cast[ptr GPUTransferBuffer](transfer),
    pixels_per_row: w,
    rows_per_layer: h,
  )
  var destination = GPUTextureRegion(
    texture: cast[ptr GPUTexture](texture.raw),
    x: x0,
    y: y0,
    w: w,
    h: h,
    d: 1,
  )
  let copyPass = beginGPUCopyPass(cmd.raw)
  uploadToGPUTexture(copyPass, addr source, addr destination, false)
  endGPUCopyPass(copyPass)

proc newCubeTexture*(device: Device, size: uint32, format: TextureFormat): Texture =
  ## A cube map of six square faces `size` pixels across: the sky's box.
  ## Only the sampler ever reads it, so that is all it is made for.
  var info = GPUTextureCreateInfo(
    `type`: GPU_TEXTURETYPE_CUBE,
    format: GPUTextureFormat(format.int32),
    usage: uint32(GPU_TEXTUREUSAGE_SAMPLER),
    width: size,
    height: size,
    layer_count_or_depth: 6,
    num_levels: 1,
    sample_count: GPU_SAMPLECOUNT_1,
  )
  let raw = createGPUTexture(device.raw, addr info)
  if raw.isNil:
    raiseSdlError("Failed to create cube texture")
  Texture(device: device, raw: raw, owned: true)

proc uploadCubeFaces*(cmd: CommandBuffer, texture: Texture, data: pointer,
                     size: uint32) =
  ## Copy six RGBA8 faces, laid one after another in CPU memory -- +X, -X,
  ## +Y, -Y, +Z, -Z -- onto the faces of a cube texture. The first upload
  ## cycles the texture; the rest write into that cycle.
  let
    faceSize = size * size * 4
    total = faceSize * 6
    transfer = pictureTransfer(cmd.device, total)
    mapped = mapGPUTransferBuffer(cmd.device.raw, transfer, true)
  if mapped.isNil:
    raiseSdlError("Failed to map cube transfer buffer")
  copyMem(mapped, data, total.int)
  unmapGPUTransferBuffer(cmd.device.raw, transfer)
  let copyPass = beginGPUCopyPass(cmd.raw)
  for face in 0'u32 ..< 6:
    var source = GPUTextureTransferInfo(
      transfer_buffer: cast[ptr GPUTransferBuffer](transfer),
      offset: face * faceSize,
      pixels_per_row: size,
      rows_per_layer: size,
    )
    var destination = GPUTextureRegion(
      texture: cast[ptr GPUTexture](texture.raw),
      layer: face,
      w: size,
      h: size,
      d: 1,
    )
    uploadToGPUTexture(copyPass, addr source, addr destination, face == 0)
  endGPUCopyPass(copyPass)

proc newLayeredTexture*(device: Device, width, height, layers, levels: uint32,
                        format: TextureFormat): Texture =
  ## A 2D array texture of `layers` same-sized pictures, each with `levels`
  ## mip levels. It is a colour target too, so `generateMipmaps` can fill
  ## the levels below the uploaded one; each layer filters on its own, so
  ## no layer's edge ever bleeds into another's the way atlas cells do.
  var info = GPUTextureCreateInfo(
    `type`: GPU_TEXTURETYPE_2D_ARRAY,
    format: GPUTextureFormat(format.int32),
    usage: uint32(GPU_TEXTUREUSAGE_SAMPLER) or uint32(GPU_TEXTUREUSAGE_COLOR_TARGET),
    width: width,
    height: height,
    layer_count_or_depth: layers,
    num_levels: levels,
    sample_count: GPU_SAMPLECOUNT_1,
  )
  let raw = createGPUTexture(device.raw, addr info)
  if raw.isNil:
    raiseSdlError("Failed to create layered texture")
  Texture(device: device, raw: raw, owned: true)

proc uploadLayers*(cmd: CommandBuffer, texture: Texture, data: pointer,
                   width, height, layers: uint32) =
  ## Copy `layers` RGBA8 pictures of `width` x `height`, one after another in
  ## CPU memory, into the top mip level of a layered texture.
  let
    layerSize = width * height * 4
    size = layerSize * layers
    transfer = pictureTransfer(cmd.device, size)
    mapped = mapGPUTransferBuffer(cmd.device.raw, transfer, true)
  if mapped.isNil:
    raiseSdlError("Failed to map layer transfer buffer")
  copyMem(mapped, data, size.int)
  unmapGPUTransferBuffer(cmd.device.raw, transfer)
  let copyPass = beginGPUCopyPass(cmd.raw)
  for layer in 0'u32 ..< layers:
    var source = GPUTextureTransferInfo(
      transfer_buffer: cast[ptr GPUTransferBuffer](transfer),
      offset: layer * layerSize,
      pixels_per_row: width,
      rows_per_layer: height,
    )
    var destination = GPUTextureRegion(
      texture: cast[ptr GPUTexture](texture.raw),
      layer: layer,
      w: width,
      h: height,
      d: 1,
    )
    uploadToGPUTexture(copyPass, addr source, addr destination, false)
  endGPUCopyPass(copyPass)

proc generateMipmaps*(cmd: CommandBuffer, texture: Texture) =
  ## Fill every mip level below the top one by halving it, layer by layer.
  generateMipmapsForGPUTexture(cmd.raw, texture.raw)

proc newSampler*(device: Device, repeat = false, mipmaps = false,
                 anisotropy = 0.0f, nearest = false,
                 pixelated = false): Sampler =
  ## Linear filtering, clamped at the edges unless `repeat` tiles the
  ## texture; `mipmaps` blends between mip levels, and an `anisotropy`
  ## above 1 keeps surfaces seen at a grazing angle sharp. `nearest` keeps
  ## magnified texels square -- pixel art up close -- while minified ones
  ## still filter. `pixelated` filters nothing at all: every texel is
  ## square near and far, and with `mipmaps` the level is picked whole
  ## rather than blended -- the hard-edged look of a console without a
  ## texture filter.
  let address =
    if repeat: GPU_SAMPLERADDRESSMODE_REPEAT
    else: GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE
  let filtered = not pixelated
  var info = GPUSamplerCreateInfo(
    min_filter: if filtered: GPU_FILTER_LINEAR else: GPU_FILTER_NEAREST,
    mag_filter:
      if nearest or pixelated: GPU_FILTER_NEAREST else: GPU_FILTER_LINEAR,
    mipmap_mode:
      if mipmaps and filtered: GPU_SAMPLERMIPMAPMODE_LINEAR
      else: GPU_SAMPLERMIPMAPMODE_NEAREST,
    address_mode_u: address,
    address_mode_v: address,
    address_mode_w: address,
    max_anisotropy: anisotropy,
    max_lod: if mipmaps: 1000.0f else: 0.0f,
    enable_anisotropy: filtered and anisotropy > 1.0f,
  )
  let raw = createGPUSamplerRaw(device.raw, addr info)
  if raw.isNil:
    raiseSdlError("Failed to create sampler")
  Sampler(device: device, raw: raw)

proc beginRender*(cmd: CommandBuffer, target: Texture, clearColor: ClearColor, depth: Texture): RenderPass =
  var colorInfo = GPUColorTargetInfo(
    texture: cast[ptr GPUTexture](target.raw),
    clear_color: FColor(r: clearColor.r, g: clearColor.g, b: clearColor.b, a: clearColor.a),
    load_op: GPU_LOADOP_CLEAR,
    store_op: GPU_STOREOP_STORE,
  )
  var depthInfo = GPUDepthStencilTargetInfo(
    texture: cast[ptr GPUTexture](depth.raw),
    clear_depth: 1.0,
    load_op: GPU_LOADOP_CLEAR,
    store_op: GPU_STOREOP_DONT_CARE,
    stencil_load_op: GPU_LOADOP_DONT_CARE,
    stencil_store_op: GPU_STOREOP_DONT_CARE,
    cycle: true,
  )
  let raw = beginGPURenderPass(cmd.raw, addr colorInfo, 1, addr depthInfo)
  if raw.isNil:
    raiseSdlError("Failed to begin render pass")
  RenderPass(cmd: cmd, raw: raw)

proc beginRender*(cmd: CommandBuffer, target: Texture, clearColor: ClearColor): RenderPass =
  ## Pass without a depth attachment, for fullscreen post-process passes.
  var colorInfo = GPUColorTargetInfo(
    texture: cast[ptr GPUTexture](target.raw),
    clear_color: FColor(r: clearColor.r, g: clearColor.g, b: clearColor.b, a: clearColor.a),
    load_op: GPU_LOADOP_CLEAR,
    store_op: GPU_STOREOP_STORE,
  )
  let raw = beginGPURenderPass(cmd.raw, addr colorInfo, 1, nil)
  if raw.isNil:
    raiseSdlError("Failed to begin render pass")
  RenderPass(cmd: cmd, raw: raw)

proc beginOverlay*(cmd: CommandBuffer, target: Texture): RenderPass =
  ## A pass that draws on top of what `target` already shows: color LOAD,
  ## no clear, no depth -- the seam for a fullscreen UI overlay.
  var colorInfo = GPUColorTargetInfo(
    texture: cast[ptr GPUTexture](target.raw),
    load_op: GPU_LOADOP_LOAD,
    store_op: GPU_STOREOP_STORE,
  )
  let raw = beginGPURenderPass(cmd.raw, addr colorInfo, 1, nil)
  if raw.isNil:
    raiseSdlError("Failed to begin overlay pass")
  RenderPass(cmd: cmd, raw: raw)

proc endRender*(pass: RenderPass) =
  if not pass.raw.isNil:
    endGPURenderPass(pass.raw)
    pass.raw = nil

proc submit*(cmd: CommandBuffer) =
  cmd.device.fence = submitGPUCommandBufferAndAcquireFence(cmd.raw)
  if cmd.device.fence.isNil:
    raiseSdlError("Failed to submit command buffer")

proc newShader*(
  device: Device,
  spirv: openArray[byte],
  stage: ShaderStage,
  numUniformBuffers: uint32 = 0,
  numSamplers: uint32 = 0
): Shader =
  var info = GPUShaderCreateInfo(
    code_size: spirv.len.csize_t,
    code: cast[ptr UncheckedArray[uint8]](unsafeAddr spirv[0]),
    entrypoint: "main",
    format: uint32(GPU_SHADERFORMAT_SPIRV),
    stage: if stage == VertexShader: GPU_SHADERSTAGE_VERTEX else: GPU_SHADERSTAGE_FRAGMENT,
    num_samplers: numSamplers,
    num_uniform_buffers: numUniformBuffers,
  )
  let raw = createGPUShader(device.raw, addr info)
  if raw.isNil:
    raiseSdlError("Failed to create shader")
  Shader(device: device, raw: raw)

proc newPipeline*(device: Device, desc: PipelineDesc): Pipeline =
  var bufferDescriptions = [GPUVertexBufferDescription(
    slot: 0,
    pitch: desc.stride,
    input_rate:
      if desc.instanced: GPU_VERTEXINPUTRATE_INSTANCE
      else: GPU_VERTEXINPUTRATE_VERTEX,
    instance_step_rate: 0,
  )]
  var attributeDescriptions: seq[GPUVertexAttribute] = @[]
  for attribute in desc.attributes:
    attributeDescriptions.add GPUVertexAttribute(
      location: attribute.location,
      buffer_slot: 0,
      format: attribute.format.toSdl(),
      offset: attribute.offset,
    )
  var colorTarget = GPUColorTargetDescription(
    format: GPUTextureFormat(desc.colorFormat.int32),
    blend_state: GPUColorTargetBlendState(
      src_color_blendfactor:
        if desc.premultiplied: GPU_BLENDFACTOR_ONE
        else: GPU_BLENDFACTOR_SRC_ALPHA,
      dst_color_blendfactor: GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA,
      color_blend_op: GPU_BLENDOP_ADD,
      src_alpha_blendfactor:
        if desc.premultiplied: GPU_BLENDFACTOR_ONE
        else: GPU_BLENDFACTOR_SRC_ALPHA,
      dst_alpha_blendfactor: GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA,
      alpha_blend_op: GPU_BLENDOP_ADD,
      enable_blend: desc.blend,
    ),
  )
  var targetInfo = GPUGraphicsPipelineTargetInfo(
    color_target_descriptions: cast[ptr UncheckedArray[GPUColorTargetDescription]](addr colorTarget),
    num_color_targets: 1,
    depth_stencil_format: GPUTextureFormat(desc.depthFormat.int32),
    has_depth_stencil_target: desc.hasDepth,
  )
  var vertexInput = GPUVertexInputState(num_vertex_buffers: 0)
  if attributeDescriptions.len > 0:
    vertexInput = GPUVertexInputState(
      vertex_buffer_descriptions: cast[ptr UncheckedArray[GPUVertexBufferDescription]](addr bufferDescriptions[0]),
      num_vertex_buffers: 1,
      vertex_attributes: cast[ptr UncheckedArray[GPUVertexAttribute]](addr attributeDescriptions[0]),
      num_vertex_attributes: attributeDescriptions.len.uint32,
    )
  var info = GPUGraphicsPipelineCreateInfo(
    vertex_shader: cast[ptr GPUShader](desc.vertex.raw),
    fragment_shader: cast[ptr GPUShader](desc.fragment.raw),
    vertex_input_state: vertexInput,
    primitive_type: desc.kind.toSdl(),
    rasterizer_state: GPURasterizerState(
      fill_mode: GPU_FILLMODE_FILL,
      cull_mode: desc.cull.toSdl(),
      front_face: GPU_FRONTFACE_COUNTER_CLOCKWISE,
      enable_depth_clip: true,
    ),
    multisample_state: GPUMultisampleState(
      sample_count: GPU_SAMPLECOUNT_1,
    ),
    depth_stencil_state: GPUDepthStencilState(
      compare_op: GPU_COMPAREOP_LESS_OR_EQUAL,
      enable_depth_test: desc.hasDepth,
      enable_depth_write: desc.depthWrite,
    ),
    target_info: targetInfo,
  )
  let raw = createGPUGraphicsPipeline(device.raw, addr info)
  if raw.isNil:
    raiseSdlError("Failed to create graphics pipeline")
  Pipeline(device: device, raw: raw)

proc newDynamicBuffer*(device: Device, usages: set[BufferUsage], capacity: uint32): DynamicBuffer =
  DynamicBuffer(
    device: device,
    raw: createRawBuffer(device, capacity, usages),
    transfer: createTransferBuffer(device, capacity),
    capacity: capacity,
    usages: usages,
  )

proc grow(buffer: DynamicBuffer, size: uint32) =
  let capacity = max(size, max(buffer.capacity, 1024'u32) * 2)
  buffer.device.freeBuffers.add buffer.raw
  buffer.raw = createRawBuffer(buffer.device, capacity, buffer.usages)
  releaseGPUTransferBuffer(buffer.device.raw, buffer.transfer)
  buffer.transfer = createTransferBuffer(buffer.device, capacity)
  buffer.capacity = capacity

proc upload*(cmd: CommandBuffer, buffer: DynamicBuffer, data: pointer, size: uint32) =
  if size == 0:
    return
  if size > buffer.capacity:
    grow(buffer, size)
  let mapped = mapGPUTransferBuffer(cmd.device.raw, buffer.transfer, true)
  if mapped.isNil:
    raiseSdlError("Failed to map transfer buffer")
  copyMem(mapped, data, size)
  unmapGPUTransferBuffer(cmd.device.raw, buffer.transfer)
  var source = GPUTransferBufferLocation(
    transfer_buffer: cast[ptr GPUTransferBuffer](buffer.transfer),
    offset: 0,
  )
  var destination = GPUBufferRegion(
    buffer: cast[ptr GPUBuffer](buffer.raw),
    offset: 0,
    size: size,
  )
  let copyPass = beginGPUCopyPass(cmd.raw)
  uploadToGPUBuffer(copyPass, addr source, addr destination, true)
  endGPUCopyPass(copyPass)

proc upload*[T](cmd: CommandBuffer, buffer: DynamicBuffer, data: openArray[T]) =
  if data.len > 0:
    cmd.upload(buffer, unsafeAddr data[data.low], (data.len * sizeof(T)).uint32)

proc waitLastFence*(device: Device) =
  ## Block until the most recently submitted command buffer finishes,
  ## leaving the fence for the next acquireCommandBuffer to release.
  if not device.fence.isNil:
    discard waitForGPUFences(device.raw, true, [device.fence])

proc stageDownload*(cmd: CommandBuffer, texture: Texture, width, height: uint32): TextureDownload =
  ## Record a GPU->CPU copy of a whole texture into a mapped transfer buffer.
  ## The bytes are only readable once the command buffer has been submitted
  ## and its fence waited on; call finishDownload for that.
  let
    device = cmd.device
    size = width * height * 4
  var info = GPUTransferBufferCreateInfo(
    usage: GPU_TRANSFERBUFFERUSAGE_DOWNLOAD,
    size: size,
  )
  let transfer = createGPUTransferBuffer(device.raw, addr info)
  if transfer.isNil:
    raiseSdlError("Failed to create transfer buffer")
  let mapped = mapGPUTransferBuffer(device.raw, transfer, false)
  if mapped.isNil:
    releaseGPUTransferBuffer(device.raw, transfer)
    raiseSdlError("Failed to map transfer buffer")
  var source = GPUTextureRegion(
    texture: cast[ptr GPUTexture](texture.raw),
    w: width,
    h: height,
    d: 1,
  )
  var destination = GPUTextureTransferInfo(
    transfer_buffer: cast[ptr GPUTransferBuffer](transfer),
    pixels_per_row: width,
    rows_per_layer: height,
  )
  let copyPass = beginGPUCopyPass(cmd.raw)
  downloadFromGPUTexture(copyPass, addr source, addr destination)
  endGPUCopyPass(copyPass)
  TextureDownload(transfer: transfer, mapped: mapped, width: width, height: height)

proc finishDownload*(device: Device, download: TextureDownload): seq[uint8] =
  ## Copy out bytes staged by stageDownload; the owning command buffer must
  ## have been submitted and its fence waited on.
  result.setLen((download.width * download.height * 4).int)
  copyMem(addr result[0], download.mapped, result.len)
  unmapGPUTransferBuffer(device.raw, download.transfer)
  releaseGPUTransferBuffer(device.raw, download.transfer)

proc bindPipeline*(pass: RenderPass, pipeline: Pipeline) =
  bindGPUGraphicsPipeline(pass.raw, pipeline.raw)

proc bindVertexBuffers*(pass: RenderPass, bindings: openArray[BufferBinding]) =
  var sdlBindings: seq[sdl3.GPUBufferBinding] = @[]
  for binding in bindings:
    sdlBindings.add sdl3.GPUBufferBinding(
      buffer: cast[ptr GPUBuffer](binding.buffer.raw),
      offset: binding.offset,
    )
  bindGPUVertexBuffers(pass.raw, 0, addr sdlBindings[0], sdlBindings.len.uint32)

proc bindIndexBuffer*(pass: RenderPass, buffer: DynamicBuffer, offset: uint32 = 0) =
  var binding = sdl3.GPUBufferBinding(
    buffer: cast[ptr GPUBuffer](buffer.raw),
    offset: offset,
  )
  bindGPUIndexBuffer(pass.raw, addr binding, GPU_INDEXELEMENTSIZE_32BIT)

proc bindFragmentSamplers*(pass: RenderPass, bindings: openArray[tuple[texture: Texture, sampler: Sampler]]) =
  var sdlBindings: seq[sdl3.GPUTextureSamplerBinding] = @[]
  for (texture, sampler) in bindings:
    sdlBindings.add sdl3.GPUTextureSamplerBinding(
      texture: cast[ptr GPUTexture](texture.raw),
      sampler: cast[ptr GPUSampler](sampler.raw),
    )
  bindGPUFragmentSamplers(pass.raw, 0, addr sdlBindings[0], sdlBindings.len.uint32)

proc pushVertexUniforms*[T](cmd: CommandBuffer, slot: uint32, value: T) =
  pushGPUVertexUniformData(cmd.raw, slot, addr value, sizeof(T).uint32)

proc pushFragmentUniforms*[T](cmd: CommandBuffer, slot: uint32, value: T) =
  pushGPUFragmentUniformData(cmd.raw, slot, addr value, sizeof(T).uint32)

proc drawPrimitive*(pass: RenderPass, vertexCount: uint32, instanceCount: uint32 = 1, firstVertex: uint32 = 0) =
  drawGPUPrimitives(pass.raw, vertexCount, instanceCount, firstVertex, 0)

proc drawIndexed*(
  pass: RenderPass,
  indexCount: uint32,
  instanceCount: uint32 = 1,
  firstIndex: uint32 = 0,
  vertexOffset: int32 = 0
) =
  drawGPUIndexedPrimitives(pass.raw, indexCount, instanceCount, firstIndex, vertexOffset, 0)

proc beginFrame*(device: Device, window: Window): GpuFrame =
  result = GpuFrame(cmd: acquireCommandBuffer(device))
  let (texture, width, height) = acquireSwapchain(result.cmd, window)
  if not texture.isNil:
    result.target = texture
    result.depth = depthTarget(device, width, height)
    result.width = width
    result.height = height
    result.valid = true

proc beginRender*(frame: GpuFrame, clearColor: ClearColor) =
  frame.pass = beginRender(frame.cmd, frame.target, clearColor, frame.depth)

proc endFrame*(frame: GpuFrame) =
  if not frame.pass.isNil:
    frame.pass.endRender()
  frame.cmd.submit()

