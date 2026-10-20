#version 450

// Flat 2D shapes in window pixels, top-left origin, y down.

layout(location = 0) in vec2 position;
layout(location = 1) in vec4 color;

layout(set = 1, binding = 0) uniform Uniforms {
  vec4 viewport; // width, height in pixels, then two unused
} u;

layout(location = 0) out vec4 vertexColor;

void main() {
  vec2 ndc = vec2(position.x / u.viewport.x * 2.0 - 1.0,
                  1.0 - position.y / u.viewport.y * 2.0);
  gl_Position = vec4(ndc, 0.0, 1.0);
  vertexColor = color;
}
