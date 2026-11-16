#version 450
#extension GL_GOOGLE_include_directive : require

// A billboard's texel: cut away under the cutoff, solid above it, lit as the
// vertex stage found, tinted red by the per-instance damage flash
// (fragmentBlink, 0..1), and fogged like every other scene shader.

layout(location = 0) in vec2 fragmentUv;
layout(location = 1) in float fragmentLayer;
layout(location = 2) in vec3 fragmentLight;
layout(location = 3) in vec3 worldPosition;
layout(location = 10) in float fragmentShade;
layout(location = 4) in float fragmentBlink; // damage-flash intensity 0..1

layout(location = 5) flat in vec4 clothingLayers;
layout(location = 6) in vec2 clothingUv0;
layout(location = 7) in vec2 clothingUv1;
layout(location = 8) in vec2 clothingUv2;
layout(location = 9) in vec2 clothingUv3;

layout(location = 0) out vec4 outColor;

layout(set = 2, binding = 0) uniform sampler2DArray uSprites;

layout(set = 3, binding = 0) uniform Fragment {
  vec4 uCut;      // x: legacy cutoff; y: coverage filter; z: fringe pass
  vec4 uFogEye;   // xyz: the eye
  vec4 uFogNear;  // rgb: the haze at the edge of sight; a: density
  vec4 uFogFar;   // rgb: the haze far in; a: falloff
  vec4 uFogLimit; // x: metres past which the world stops
};

float fogAmount(float reach) {
  float soft = clamp(1.0 - exp(-reach * max(uFogNear.a, 0.0)), 0.0, 1.0);
  soft = pow(soft, max(uFogFar.a, 0.001));
  float limit = max(uFogLimit.x, 0.001);
  return max(soft, smoothstep(limit * 0.82, limit, reach));
}

float fogVisibility(float reach) {
  float limit = max(uFogLimit.x, 0.001);
  return 1.0 - smoothstep(limit * 0.82, limit, reach);
}

#include "clustered.glsl.inc"

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
  vec4 texel = dressedTexel();
  // Coverage mode: opaque core writes depth; sorted fringe never does.
  if (uCut.y > 0.5 ? (uCut.z < 0.5 ? texel.a < 0.99999 :
      (texel.a <= 0.00001 || texel.a >= 0.99999)) : texel.a < uCut.x) {
    discard;
  }
  float reach = length(uFogEye.xyz - worldPosition);
  float visibility = fogVisibility(reach);
  if (visibility <= 0.001) {
    discard;
  }
  // Zero normal requests the camera-independent spherical diffuse average.
  vec3 n = vec3(0.0);
  float sky = environmentExposure(worldPosition);
  vec3 colour = texel.rgb * (fragmentLight * sky + pointLighting(worldPosition,n) * fragmentShade);
  // damage flash: blend toward bright red by fragmentBlink
  colour = mix(colour, vec3(1.4, 0.35, 0.25) * fragmentLight * sky,
              clamp(fragmentBlink, 0.0, 1.0));
  float amount = fogAmount(reach);
  vec3 hazed = mix(colour, mix(uFogNear.rgb, uFogFar.rgb, amount), amount);
  outColor = vec4(hazed, visibility * (uCut.y > 0.5 ? texel.a : 1.0));
}
