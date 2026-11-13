#version 450

// The sky's fullscreen triangle: one huge triangle covering the frame, its
// vertices built from gl_VertexIndex alone. Each fragment un-projects its
// own clip position through the camera's rotation into a world direction,
// so the dome turns with the eye and sits at infinite distance.

layout(location = 0) out vec3 vViewDirection;

layout(set = 1, binding = 0) uniform Sky {
  mat4 uCameraRotation;
  vec4 uViewportScale; // tan of the projection's half-angles, x widened by aspect
  vec4 uHorizonExposure;
  vec4 uZenithUseSkybox;
  vec4 uGroundColorValue;
  vec4 uCloudWeather; // seconds, coverage, daylight, enabled
  vec4 uCloudSun; // direction toward sun
};

void main() {
  vec2 positions[3] = vec2[](vec2(-1.0, -1.0), vec2(3.0, -1.0), vec2(-1.0, 3.0));
  vec2 position = positions[gl_VertexIndex];
  vec3 viewDirection = vec3(
    position.x * uViewportScale.x,
    position.y * uViewportScale.y,
    -1.0 // the camera looks down -z, like the projection the scene draws with
  );
  vViewDirection = (uCameraRotation * vec4(viewDirection, 0.0)).xyz;
  gl_Position = vec4(position, 0.0, 1.0);
}
