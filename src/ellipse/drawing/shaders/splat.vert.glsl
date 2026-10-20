#version 450

// Splatted ground: lit per vertex like mesh.vert, with the world position
// handed on so the fragment stage can tile the layer textures across it.

layout(location = 0) in vec3 position;
layout(location = 1) in vec3 normal;
layout(location = 2) in vec4 low;
layout(location = 3) in vec4 high;

layout(set = 1, binding = 0) uniform Uniforms {
  mat4 model;
  mat4 viewProj;
  vec4 color;
  vec4 light;
  vec4 params;
} u;

layout(location = 0) out vec3 worldPosition;
layout(location = 1) out vec4 weightsLow;
layout(location = 2) out vec4 weightsHigh;
layout(location = 3) out vec4 lighting; // rgb: ambient + diffuse, a: specular

void main() {
  vec4 world = u.model * vec4(position, 1.0);
  gl_Position = u.viewProj * world;

  mat3 normalMatrix = transpose(inverse(mat3(u.model)));
  vec3 n = normalize(normalMatrix * normal);
  vec3 l = normalize(-u.light.xyz);
  float diffuse = max(dot(n, l), 0.0) * u.light.w;
  float specular = pow(max(dot(reflect(-l, n), normalize(-world.xyz)), 0.0), u.params.y) * u.params.z;

  worldPosition = world.xyz;
  weightsLow = low;
  weightsHigh = high;
  lighting = vec4(u.color.rgb * (u.params.x + diffuse), specular);
}
