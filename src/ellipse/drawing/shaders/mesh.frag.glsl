#version 450

// Meshes carry their colour from the vertex stage; the fragment stage only
// tints that colour by the mesh texture when the batch asked for one (the
// vertex stage hands the atlas layer over in `fragmentCell`, 0 meaning
// none), and sinks them into the fog: a haze that thickens with reach,
// fades out at the limit, and past it lets the sky show through.

layout(location = 0) in vec4 vertexColor;
layout(location = 1) in vec2 fragmentUv;
layout(location = 2) in vec3 worldPosition;
layout(location = 3) in float fragmentCell;

layout(location = 0) out vec4 outColor;

layout(set = 2, binding = 0) uniform sampler2DArray uMeshTex;

layout(set = 3, binding = 0) uniform Fog {
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
  vec3 colour = vertexColor.rgb;
  if (fragmentCell > 0.5) {
    // The cell rides in the batch's uniform, so every fragment of a
    // textured draw takes this branch together and the implicit
    // derivatives stay well defined.
    colour *= texture(uMeshTex, vec3(fragmentUv, floor(fragmentCell - 0.5))).rgb;
  }
  float amount = fogAmount(reach);
  vec3 hazed = mix(colour, mix(uFogNear.rgb, uFogFar.rgb, amount), amount);
  outColor = vec4(hazed, vertexColor.a * visibility);
}
