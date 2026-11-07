#version 450
#extension GL_GOOGLE_include_directive : require

// Water shading, all of it procedural. The surface tilts by the slope of a
// few octaves of gradient-carrying noise. Still water drifts two layers of it
// across each other in the wind; moving water carries its layer downstream
// with the flow, twice over, half a cycle apart, crossfading so neither
// stretches far before it is swapped out (the usual flow-map trick). The
// tilted surface reflects the sky and the sun by Fresnel, and lets the
// bottom through by depth: clear and pale over the shallows, dark and opaque
// out deep. White water is noise thresholded by how broken the surface is,
// carried along with the flow. Surf -- the sea where it runs onto a beach --
// breaks: crests the vertex stage heaves toward the shore go white as they
// reach the shallows, spill foam behind them, and leave a lace of it on the
// sand as the wash drains back.

layout(location = 0) in vec3 worldPosition;
layout(location = 1) in vec3 worldNormal;
layout(location = 2) in vec4 water; // xy: flow over x and z, z: depth, w: foam
layout(location = 3) in vec4 surfing; // x: surf; y: depth under the still surface; z: lift; w: shore

layout(location = 0) out vec4 outColor;

layout(set = 3, binding = 0) uniform Water {
  vec4 uShallow; // rgb; a: clarity, metres the bottom fades out over
  vec4 uDeep;    // rgb; a: metres across one ripple
  vec4 uSky;     // rgb; a: how far ripples tilt the surface
  vec4 uEye;     // xyz: the eye; w: seconds
  vec4 uSun;     // xyz: toward the sun; w: its intensity
  vec4 uAmbient; // x: flat fill
  vec4 uFogNear; // rgb: the haze at the edge of sight; a: density
  vec4 uFogFar;  // rgb: the haze far in; a: falloff
  vec4 uFogLimit; // x: metres past which the world stops
  vec4 uSurf;     // x: wave height; y: seconds between waves; z: metres out they rise from; w: metres between crests
  vec4 uGroundArea; // xy: x and z of the ground's first height; z: metres between; w: heights across
};

layout(set = 2, binding = 0) uniform sampler2D uGround; // one float a texel: the ground's height

// The ground's height under `xz`, blended from the four heights round it --
// fetched and blended here, as a float texture need not filter. False
// outside the square the heights cover.
bool groundAt(vec2 xz, out float height) {
  height = 0.0;
  float size = uGroundArea.w;
  vec2 f = (xz - uGroundArea.xy) / max(uGroundArea.z, 1e-3);
  if (size < 2.0 || any(lessThan(f, vec2(0.0))) || any(greaterThanEqual(f, vec2(size - 1.0)))) {
    return false;
  }
  ivec2 i = ivec2(floor(f));
  vec2 t = f - vec2(i);
  float h00 = texelFetch(uGround, i, 0).r;
  float h10 = texelFetch(uGround, i + ivec2(1, 0), 0).r;
  float h01 = texelFetch(uGround, i + ivec2(0, 1), 0).r;
  float h11 = texelFetch(uGround, i + ivec2(1, 1), 0).r;
  height = mix(mix(h00, h10, t.x), mix(h01, h11, t.x), t.y);
  return true;
}

const float Cycle = 2.0; // seconds one flow layer lives before it is reset

float fogAmount(float reach) {
  float soft = clamp(1.0 - exp(-reach * max(uFogNear.a, 0.0)), 0.0, 1.0);
  soft = pow(soft, max(uFogFar.a, 0.001));
  float limit = max(uFogLimit.x, 0.001);
  return max(soft, smoothstep(limit * 0.82, limit, reach));
}

float fogVisibility(float reach) {
  float limit = max(uFogLimit.x, 0.001);
  return 1.0 - smoothstep(limit * 0.82, limit, reach);
}

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

vec2 gradient(ivec2 cell) {
  float angle = float(hash(cell)) * (6.2831853 / 4294967296.0);
  return vec2(cos(angle), sin(angle));
}

// Gradient noise, roughly -0.7 .. 0.7, and its two partial derivatives, in
// x, y, z. Unlike value noise it has no creases along the lattice, which
// ripples tilted by its slope would show as straight lines.
vec3 noised(vec2 x) {
  ivec2 i = ivec2(floor(x));
  vec2 f = fract(x);
  vec2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
  vec2 du = 30.0 * f * f * (f * (f - 2.0) + 1.0);
  vec2 ga = gradient(i);
  vec2 gb = gradient(i + ivec2(1, 0));
  vec2 gc = gradient(i + ivec2(0, 1));
  vec2 gd = gradient(i + ivec2(1, 1));
  float va = dot(ga, f);
  float vb = dot(gb, f - vec2(1.0, 0.0));
  float vc = dot(gc, f - vec2(0.0, 1.0));
  float vd = dot(gd, f - vec2(1.0, 1.0));
  float k = va - vb - vc + vd;
  return vec3(va + u.x * (vb - va) + u.y * (vc - va) + u.x * u.y * k,
              ga + u.x * (gb - ga) + u.y * (gc - ga) + u.x * u.y * (ga - gb - gc + gd) +
              du * (u.yx * k + vec2(vb, vc) - va));
}

// The slope of three octaves of ripples, each rotated off the last so their
// grids never line up.
vec2 ripples(vec2 p) {
  const mat2 turn = mat2(0.8, 0.6, -0.6, 0.8);
  vec2 slope = vec2(0.0);
  float amplitude = 1.0;
  for (int i = 0; i < 3; i++) {
    slope += noised(p).yz * amplitude;
    p = turn * p * 2.03 + vec2(17.1, 3.7);
    amplitude *= 0.55 * 2.03; // the slope of a smaller ripple counts for more
  }
  return slope / 2.6;
}

float valueNoise(vec2 x) {
  ivec2 i = ivec2(floor(x));
  vec2 f = fract(x);
  vec2 s = f * f * (3.0 - 2.0 * f);
  return mix(mix(random(i), random(i + ivec2(1, 0)), s.x),
             mix(random(i + ivec2(0, 1)), random(i + ivec2(1, 1)), s.x), s.y);
}

// Where a wave is at this spot: 0 as its crest passes, rising to 1 as the
// next crest comes. Matches the vertex stage's, which heaves the surface by it.
float wavePhase(vec2 xz, float shore, float time, float period, float spacing) {
  float offset = valueNoise(xz / 70.0) * 1.3 + valueNoise(xz / 23.0) * 0.25;
  return fract(time / period + offset + shore / spacing);
}

// How white the surf is here: the crest's lip and the foam spilling behind
// it once it breaks, then a lace left on the beach while the wash runs back.
// Also how much the crest glows where it stands up unbroken. `shore` is
// metres out from the shore.
vec2 surfFoam(vec2 xz, float shore, float time) {
  float reach = max(uSurf.z, 1e-3);
  if (shore >= reach) {
    return vec2(0.0);
  }
  float v = wavePhase(xz, shore, time, max(uSurf.y, 0.1), max(uSurf.w, 0.1));
  float breaking = 1.0 - smoothstep(0.3 * reach, 0.65 * reach, shore);
  float front = smoothstep(0.9, 1.0, v);
  float crest = max(front * front, 1.0 - smoothstep(0.0, 0.06 + 0.3 * breaking, v));
  float lace = (1.0 - smoothstep(0.15 * reach, 0.35 * reach, shore)) *
               (1.0 - smoothstep(0.1, 0.6, v)) * 0.6;
  float fade = 1.0 - smoothstep(0.8 * reach, reach, shore);
  return vec2(max(crest * breaking, lace), front * (1.0 - breaking)) * fade;
}

float foamNoise(vec2 p) {
  return 0.5 + noised(p).x * 0.6 + noised(p * 2.7 + 9.3).x * 0.3;
}

#include "clustered.glsl.inc"

void main() {
  float clarity = max(uShallow.a, 1e-3);
  float rippleMeters = max(uDeep.a, 1e-3);
  float time = uEye.w;
  vec2 flow = water.xy;
  // Depth to the ground under this very pixel where its heights are known:
  // the depths at the corners blend in a straight line across a triangle,
  // and a bank curves, so they put the waterline metres off where it is.
  float depth = water.z;
  float ground;
  if (groundAt(worldPosition.xz, ground)) {
    depth = worldPosition.y - ground;
  }
  float churn = clamp(water.w, 0.0, 1.0);
  float speed = length(flow);
  vec2 surf = surfing.x > 0.0 ? surfFoam(worldPosition.xz, surfing.w, time) * surfing.x
                              : vec2(0.0);

  vec2 p = worldPosition.xz / rippleMeters;
  // Ripples finer than a pixel only shimmer: fade them by the footprint.
  float footprint = length(fwidth(p));
  float detail = 1.0 - smoothstep(0.35, 1.6, footprint);

  // Still water: two layers drifting across each other.
  vec2 still = ripples(p + time * vec2(0.23, 0.07)) +
               0.6 * ripples(p * 1.6 - time * vec2(0.04, 0.19));
  // Moving water: one layer carried twice, half a cycle apart.
  float phase0 = fract(time / Cycle);
  float phase1 = fract(time / Cycle + 0.5);
  vec2 carried = flow / rippleMeters * Cycle;
  vec2 moving = mix(ripples(p - carried * phase0),
                    ripples(p - carried * phase1 + vec2(0.37, 0.71)),
                    abs(2.0 * phase0 - 1.0));
  vec2 slope = mix(still, moving * 1.4, clamp(speed * 1.5, 0.0, 1.0));
  float strength = uSky.a * detail * (1.0 + 1.5 * max(churn, surf.x));

  vec3 base = normalize(worldNormal);
  vec3 n = normalize(base - vec3(slope.x, 0.0, slope.y) * strength);
  vec3 toEye = normalize(uEye.xyz - worldPosition);
  if (dot(n, toEye) < 0.02) { // a ripple turned away: lean it back
    n = normalize(n + toEye * (0.02 - dot(n, toEye)));
  }
  vec3 sun = normalize(uSun.xyz);

  float facing = max(dot(n, toEye), 0.0);
  float fresnel = 0.02 + 0.98 * pow(1.0 - facing, 5.0);
  vec3 r = reflect(-toEye, n);
  vec3 sky = mix(uSky.rgb * 1.08, uSky.rgb * 0.72, clamp(r.y, 0.0, 1.0));
  float glint = pow(max(dot(r, sun), 0.0), 320.0) * 4.0 +
                pow(max(dot(r, sun), 0.0), 48.0) * 0.12;
  glint *= uSun.w * smoothstep(-0.05, 0.08, sun.y);

  float light = uAmbient.x + max(dot(base, sun), 0.0) * uSun.w * 0.7;
  float murk = 1.0 - exp(-max(depth, 0.0) / clarity);
  vec3 body = mix(uShallow.rgb, uDeep.rgb, murk) * light;
  // Broken water carries air: paler and cloudier than the same water still,
  // but still water-coloured, not white.
  body = mix(body, vec3(0.62, 0.72, 0.76) * light, churn * 0.35);
  // A crest standing up before it breaks lets the light through, greener.
  body = mix(body, vec3(0.3, 0.68, 0.62) * light, surf.y * 0.45);

  // White water: streaks of it wherever the flow breaks up, and a thin band
  // along the shore, carried downstream the same way the ripples are. Even
  // the steepest fall is only partly covered, so it reads as falling water
  // laced with foam rather than as a white sheet.
  float shore = 1.0 - smoothstep(0.0, 0.35, depth);
  float broken = max(churn * 0.55, shore * 0.45 * (1.0 - churn));
  broken = max(broken, surf.x * 0.9);
  vec2 q = worldPosition.xz * 0.9;
  vec2 drift = flow * 0.9 * Cycle;
  float carriedFoam = mix(foamNoise(q - drift * phase0),
                          foamNoise(q - drift * phase1 + vec2(5.1, 2.3)),
                          abs(2.0 * phase0 - 1.0));
  float stillFoam = foamNoise(q + time * vec2(0.05, 0.03));
  float pattern = mix(stillFoam, carriedFoam, clamp(speed, 0.0, 1.0));
  float foam = smoothstep(1.0 - broken, 1.0 - broken + 0.12, pattern) * smoothstep(0.0, 0.05, broken);
  foam *= 0.85;

  vec3 colour = mix(body, sky, fresnel) + glint + mix(uShallow.rgb, uDeep.rgb, 0.5) * pointLighting(worldPosition, n);
  colour = mix(colour, vec3(0.9, 0.94, 0.96) * light, foam);

  float alpha = mix(0.3, 0.94, murk) + fresnel * 0.5 + foam;
  alpha = max(alpha, churn * 0.6);
  // Onto the shore it thins to nothing, so the bank shows where it rises
  // through the surface rather than a hard edge of mesh.
  alpha = clamp(alpha, 0.0, 1.0) * smoothstep(0.0, 0.12, depth);

  // The sea fogs like the land it laps: colour sinking into the haze, and
  // the sheet thinning to nothing where the world ends.
  float reach = length(uEye.xyz - worldPosition);
  float visibility = fogVisibility(reach);
  if (visibility <= 0.001) {
    discard;
  }
  float amount = fogAmount(reach);
  colour = mix(colour, mix(uFogNear.rgb, uFogFar.rgb, amount), amount);
  alpha *= visibility;

  outColor = vec4(colour, alpha);
}
