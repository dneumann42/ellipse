#version 450

layout(location = 0) in vec3 position;
layout(location = 1) in vec3 normal;
layout(location = 2) in vec4 color;
layout(location = 3) in vec2 uv;

layout(set = 1, binding = 0) uniform Uniforms {
  mat4 model;
  mat4 viewProj;
  vec4 color;
  vec4 light;
  vec4 params;
} u;

layout(location = 0) out vec4 vertexColor;
layout(location = 1) out vec2 fragmentUv;
layout(location = 2) out vec3 worldPosition; // the fragment stage fogs by the reach to it

void main() {
  vec4 world = u.model * vec4(position, 1.0);
  gl_Position = u.viewProj * world;

  mat3 normalMatrix = transpose(inverse(mat3(u.model)));
  vec3 n = normalize(normalMatrix * normal);
  vec3 l = normalize(u.light.xyz); // toward the light: the artist sends it so
  float diffuse = max(dot(n, l), 0.0) * u.light.w;
  float specular = pow(max(dot(reflect(-l, n), normalize(-world.xyz)), 0.0), u.params.y) * u.params.z;

  vertexColor = vec4(u.color.rgb * color.rgb * (u.params.x + diffuse) + specular, u.color.a * color.a);
  fragmentUv = uv;
  worldPosition = world.xyz;
}
