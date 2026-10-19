#version 450

layout(location = 0) in vec2 vUv;
layout(location = 0) out vec4 outColor;
layout(set = 2, binding = 0) uniform sampler2D uDepth;
layout(set = 3, binding = 0) uniform Ssao {
  vec4 uResolutionRadius; // xy = pixels, z = reach in metres
  vec4 uProjection; // x = near, y = far, z = tan(fovY / 2)
  vec4 uStrengthBias; // x = strength, y = height off the plane to count, metres
};

float unpackDepth(vec4 packed) {
  return dot(packed, vec4(1.0 / 16777216.0, 1.0 / 65536.0,
    1.0 / 256.0, 1.0));
}

vec3 viewPosition(vec2 uv, float depth) {
  // Un-project: the eye sits at the origin looking down -z, and a texel's
  // ray spreads from the centre by the frustum's opening at that uv.
  float tanHalf = max(uProjection.z, 0.0001);
  vec2 open = (uv - 0.5) * vec2(uResolutionRadius.x / uResolutionRadius.y, 1.0)
    * 2.0 * tanHalf;
  vec3 ray = normalize(vec3(open, -1.0));
  return ray * (depth / -ray.z);
}

float hash12(vec2 p) {
  vec3 p3 = fract(vec3(p.xyx) * 0.1031);
  p3 += dot(p3, p3.yzx + 33.33);
  return fract((p3.x + p3.y) * p3.z);
}

void main() {
  float far = uProjection.y;
  float center = unpackDepth(texture(uDepth, vUv)) * far;
  if (center >= far * 0.995) { outColor = vec4(1.0); return; }

  vec3 eye = viewPosition(vUv, center);
  // The surface's own tilt, read off the depth field across one texel
  // step: a receding floor is a plane, and planes do not hide themselves.
  // Only a seam -- where the depth field bends -- is a corner.
  vec3 normal = normalize(cross(dFdx(eye), dFdy(eye)));
  if (normal.z < 0.0) { normal = -normal; } // visible faces look at the eye

  float radius = uResolutionRadius.z;
  // Metres to uv at this depth: the window shows twice the half-angle's
  // tangent of world height, and that times the aspect of width. So the
  // reach is one fixed world length -- wide on screen up close, fine far
  // away -- which is what shades a hand-sized corner in both the cellars
  // and the open country.
  vec2 uvPerMetre = vec2(1.0 / (uResolutionRadius.x / uResolutionRadius.y), 1.0)
    / (2.0 * center * max(uProjection.z, 0.0001));
  float angle = hash12(gl_FragCoord.xy) * 6.2831853;
  mat2 spin = mat2(cos(angle), sin(angle), -sin(angle), cos(angle));

  const vec2 kernel[12] = vec2[](
    vec2(0.52, 0.18), vec2(-0.33, 0.61), vec2(-0.72, -0.16), vec2(0.21, -0.71),
    vec2(0.84, -0.42), vec2(-0.11, -0.93), vec2(0.42, 0.82), vec2(-0.91, 0.36),
    vec2(0.13, 0.42), vec2(-0.39, -0.28), vec2(0.58, 0.05), vec2(-0.05, 0.75)
  );
  float occlusion = 0.0;
  for (int i = 0; i < 12; ++i) {
    float scale = mix(0.35, 1.0, float(i) / 11.0);
    vec2 uv = clamp(vUv + (spin * (kernel[i] * scale)) * radius * uvPerMetre,
      0.001, 0.999);
    float hit = unpackDepth(texture(uDepth, uv)) * far;
    if (center - hit <= 0.0 || center - hit > radius) { continue; }
    vec3 v = viewPosition(uv, hit) - eye;
    // How far the sample stands proud of the surface's own plane: that
    // height, not the depth gap, is the shadow. A wall cutting across the
    // floor's plane lifts off it; the flat floor ahead does not.
    float height = dot(normal, v);
    float occludes = smoothstep(uStrengthBias.y, uStrengthBias.y + radius, height);
    float reach = 1.0 - dot(v, v) / (radius * radius);
    occlusion += occludes * max(reach, 0.0);
  }
  float ao = 1.0 - (occlusion / 12.0) * uStrengthBias.x;
  // The target holds one byte of shade: dithering it breaks the contour
  // lines a smooth gradient would otherwise stack across wide flat faces.
  ao += (hash12(gl_FragCoord.xy + 41.0) - 0.5) / 128.0;
  outColor = vec4(vec3(clamp(ao, 0.0, 1.0)), 1.0);
}
