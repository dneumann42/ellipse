#version 450

// The wireframe billboard: a sprite's quad edge, with no picture to cut away.
// The filled sprites discard every texel under the cutoff, and a quad's four
// sides run through the transparent margins of its sprite, so outlining them
// through `billboard.frag` would draw almost nothing. This takes the lighting
// the vertex stage found and sinks it into the same fog, so an outlined tree
// sits in the world like the filled one it stands beside.

layout(location = 0) in vec2 fragmentUv;
layout(location = 1) in float fragmentLayer;
layout(location = 2) in vec3 fragmentLight;
layout(location = 3) in vec3 worldPosition;

layout(location = 0) out vec4 outColor;

layout(set = 3, binding = 0) uniform Fragment {
  vec4 uCut;      // x: opacity under which a texel is cut away: no texel here
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

void main() {
  float reach = length(uFogEye.xyz - worldPosition);
  float visibility = fogVisibility(reach);
  if (visibility <= 0.001) {
    discard;
  }
  vec3 colour = fragmentLight;
  float amount = fogAmount(reach);
  vec3 hazed = mix(colour, mix(uFogNear.rgb, uFogFar.rgb, amount), amount);
  outColor = vec4(hazed, visibility);
}
