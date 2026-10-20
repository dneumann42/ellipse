#version 450

// Straight colour in, premultiplied out: the pass blends the way the
// overlay does.

layout(location = 0) in vec4 vertexColor;
layout(location = 0) out vec4 outColor;

void main() {
  outColor = vec4(vertexColor.rgb * vertexColor.a, vertexColor.a);
}
