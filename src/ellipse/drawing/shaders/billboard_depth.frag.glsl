#version 450

// A billboard into the occlusion pass's packed linear depth: cut out exactly
// as the colour pass cuts it, so the shade it casts matches its outline.

layout(location = 0) in vec2 fragmentUv;
layout(location = 1) in float fragmentLayer;

layout(location = 0) out vec4 outColor;

layout(set = 2, binding = 0) uniform sampler2DArray uSprites;

layout(set = 3, binding = 0) uniform Depth {
  vec4 uNearFar; // x = near, y = far
  vec4 uFogFade; // x: metres past which geometry stops occluding
  vec4 uCut;     // x: opacity under which a texel is cut away
};

vec4 packDepth(float value) {
  const vec4 shifts = vec4(16777216.0, 65536.0, 256.0, 1.0);
  const vec4 masks = vec4(0.0, 1.0 / 256.0, 1.0 / 256.0, 1.0 / 256.0);
  vec4 packed = fract(clamp(value, 0.0, 0.999999) * shifts);
  packed -= packed.xxyz * masks;
  return packed;
}

void main() {
  if (texture(uSprites, vec3(fragmentUv, fragmentLayer)).a < uCut.x) {
    discard;
  }
  float z = gl_FragCoord.z;
  float near = uNearFar.x;
  float far = uNearFar.y;
  float linear = (near * far) / max(far - z * (far - near), 0.0001);
  if (linear >= uFogFade.x) {
    discard;
  }
  outColor = packDepth(linear / far);
}
