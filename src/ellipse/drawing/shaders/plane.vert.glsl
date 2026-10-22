#version 450

// A sprite plane's corners arrive already placed in the world: the vertex
// stage only lifts them through the frustum and hands the picture's corners
// and the caller's colour along. No lighting -- a held weapon wears its own
// brightness, the way it does in the hand.

layout(location = 0) in vec3 position;
layout(location = 1) in vec2 uv;
layout(location = 2) in vec4 color;

layout(set = 1, binding = 0) uniform Uniforms {
  mat4 viewProj;
  vec4 params; // x: the cut; three unused
} u;

layout(location = 0) out vec4 vertexColor;
layout(location = 1) out vec2 fragmentUv;
layout(location = 2) out vec3 worldPosition;

void main() {
  gl_Position = u.viewProj * vec4(position, 1.0);
  vertexColor = color;
  fragmentUv = uv;
  worldPosition = position;
}
