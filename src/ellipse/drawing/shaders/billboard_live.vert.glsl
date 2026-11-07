#version 450

// Billboards: one instance per sprite, its six corners built here from
// gl_VertexIndex. Each stands upright on its foot, turned square to the
// camera's flattened right, its top swaying in the wind by its own phase.
// Lighting is a sprite's: no normal to speak of, so the sun lights it by how
// high it stands, and the foot of every sprite falls into its own shade the
// way the floor under a canopy does.

layout(location = 0) in vec3 iPosition; // the middle of the foot
layout(location = 1) in vec2 iSize;     // metres across and tall
layout(location = 2) in float iLayer;
layout(location = 3) in float iShade;
layout(location = 4) in float iPhase;
layout(location = 5) in float iBlink;   // damage-flash intensity 0..1

layout(location = 6) in vec4 iRect; // per-instance sprite UV rectangle

layout(location = 7) in vec4 iClothing;
layout(location = 8) in vec4 iClothingRect0;
layout(location = 9) in vec4 iClothingRect1;
layout(location = 10) in vec4 iClothingRect2;
layout(location = 11) in vec4 iClothingRect3;
layout(location = 5) flat out vec4 clothingLayers;
layout(location = 6) out vec2 clothingUv0;
layout(location = 7) out vec2 clothingUv1;
layout(location = 8) out vec2 clothingUv2;
layout(location = 9) out vec2 clothingUv3;

layout(set = 1, binding = 0) uniform Uniforms {
  mat4 viewProj;
  vec4 eye;    // xyz: the eye; w: seconds
  vec4 right;  // xyz: the camera's right, flat; w: metres of sway
  vec4 light;  // xyz: toward the sun; w: intensity
  vec4 params; // x: ambient; y: grow; z: cutoff
} u;

layout(location = 0) out vec2 fragmentUv;
layout(location = 1) out float fragmentLayer;
layout(location = 2) out vec3 fragmentLight;
layout(location = 3) out vec3 worldPosition;
layout(location = 4) out float fragmentBlink;

const vec2 corners[6] = vec2[](
  vec2(0.0, 0.0), vec2(1.0, 0.0), vec2(1.0, 1.0),
  vec2(0.0, 0.0), vec2(1.0, 1.0), vec2(0.0, 1.0)
);

void main() {
  vec2 c = corners[gl_VertexIndex % 6];
  vec2 size = iSize * u.params.y;
  vec3 up = vec3(0.0, 1.0, 0.0);
  vec3 world = iPosition + u.right.xyz * ((c.x - 0.5) * size.x) + up * (c.y * size.y);

  // The top sways, the foot holds: the bend grows with the square of the
  // height up the sprite, and taller sprites sway further.
  float gust = sin(u.eye.w * 1.3 + iPhase * 6.2831853) +
               0.35 * sin(u.eye.w * 3.1 + iPhase * 17.0);
  float sway = (iPhase > 0.0 ? u.right.w : 0.0) * c.y * c.y * (size.y / 10.0) * gust;
  world += u.right.xyz * sway;

  gl_Position = u.viewProj * vec4(world, 1.0);

  int layer = int(iLayer + 0.5);
  vec4 rect = iRect;
  fragmentUv = vec2(mix(rect.x, rect.z, c.x), mix(rect.w, rect.y, c.y));
  fragmentLayer = float(layer);
  clothingLayers = iClothing;
  vec2 logical = vec2(c.x,1.0-c.y);
  clothingUv0 = mix(iClothingRect0.xy,iClothingRect0.zw,logical);
  clothingUv1 = mix(iClothingRect1.xy,iClothingRect1.zw,logical);
  clothingUv2 = mix(iClothingRect2.xy,iClothingRect2.zw,logical);
  clothingUv3 = mix(iClothingRect3.xy,iClothingRect3.zw,logical);

  float sun = u.light.w * (0.55 + 0.45 * clamp(u.light.y, 0.0, 1.0));
  float foot = mix(0.62, 1.0, smoothstep(0.0, 0.55, c.y));
  fragmentLight = vec3((u.params.x + sun) * iShade * foot);
  worldPosition = world;
  fragmentBlink = iBlink;
}
