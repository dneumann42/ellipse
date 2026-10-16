#version 450

layout(location = 0) out vec4 outColor;

layout(set = 3, binding = 0) uniform Depth {
  vec4 uNearFar; // x = near, y = far
};

vec4 packDepth(float value) {
  const vec4 shifts = vec4(16777216.0, 65536.0, 256.0, 1.0);
  const vec4 masks = vec4(0.0, 1.0 / 256.0, 1.0 / 256.0, 1.0 / 256.0);
  vec4 packed = fract(clamp(value, 0.0, 0.999999) * shifts);
  packed -= packed.xxyz * masks;
  return packed;
}

void main() {
  // Store linear view depth (normalized by far) in a filterable colour target.
  float z = gl_FragCoord.z;
  float near = uNearFar.x;
  float far = uNearFar.y;
  float linear = (near * far) / max(far - z * (far - near), 0.0001);
  outColor = packDepth(linear / far);
}
