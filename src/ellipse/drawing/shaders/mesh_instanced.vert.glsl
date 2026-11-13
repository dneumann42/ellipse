#version 450

layout(location = 0) in vec3 position;
layout(location = 1) in vec3 normal;
layout(location = 2) in vec4 color;
layout(location = 3) in vec2 uv;
layout(location = 4) in float occlusion;

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
layout(location = 3) out float fragmentCell; // atlas layer to sample; 0: none

layout(location = 4) out vec3 localAlbedo;
layout(location = 5) out vec3 localNormal;
layout(location = 6) out float environmentWeight;

layout(set = 1, binding = 1) uniform Instances {
  mat4 models[64];
} instances;

void main() {
  mat4 model = instances.models[gl_InstanceIndex] * u.model;
  vec4 world = model * vec4(position, 1.0);
  gl_Position = u.viewProj * world;

  mat3 normalMatrix = transpose(inverse(mat3(model)));
  vec3 n = normalize(normalMatrix * normal);
  vec3 l = normalize(u.light.xyz); // toward the light: the artist sends it so
  float diffuse = max(dot(n, l), 0.0) * u.light.w;
  float specular = pow(max(dot(reflect(-l, n), normalize(-world.xyz)), 0.0), u.params.y) * u.params.z;

  vertexColor = vec4(u.color.rgb * color.rgb * (u.params.x + diffuse) + specular, u.color.a * color.a);
  vertexColor.rgb *= 1.0-clamp(occlusion,0.0,1.0);
  fragmentUv = uv;
  worldPosition = world.xyz;
  fragmentCell = u.params.w;
  localAlbedo = u.color.rgb * color.rgb;
  localNormal = n;
  // The artist draws sky bodies and lamp flames with unit ambient and no
  // directional light. Preserve these intentionally emissive batches.
  environmentWeight = (u.params.x >= 0.999 && u.light.w <= 0.0) ? 0.0 : 1.0;
}
