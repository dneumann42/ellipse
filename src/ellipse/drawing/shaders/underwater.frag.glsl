#version 450

// The finished scene looked at from under the water: the picture sways in
// slow crossing waves, takes the water's colour, and loses light, colour
// and sharpness as the eye sinks. `clarity` is the depth over which the
// light halves; red goes first, then green, so the deep turns blue.

layout(location = 0) in vec2 vUv;
layout(location = 0) out vec4 outColor;
layout(set = 2, binding = 0) uniform sampler2D uScene;

layout(set = 3, binding = 0) uniform Underwater {
  vec4 uShallow; // rgb: the water just under the surface; w: metres the eye is down
  vec4 uDeep;    // rgb: the water far down; w: clarity, metres per halving of the light
  vec4 uWobble;  // x: sway, a fraction of the screen; y: waves across it; z: speed; w: seconds
  vec4 uScreen;  // xy: pixels across and down; z: blur in pixels at full murk; w: unused
};

const float TAU = 6.2831853;

vec2 sway(vec2 uv) {
  float t = uWobble.w * uWobble.z;
  float k = max(uWobble.y, 0.0) * TAU;
  // Two waves each way at unrelated rates, so the motion never repeats
  // in a way the eye can follow.
  return vec2(
    sin(uv.y * k + t) + 0.5 * sin(uv.y * k * 2.3 + uv.x * 3.1 - t * 1.7),
    cos(uv.x * k * 0.8 + t * 1.3) + 0.5 * sin(uv.x * k * 1.9 + uv.y * 4.2 + t * 0.9)
  ) / 1.5;
}

void main() {
  float depth = max(uShallow.w, 0.0);
  float clarity = max(uDeep.w, 0.01);
  float murk = 1.0 - exp2(-depth / clarity); // 0 at the surface, toward 1 far down

  vec2 uv = vUv + sway(vUv) * uWobble.x;

  // A ring of taps around the swayed point, wider the deeper the eye.
  vec2 texel = 1.0 / max(uScreen.xy, vec2(1.0));
  float radius = uScreen.z * murk;
  vec3 scene = texture(uScene, uv).rgb * 2.0;
  for (int i = 0; i < 6; i++) {
    float angle = float(i) * (TAU / 6.0);
    scene += texture(uScene, uv + vec2(cos(angle), sin(angle)) * radius * texel).rgb;
  }
  scene /= 8.0;

  // Absorbed: red fastest, blue slowest, and never fully clear even right
  // under the surface.
  vec3 absorb = exp2(-(depth + 1.0) / clarity * vec3(1.4, 0.7, 0.45));
  vec3 water = mix(uShallow.rgb, uDeep.rgb, murk);
  vec3 colour = mix(scene * absorb, water, 0.2 + 0.6 * murk);

  // Darker toward the edges, more so far down.
  float edge = smoothstep(0.85, 0.25, length(vUv - 0.5));
  colour *= mix(1.0, edge, 0.25 + 0.45 * murk);

  outColor = vec4(colour, 1.0);
}
