#version 450

// The sky itself: a direction in, a colour out. A skybox is sampled along
// that direction and softened toward the horizon colour where the eye
// grazes the horizon or dips below it; with no skybox the sky is painted
// from three colours -- warm at the horizon, deep at the zenith, and a
// ground band below. Exposure brightens whichever the frame draws. The
// two mix into each other as the skybox's strength drops, so a picture
// can melt into the night sky instead of snapping away.

layout(location = 0) in vec3 vViewDirection;

layout(location = 0) out vec4 outColor;

layout(set = 2, binding = 0) uniform samplerCube uSkybox;

layout(set = 3, binding = 0) uniform Sky {
  mat4 uCameraRotation;
  vec4 uViewportScale;
  vec4 uHorizonExposure;
  vec4 uZenithUseSkybox;
  vec4 uGroundColorValue;
  vec4 uCloudWeather; // seconds, coverage, daylight, enabled
  vec4 uCloudSun; // direction toward sun
};

#define uHorizonColor uHorizonExposure.rgb
#define uExposure uHorizonExposure.a
#define uZenithColor uZenithUseSkybox.rgb
#define uUseSkybox uZenithUseSkybox.a
#define uGroundColor uGroundColorValue.rgb

vec3 proceduralSky(vec3 direction) {
  float up = clamp(direction.y * 0.5 + 0.5, 0.0, 1.0);
  float horizon = exp(-abs(direction.y) * 7.0);
  vec3 sky = mix(uHorizonColor, uZenithColor, smoothstep(0.35, 1.0, up));
  vec3 ground = mix(uGroundColor, uHorizonColor, smoothstep(0.0, 0.45, up));
  sky = direction.y < 0.0 ? ground : sky;
  return mix(sky, uHorizonColor, horizon * 0.35);
}

vec3 skyboxSky(vec3 direction) {
  vec3 color = texture(uSkybox, direction).rgb;
  float horizonBlend = pow(clamp(1.0 - abs(direction.y), 0.0, 1.0), 3.0) * 0.55;
  float lowerBlend = smoothstep(-0.45, 0.05, -direction.y) * 0.35;
  return mix(color, uHorizonColor, max(horizonBlend, lowerBlend));
}

// Integer hashing matches the game's celestial transmission samples.
float cloudHash(ivec2 cell) {
  uint h = uint(cell.x) * 374761393u;
  h ^= uint(cell.y) * 668265263u;
  h = (h ^ (h >> 13)) * 1274126177u;
  return float(h ^ (h >> 16)) / 4294967295.0;
}
float cloudNoise(vec2 p) {
  ivec2 cell = ivec2(floor(p));
  vec2 f = fract(p);
  f = f*f*(3.0-2.0*f);
  return mix(mix(cloudHash(cell), cloudHash(cell+ivec2(1,0)), f.x),
             mix(cloudHash(cell+ivec2(0,1)), cloudHash(cell+ivec2(1,1)), f.x), f.y);
}
// Match the CPU transmission field: large lobes curl slowly while
// smaller billows shear past them. Time is continuous across clock wraps.
float cloudField(vec2 p) {
  float t = uCloudWeather.x;
  p += t * vec2(0.014,0.004);
  vec2 curl = vec2(
    cloudNoise(p*0.8+t*vec2(0.009,-0.006)),
    cloudNoise(p*0.8+vec2(23,9)+t*vec2(-0.005,0.008)));
  vec2 q = p + (curl-0.5)*0.85;
  return cloudNoise(q)*0.55 +
    cloudNoise(q*2.07+vec2(17,0)+t*vec2(0.012,-0.009))*0.27 +
    cloudNoise(q*4.13+vec2(0,31)+t*vec2(-0.018,0.014))*0.13 +
    cloudNoise(q*8.21+t*vec2(0.025,0.011))*0.05;
}
vec3 cloudSky(vec3 sky, vec3 dir) {
  if (uCloudWeather.w < 0.5 || dir.y <= 0.0) return sky;
  vec2 p = dir.xz * (2.8 / (dir.y + 0.38));
  float body = cloudField(p);
  float threshold = 0.76-uCloudWeather.y*0.62;
  float thickness = smoothstep(0.015, 0.115, body-threshold);
  float alpha = smoothstep(0.0, 0.18, body-threshold) * smoothstep(0.0,0.16,dir.y) * (0.94+uCloudWeather.y*0.055);
  // Broad pigment masses with broken, directional brush marks. Keep the
  // silhouette field shared with CPU celestial transmission.
  float coverage = uCloudWeather.y;
  float storm = smoothstep(0.60, 0.98, coverage);
  float daylight = uCloudWeather.z;
  vec2 paintP = p + uCloudWeather.x * vec2(0.014,0.004);
  vec2 brushP = paintP * vec2(10.0, 23.0);
  brushP.x += cloudNoise(paintP * 5.0) * 3.0;
  float brush = cloudNoise(brushP);
  float mass = cloudNoise(paintP * 1.65 + vec2(8.0, 19.0));
  float shoulder = cloudField(p + uCloudSun.xz * 0.38) - body;
  float relief = clamp(0.60 - shoulder * 2.8 -
    (body - threshold) * 0.48 + (mass - 0.5) * 0.24, 0.0, 1.0);
  // Narrow transitions between paint values retain clear, irregular planes
  // without screen-space stippling or a blurred noise texture.
  float pigment = relief + (brush - 0.5) * 0.085;
  float planes = 0.24 + 0.23 * smoothstep(0.25, 0.40, pigment)
    + 0.23 * smoothstep(0.44, 0.59, pigment)
    + 0.22 * smoothstep(0.62, 0.77, pigment);
  float silver = pow(max(dot(dir,uCloudSun.xyz),0.0),18.0)*daylight;
  float edge = 4.0*thickness*(1.0-thickness);
  float dusk = (1.0-smoothstep(0.0,0.375,abs(uCloudSun.y)))*daylight;
  vec3 shadowColor = mix(vec3(0.43,0.49,0.59), vec3(0.16,0.21,0.29), storm);
  vec3 lightColor = mix(vec3(1.0,0.96,0.87), vec3(0.69,0.73,0.77), storm);
  lightColor = mix(lightColor, vec3(1.0,0.63,0.39), dusk * 0.65);
  vec3 cloud = mix(shadowColor, lightColor, planes);
  cloud += silver * edge * vec3(0.20,0.17,0.12) * (1.0-storm*0.6);
  cloud += (brush-0.5) * 0.025;
  cloud *= 0.09 + daylight * 0.91;
  cloud += vec3(0.005,0.009,0.025)*(1.0-daylight);
  // A cool atmospheric veil closes the blue gaps under a heavy front.
  vec3 stormSky = mix(vec3(0.39,0.45,0.53),vec3(0.23,0.29,0.38),
    smoothstep(0.0,0.7,dir.y)) * (0.09+daylight*0.91);
  sky = mix(sky, stormSky * max(uExposure,0.0), storm*0.85);
  return mix(sky, cloud * max(uExposure, 0.0), alpha);
}

void main() {
  vec3 direction = normalize(vViewDirection);
  float blend = clamp(uUseSkybox, 0.0, 1.0);
  vec3 color = mix(proceduralSky(direction), skyboxSky(direction), blend);
  outColor = vec4(cloudSky(color * max(uExposure, 0.0), direction), 1.0);
}
