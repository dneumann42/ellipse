#version 450

// Water: the surface as laid, handed on whole to the fragment stage, which
// does all the shading -- ripples, reflections and glints change across a
// single triangle. Only surf moves the surface itself. A swell of a few long
// waves rolls across it, gathering the water toward each crest, and dies out
// over deep water and away from the eye, where the mesh grows too coarse to
// carry it. Nearer the beach each breaking wave lifts the water more the
// shallower it runs, and at the shore pushes the waterline up the beach and
// lets it slide back. The fragment stage works out the same breakers to lay
// foam on them.

layout(location = 0) in vec3 position;
layout(location = 1) in vec3 normal;
layout(location = 2) in vec4 stream; // xy: flow over x and z, z: depth, w: foam
layout(location = 3) in float surf;  // 0 sheltered .. 1 open sea

layout(set = 1, binding = 0) uniform Uniforms {
  mat4 model;
  mat4 viewProj;
  vec4 color; // xyz: the eye
  vec4 light;
  vec4 params; // x: seconds; y: wave height; z: seconds between waves; w: depth they rise from
} u;

layout(location = 0) out vec3 worldPosition;
layout(location = 1) out vec3 worldNormal;
layout(location = 2) out vec4 water; // as `stream`, but depth under the heaved surface
layout(location = 3) out vec2 surfing; // x: surf; y: depth under the still surface

// A well-mixed integer hash of a lattice point: no float rounding, so the
// noise stays as fine-grained far from the origin as near it.
uint hash(ivec2 cell) {
  uvec2 v = uvec2(cell) * 1664525u + 1013904223u;
  v.x += v.y * 1664525u;
  v.y += v.x * 1664525u;
  v ^= v >> 16u;
  v.x += v.y * 1664525u;
  v.y += v.x * 1664525u;
  v ^= v >> 16u;
  return v.x ^ v.y;
}

float random(ivec2 cell) {
  return float(hash(cell) >> 8u) / 16777216.0;
}

float valueNoise(vec2 x) {
  ivec2 i = ivec2(floor(x));
  vec2 f = fract(x);
  vec2 s = f * f * (3.0 - 2.0 * f);
  return mix(mix(random(i), random(i + ivec2(1, 0)), s.x),
             mix(random(i + ivec2(0, 1)), random(i + ivec2(1, 1)), s.x), s.y);
}

// The swell's lift (y) and pull toward its crests (xz), each wave travelling
// at deep-water speed; `slope` takes the height's rise over x and z.
vec3 swell(vec2 xz, float time, out vec2 slope) {
  const vec4 Waves[3] = vec4[3]( // xy: heading; z: metres crest to crest; w: share of height
    vec4(0.8, 0.6, 31.0, 0.5),
    vec4(0.35, 0.94, 19.0, 0.3),
    vec4(0.97, -0.25, 13.0, 0.2));
  const float Pinch = 0.35; // how far crests gather the water, 0 .. 1
  vec3 offset = vec3(0.0);
  slope = vec2(0.0);
  for (int i = 0; i < 3; i++) {
    vec2 heading = normalize(Waves[i].xy);
    float k = 6.2831853 / Waves[i].z;
    float a = Waves[i].w;
    float phase = k * (dot(heading, xz) - sqrt(9.8 / k) * time) + float(i) * 2.1;
    offset.y += a * sin(phase);
    offset.xz += heading * (Pinch / (k * 3.0)) * cos(phase);
    slope += heading * k * a * cos(phase);
  }
  return offset;
}

// Where a wave is at this spot: 0 as its crest passes, rising to 1 as the
// next crest comes. Crests run toward shallower water; stretches of shore
// tens of metres apart take them at different moments. Matches the fragment
// stage's.
float wavePhase(vec2 xz, float depth, float time, float period, float reach) {
  float offset = valueNoise(xz / 70.0) * 1.3 + valueNoise(xz / 23.0) * 0.25;
  return fract(time / period + offset + depth / reach);
}

void main() {
  vec4 world = u.model * vec4(position, 1.0);
  float depth = stream.z;
  float lift = 0.0;
  vec3 normalOut = normalize(transpose(inverse(mat3(u.model))) * normal);
  float reach = u.params.w;
  float sway = surf * (1.0 - smoothstep(6.0, 16.0, depth)) *
               (1.0 - smoothstep(90.0, 150.0, length(world.xyz - u.color.xyz)));
  if (sway > 0.0) {
    vec2 slope;
    vec3 offset = swell(world.xz, u.params.x, slope);
    float height = u.params.y * 0.6 * sway;
    world.xz += offset.xz * height;
    lift = offset.y * height;
    normalOut = normalize(normalOut - vec3(slope.x, 0.0, slope.y) * height);
  }
  if (surf > 0.0 && depth < reach) {
    float v = wavePhase(world.xz, depth, u.params.x, u.params.z, reach);
    // A quick rise as the crest arrives, a slow fall as it drains back.
    float rise = smoothstep(0.82, 1.0, v) + 1.0 - smoothstep(0.0, 0.5, v);
    float shoal = 1.0 - smoothstep(0.15 * reach, reach, depth);
    lift += u.params.y * rise * shoal * surf;
    // Mesh past the waterline may lift only to the ground it stands over,
    // so the water's edge always meets the beach rather than the mesh's end.
    if (depth < 0.0) {
      lift = min(lift, -depth);
    }
  }
  world.y += lift;
  gl_Position = u.viewProj * world;
  worldPosition = world.xyz;
  worldNormal = normalOut;
  water = vec4(stream.xy, depth + lift, stream.w);
  surfing = vec2(surf, depth);
}
