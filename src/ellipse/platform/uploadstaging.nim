## Texture staging is sized to each upload, never the largest previous atlas.
const
  MaxPooledTextureUpload* = 4'u32 * 1024 * 1024
  TextureUploadBuckets* = 21 # 4 bytes through 4 MiB

type TextureUploadPlan* = object
  bucket*: int # -1 is an exact-sized transient allocation
  capacity*: uint32

func textureUploadPlan*(bytes: uint32): TextureUploadPlan =
  if bytes > MaxPooledTextureUpload:
    return TextureUploadPlan(bucket: -1,capacity: bytes)
  result.capacity = 4
  while result.capacity < bytes:
    result.capacity = result.capacity shl 1
    inc result.bucket
