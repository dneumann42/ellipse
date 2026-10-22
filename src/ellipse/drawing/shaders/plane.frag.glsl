#version 450

// The plane's picture: a texel under the cut is discarded, the rest tinted
// by the caller's colour and sunk into the scene's fog -- the same haze the
// meshes fade into, so a plane standing at the world's edge dissolves with
// it rather than floating clear above the haze.

layout(location = 0) in vec4 vertexColor;
layout(location = 1) in vec2 fragmentUv;
layout(location = 2) in vec3 worldPosition;

layout(location = 0) out vec4 outColor;

layout(set = 2, binding = 0) uniform sampler2D uSprite;

layout(set = 3, binding = 0) uniform Planes {
  vec4 uFogEye;   // xyz: the eye
  vec4 uFogNear;  // rgb: the haze at the edge of sight; a: density
  vec4 uFogFar;   // rgb: the haze far in; a: falloff
  vec4 uFogLimit; // x: metres past which the world stops
  vec4 uCut;      // x: opacity under which a texel is cut away
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

void main() {
  vec4 sprite = texture(uSprite, fragmentUv);
  if (sprite.a < uCut.x) {
    discard;
  }
  float reach = length(uFogEye.xyz - worldPosition);
  float visibility = fogVisibility(reach);
  if (visibility <= 0.001) {
    discard;
  }
  vec3 colour = vertexColor.rgb * sprite.rgb;
  float amount = fogAmount(reach);
  vec3 hazed = mix(colour, mix(uFogNear.rgb, uFogFar.rgb, amount), amount);
  outColor = vec4(hazed, vertexColor.a * visibility * sprite.a);
}
