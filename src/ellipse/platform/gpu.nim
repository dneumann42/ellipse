import sdl3, errors

{.push cdecl, dynlib: LibName.}
proc acquireSwapchainTextureRaw(
  commandBuffer: GPUCommandBuffer,
  window: Window,
  swapchainTexture: var GPUTexture,
  width: var uint32,
  height: var uint32
): bool {.importc: "SDL_AcquireGPUSwapchainTexture".}
{.pop.}

type
  Device* = ref DeviceObj
  Texture* = ref TextureObj
  Shader* = ref ShaderObj
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

  ShaderObj* = object
    device: Device
    raw: GPUShader

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
    cull*: CullMode = NoCulling
    depthWrite*: bool = true

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

proc depthTarget*(device: Device, width, height: uint32): Texture =
  if width == 0 or height == 0:
    return nil
  if device.depth.isNil or device.depthWidth != width or device.depthHeight != height:
    if not device.depth.isNil:
      device.freeTextures.add device.depth
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
    device.depth = Texture(device: device, raw: raw, owned: true)
    device.depthWidth = width
    device.depthHeight = height
  device.depth

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
    input_rate: GPU_VERTEXINPUTRATE_VERTEX,
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
      src_color_blendfactor: GPU_BLENDFACTOR_SRC_ALPHA,
      dst_color_blendfactor: GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA,
      color_blend_op: GPU_BLENDOP_ADD,
      src_alpha_blendfactor: GPU_BLENDFACTOR_SRC_ALPHA,
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
  var info = GPUGraphicsPipelineCreateInfo(
    vertex_shader: cast[ptr GPUShader](desc.vertex.raw),
    fragment_shader: cast[ptr GPUShader](desc.fragment.raw),
    vertex_input_state: GPUVertexInputState(
      vertex_buffer_descriptions: cast[ptr UncheckedArray[GPUVertexBufferDescription]](addr bufferDescriptions[0]),
      num_vertex_buffers: 1,
      vertex_attributes: cast[ptr UncheckedArray[GPUVertexAttribute]](addr attributeDescriptions[0]),
      num_vertex_attributes: attributeDescriptions.len.uint32,
    ),
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

