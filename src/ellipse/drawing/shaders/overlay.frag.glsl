#version 450

// The UI picture sampled straight: whatever orientation `readPicture`
// hands over, this rides onto the screen exactly as the composite path
// rides the scene -- the pairing verified against the live window.

layout(location = 0) in vec2 vUv;
layout(location = 0) out vec4 outColor;
layout(set = 2, binding = 0) uniform sampler2D uUi;

void main() {
  outColor = texture(uUi, vUv);
}
