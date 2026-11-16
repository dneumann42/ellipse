#version 450
#extension GL_GOOGLE_include_directive : require

// A billboard into the occlusion pass's packed linear depth: cut out exactly
// as the colour pass cuts it, so the shade it casts matches its outline.

layout(location = 0) in vec2 fragmentUv;
layout(location = 1) in float fragmentLayer;

layout(location = 5) flat in vec4 clothingLayers;
layout(location = 6) in vec2 clothingUv0;
layout(location = 7) in vec2 clothingUv1;
layout(location = 8) in vec2 clothingUv2;
layout(location = 9) in vec2 clothingUv3;

layout(location = 0) out vec4 outColor;

layout(set = 2, binding = 0) uniform sampler2DArray uSprites;

layout(set = 3, binding = 0) uniform Depth {
  vec4 uNearFar; // x = near, y = far
  vec4 uFogFade; // x: metres past which geometry stops occluding
  vec4 uCut;     // x: occlusion cutoff; y: coverage filter
};

vec4 packDepth(float value) {
  const vec4 shifts = vec4(16777216.0, 65536.0, 256.0, 1.0);
  const vec4 masks = vec4(0.0, 1.0 / 256.0, 1.0 / 256.0, 1.0 / 256.0);
  vec4 packed = fract(clamp(value, 0.0, 0.999999) * shifts);
  packed -= packed.xxyz * masks;
  return packed;
}

#include "character_filter.glsl.inc"

vec4 dressedTexel() {
  if (uCut.y > 0.5) return coverageTexel();
  // Accumulate premultiplied color, then return straight color for lighting.
  vec4 body = texture(uSprites,vec3(fragmentUv,fragmentLayer));
  vec4 result = vec4(body.rgb*body.a,body.a);
  vec2 uv[4] = vec2[](clothingUv0,clothingUv1,clothingUv2,clothingUv3);
  for (int i=0;i<4;++i) {
    if (clothingLayers[i] < 0.0) continue;
    vec4 cloth = texture(uSprites,vec3(uv[i],clothingLayers[i]));
    result.rgb = cloth.rgb*cloth.a + result.rgb*(1.0-cloth.a);
    result.a = cloth.a + result.a*(1.0-cloth.a);
  }
  if (result.a > 0.0) result.rgb /= result.a;
  return result;
}

void main() {
  if (dressedTexel().a < uCut.x) {
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
