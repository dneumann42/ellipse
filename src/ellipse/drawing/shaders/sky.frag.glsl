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
float cloudField(vec2 p) {
  return cloudNoise(p)*0.55 + cloudNoise(p*2.07+vec2(17,0))*0.27 +
    cloudNoise(p*4.13+vec2(0,31))*0.13 + cloudNoise(p*8.21)*0.05;
}
vec3 cloudSky(vec3 sky, vec3 dir) {
  if (uCloudWeather.w < 0.5 || dir.y <= 0.0) return sky;
  vec2 p = dir.xz * (2.8 / (dir.y + 0.38)) + uCloudWeather.x*vec2(0.007,0.002);
  float body = cloudField(p);
  float threshold = 0.76-uCloudWeather.y*0.62;
  float thickness = smoothstep(0.0, 0.18, body-threshold);
  float alpha = thickness * smoothstep(0.0,0.16,dir.y) * (0.94+uCloudWeather.y*0.055);
  // One offset density sample approximates sunlight through the cloud's
  // shoulder. The narrow forward lobe gives bright, translucent silver edges.
  float shadow = cloudField(p + uCloudSun.xz*0.24) - body;
  float daylight = uCloudWeather.z;
  float silver = pow(max(dot(dir,uCloudSun.xyz),0.0),18.0)*daylight;
  float edge = 4.0*thickness*(1.0-thickness);
  float shade = clamp(0.96-thickness*0.23-shadow*1.8+silver*(edge*0.65+0.12),0.42,1.2);
  float dusk = (1.0-smoothstep(0.0,0.375,abs(uCloudSun.y)))*daylight;
  float warm = dusk*(0.25+silver*0.55);
  vec3 cloud = shade*(0.10+daylight*0.90)*vec3(1.0,0.96-warm*0.24,1.0-warm*0.48);
  cloud += vec3(warm*0.20,0.0,(1.0-daylight)*0.055);
  return mix(sky, cloud * max(uExposure, 0.0), alpha);
}

void main() {
  vec3 direction = normalize(vViewDirection);
  float blend = clamp(uUseSkybox, 0.0, 1.0);
  vec3 color = mix(proceduralSky(direction), skyboxSky(direction), blend);
  outColor = vec4(cloudSky(color * max(uExposure, 0.0), direction), 1.0);
}
