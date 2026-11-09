#version 450

// A mist puff's body, and the whole look lives in three ideas:
//
// * The body is a Gaussian: a curve, never a cliff. There is no edge of a
//   puff to find, however closely the eye looks, and overlapping bodies
//   sum their softness -- puffs blob into one another because there is
//   nothing on them to interrupt the blobbing.
// * The mottling is four octaves of value noise sampled in WORLD space,
//   so the pattern stays nailed to the ground while the eye moves through
//   it and nothing slides across a puff when the camera turns. It shades
//   the body's weight gently -- a thick roll here, a thin veil there --
//   and never cuts holes into the silhouette.
// * The blend weight is dithered with a per-pixel hash, the same grain
//   the occlusion pass wears -- and then mixed back into the continuous
//   value, so a stepped texture rides over a smooth wash: retro feel
//   without dots standing in for colour. Each pixel's decision is one
//   pixel wide, so the grain fits the retro picture exactly, and
//   dissolves into plain smoothness at true resolution.
//
// Colour rides the scene's own fog vectors: a puff takes the haze it
// floats in, mixed toward an optional tint, and sinks into it with
// distance like every other scene shader, so a field of puffs dissolves
// at the limit instead of hanging in front of the horizon.

layout(location = 0) in vec2 corner;
layout(location = 1) in vec3 worldPosition;
layout(location = 2) in vec4 shape; // x: seed 0..1; w: opacity
layout(location = 3) in float viewDepth; // metres along the view's -z

layout(location = 0) out vec4 outColor;

// The scene's own depth, packed by the occlusion pass's replay of last
// frame's geometry: one linear depth a texel, far where nothing stands.
// The mist reads it to dissolve where it would otherwise cut a hard
// chord across the land -- the soft-particle trick, and the only way a
// billboard crossing a hillside can be anything but a line.
layout(set = 2, binding = 0) uniform sampler2D uSceneDepth;

layout(set = 3, binding = 0) uniform Mist {
  vec4 uFogEye;   // xyz: the eye
  vec4 uFogNear;  // rgb: the haze at the edge of sight; a: density
  vec4 uFogFar;   // rgb: the haze far in; a: falloff
  vec4 uFogLimit; // x: metres past which the world stops
  vec4 uDither;   // x: dither share 0..1; y: softness 0..1;
                  // z: detail 0..1; w: soft fade, metres (0: off)
  vec4 uMotion;   // x: seconds; y: noise scale, metres; z: near fade,
                  // metres; w: swirl
  vec4 uTint;     // rgb: mist's own colour; a: how much of it to wear
  vec4 uSoft;     // x: the far plane, metres; yzw unused
};

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

// The occlusion pass's grain, verbatim: one value per screen pixel, no
// structure between neighbours, no clusters to read as a pattern.
float hash12(vec2 p) {
  vec3 p3 = fract(vec3(p.xyx) * 0.1031);
  p3 += dot(p3, p3.yzx + 33.33);
  return fract((p3.x + p3.y) * p3.z);
}

// The depth replay's packing, inverted: a texel's linear view depth in
// metres. See `depth.frag`: four bytes of a normalised fraction of far.
float unpackDepth(vec4 packed) {
  return dot(packed, vec4(1.0 / 16777216.0, 1.0 / 65536.0,
    1.0 / 256.0, 1.0));
}

// One cheap lattice of smooth value noise. The hash is a sine-free mix of
// bit-scrambled coordinates: fine for weather, stable across drivers.
float hash21(vec2 p) {
  p = fract(p * vec2(123.34, 456.21));
  p += dot(p, p + 45.32);
  return fract(p.x * p.y);
}

float vnoise(vec2 p) {
  vec2 i = floor(p);
  vec2 f = fract(p);
  f = f * f * (3.0 - 2.0 * f);
  float a = hash21(i);
  float b = hash21(i + vec2(1.0, 0.0));
  float c = hash21(i + vec2(0.0, 1.0));
  float d = hash21(i + vec2(1.0, 1.0));
  return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

// Four octaves, normalised: the highest crest the sum can reach is known,
// so the caller's thresholds mean the same thing at every pixel.
float fbm(vec2 p) {
  float v = vnoise(p) * 0.5 +
            vnoise(p * 2.07 + vec2(1.7, 9.2)) * 0.25 +
            vnoise(p * 4.13 + vec2(8.3, 2.8)) * 0.125 +
            vnoise(p * 8.31 + vec2(3.1, 7.7)) * 0.0625;
  return v / 0.9375;
}

void main() {
  // The body: a Gaussian core, clamped to the ellipse it inscribes by a
  // (1 - r^2)^2 skirt that drags both the value and its slope to zero at
  // the rim. A bare Gaussian never really ends -- its quad would keep a
  // faint rectangular skirt, and where two skirts meet the eye finds a
  // straight chord between them. Clamped, every puff fades out completely
  // before its quad has anything left to say, and neighbours can only
  // blend: there is no edge of a puff to show. The skirt still drops
  // under the discard floor before the quad's corners, so the margin
  // costs no noise taps.
  float r2 = dot(corner, corner);
  if (r2 >= 1.0) {
    discard; // outside the ellipse there is only the quad's own edge
  }
  float skirt = (1.0 - r2) * (1.0 - r2);
  float att = exp2(-mix(1.6, 3.4, clamp(uDither.y, 0.0, 1.0)) * r2) * skirt;
  if (att <= 0.004) {
    discard;
  }

  float reach = length(uFogEye.xyz - worldPosition);
  float visibility = fogVisibility(reach);
  if (visibility <= 0.001) {
    discard; // the world stops here; so does the mist
  }
  float nearFade = smoothstep(0.0, max(uMotion.z, 0.001), reach);

  // The drifting mottle, welded to the world: a plane through the puff's
  // own coordinates, crawled by time and warped once by its lower
  // octave. The seed pins every puff's pattern somewhere else in the
  // lattice, and the world stays put under a turning camera.
  float scale = max(uMotion.y, 0.1);
  vec2 p = worldPosition.xz / scale + shape.x * 37.0;
  float t = uMotion.x;
  p += vec2(t * 0.035, t * 0.017);
  if (uDither.z > 0.0 && uMotion.w > 0.0) {
    float warp = vnoise(p * 0.37 + t * 0.05);
    p += (vec2(warp, vnoise(p * 0.53 - warp)) - 0.5) * uMotion.w;
  }
  float w = fbm(p);

  // Detail shades the body's weight -- thick rolls and thin veils -- but
  // only within the puff: the noise never eats the silhouette, so what
  // fades is always the smooth Gaussian, never a torn threshold.
  float wisps = clamp(0.55 + 1.3 * (w - 0.5), 0.0, 1.0);
  float coverage = mix(1.0, wisps, clamp(uDither.z, 0.0, 1.0));

  float alpha = shape.w * att * coverage * nearFade * visibility;

  // The soft particle: where the land rises through a puff, the two
  // depths converge, and the mist gives way over the last few metres of
  // the crossing instead of drawing a chord across the hillside. The
  // scene depth is last frame's replay -- one frame stale, and fog is
  // the slowest thing on screen, so the eye never catches it.
  if (uDither.w > 0.0) {
    vec2 res = textureSize(uSceneDepth, 0);
    float scene = unpackDepth(texture(uSceneDepth, gl_FragCoord.xy / res)) *
                  uSoft.x;
    alpha *= clamp((scene - viewDepth) / uDither.w, 0.0, 1.0);
    if (alpha <= 0.002) {
      discard; // the land is here; the mist is not
    }
  }

  // The dither, and its smooth twin: the blend weight is first landed on
  // one of thirty-two steps by a pixel-sized coin-toss -- the same grain
  // the occlusion pass breaks its contours with, so the mist's fades sit
  // on the very grid the lighting's dithers across -- and that stepped
  // value is then blended back into the continuous one. What the eye gets
  // is a retro dither feel with a smooth wash behind it: texture in the
  // transitions, never dots in place of colour. The share is the caller's
  // `dither`: 0 is pure wash, 1 pure stepped grain, and half is the look.
  float grain = hash12(gl_FragCoord.xy);
  const float steps = 32.0;
  float stepped = floor(clamp(alpha, 0.0, 1.0) * steps + grain) / steps;
  alpha = mix(alpha, stepped, clamp(uDither.x, 0.0, 1.0));
  if (alpha <= 0.002) {
    discard; // nothing to lay: cost the frame a pixel less
  }

  // Wear the scene's haze -- or a tint, when the caller has something of
  // its own to say -- and sink into it like everything else in the frame.
  vec3 base = mix(uFogNear.rgb, uFogFar.rgb, 0.35) *
              (0.92 + 0.16 * fract(shape.x * 7.31));
  base = mix(base, uTint.rgb, clamp(uTint.a, 0.0, 1.0));
  float amount = fogAmount(reach);
  vec3 hazed = mix(base, mix(uFogNear.rgb, uFogFar.rgb, amount), amount);
  outColor = vec4(hazed, alpha);
}
