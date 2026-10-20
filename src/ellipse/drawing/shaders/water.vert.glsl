#version 450

// Water: the surface as laid, handed on whole to the fragment stage, which
// does all the shading -- ripples, reflections and glints change across a
// single triangle.

layout(location = 0) in vec3 position;
layout(location = 1) in vec3 normal;
layout(location = 2) in vec4 stream; // xy: flow over x and z, z: depth, w: foam

layout(set = 1, binding = 0) uniform Uniforms {
  mat4 model;
  mat4 viewProj;
  vec4 color;
  vec4 light;
  vec4 params;
} u;

layout(location = 0) out vec3 worldPosition;
layout(location = 1) out vec3 worldNormal;
layout(location = 2) out vec4 water;

void main() {
  vec4 world = u.model * vec4(position, 1.0);
  gl_Position = u.viewProj * world;
  worldPosition = world.xyz;
  worldNormal = normalize(transpose(inverse(mat3(u.model))) * normal);
  water = stream;
}
