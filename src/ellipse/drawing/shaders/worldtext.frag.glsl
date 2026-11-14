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
  // A signed distance's transition follows the projected pixel footprint.
  // Slight weight compensation preserves fine stems when signs get small.
  float distance = texture(uSprite, fragmentUv).a;
  float footprint = clamp(fwidth(distance), 1.0 / 255.0, 0.45);
  vec2 atlasSize = vec2(textureSize(uSprite, 0));
  float texelsPerPixel = max(length(dFdx(fragmentUv) * atlasSize),
                            length(dFdy(fragmentUv) * atlasSize));
  // Below a few pixels per em there is no readable letter shape. Fade instead
  // of turning the padded glyph cells into flickering blocks.
  float sizeVisibility = smoothstep(2.0, 5.0, 48.0 / max(texelsPerPixel, 0.001));
  float weight = min(footprint * 0.12, 0.035);
  float ink = smoothstep(0.5 - footprint * 0.5, 0.5 + footprint * 0.5,
                         distance + weight);
  // Offset in atlas texels (inside each glyph's padded cell), so the shadow
  // stays attached to the painted surface at every orientation and distance.
  vec2 texel = 1.0 / vec2(textureSize(uSprite, 0));
  float behind = texture(uSprite, fragmentUv - texel * vec2(1.5, 2.0)).a;
  float shadow = 0.65 * smoothstep(0.5 - footprint * 0.75,
                                 0.5 + footprint * 0.75, behind);
  float opacity = ink + shadow * (1.0 - ink);
  if (opacity < 0.01) discard;
  float reach = length(uFogEye.xyz - worldPosition);
  float visibility = fogVisibility(reach);
  if (visibility <= 0.001) {
    discard;
  }
  vec3 colour = mix(vec3(0.055, 0.035, 0.025), vertexColor.rgb, ink / max(opacity, 0.001));
  float amount = fogAmount(reach);
  vec3 hazed = mix(colour, mix(uFogNear.rgb, uFogFar.rgb, amount), amount);
  outColor = vec4(hazed, vertexColor.a * visibility * opacity * sizeVisibility);
}
